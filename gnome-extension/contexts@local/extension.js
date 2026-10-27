// Opens the Contexts panel from the right screen edge: launches the app, finds
// its window, and places, shows and hides it. The app draws the panel and
// hides its own content (see linux/src/panel.rs); this side owns placement,
// pointer tracking and the open/close animation.

import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const APP_ID = 'local.contexts';
const APP_PATH = `${GLib.get_home_dir()}/.local/bin/contexts-linux`;
const OBJECT_PATH = '/local/contexts';
const PANEL_IFACE = 'local.contexts.Panel';

const EDGE = 2;              // hot zone width
const DWELL_MS = 60;
const LEAVE_MS = 40;
const POLL_MS = 10;          // pointer polling, only while shown
const HOVER_SLACK = 10;      // px around the panel that still count as inside
const MARGIN = 12;           // gap to the screen edge
const HEADER_CENTER = 30;    // panel edge to header center, so the header lands under the pointer
const UPWARD_BELOW = 320;    // closer than this to the bottom, the list grows upward
const ANIM_MS = 70;
const SLIDE = 10;
const RELAUNCH_MS = 1000;

// A disable followed by enable in the same main-loop pass (the shell does this
// around screen lock) cancels the quit, so the app survives it.
let pendingQuit = 0;

export default class ContextsEdge extends Extension {
    enable() {
        if (pendingQuit) {
            GLib.source_remove(pendingQuit);
            pendingQuit = 0;
        }
        this._win = null;
        this._shown = false;
        this._pinned = false;
        this._editing = false;

        // 1. Launch the app.
        //    X11: whenever its bus name has no owner (now, or after it quits or
        //    crashes); the app hides itself from dock/Alt-Tab with X11 hints.
        //    Wayland only (not tested): spawn through Meta.WaylandClient so the
        //    extension owns the window and can hide it from the window list.
        if (Meta.is_wayland_compositor()) {
            const launcher = new Gio.SubprocessLauncher({flags: Gio.SubprocessFlags.NONE});
            this._client = Meta.WaylandClient.new.length === 1
                ? Meta.WaylandClient.new(launcher) : Meta.WaylandClient.new(global.context, launcher);
            this._client.spawnv(global.display, [APP_PATH]);
        } else {
            this._nameWatch = Gio.bus_watch_name(Gio.BusType.SESSION, APP_ID,
                Gio.BusNameWatcherFlags.NONE, null, () => this._launch());
        }

        // 2. Adopt its window: one already open (after an Alt+F2 r restart) or a new one.
        global.display.list_all_windows().forEach(w => this._adopt(w));
        global.display.connectObject('window-created', (_d, w) => this._adopt(w), this);

        this._signalId = Gio.DBus.session.signal_subscribe(APP_ID, PANEL_IFACE, null, OBJECT_PATH,
            null, Gio.DBusSignalFlags.NONE,
            (_c, _sender, _path, _iface, signal, params) => this._onAppSignal(signal, params));

        // 3. Edge hot zone, event-driven (no polling while idle).
        this._buildEdge();
        Main.layoutManager.connectObject('monitors-changed', () => this._buildEdge(), this);
        Main.sessionMode.connectObject('updated', () => {
            if (Main.sessionMode.isLocked)
                this._hide();
        }, this);
        // The hidden panel is still focusable, and Mutter falls back to it
        // (workspace switch, a window closing): pass the keyboard on.
        global.display.connectObject('notify::focus-window', () => {
            if (!this._shown && this._win && global.display.focus_window === this._win)
                this._focusAwayId ||= GLib.idle_add(GLib.PRIORITY_DEFAULT, () => {
                    this._focusAwayId = 0;
                    if (!this._shown && global.display.focus_window === this._win)
                        this._focusAway(null);
                    return GLib.SOURCE_REMOVE;
                });
        }, this);
    }

    disable() {
        this._hide();
        this._clearTimeouts();
        if (this._focusAwayId)
            GLib.source_remove(this._focusAwayId);
        if (this._relaunchId)
            GLib.source_remove(this._relaunchId);
        this._focusAwayId = this._relaunchId = 0;
        if (this._nameWatch)
            Gio.bus_unwatch_name(this._nameWatch);
        this._nameWatch = 0;
        Gio.DBus.session.signal_unsubscribe(this._signalId);
        global.display.disconnectObject(this);
        Main.layoutManager.disconnectObject(this);
        Main.sessionMode.disconnectObject(this);
        this._win?.disconnectObject(this);
        this._destroyEdge();
        // The panel goes with the extension, unless it is enabled again right away.
        pendingQuit = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            pendingQuit = 0;
            callApp('quit');
            return GLib.SOURCE_REMOVE;
        });
        this._win = null;
        this._client = null;
    }

    // Delayed and rate-limited, so an app that keeps crashing isn't respawned in a loop.
    _launch() {
        if (this._relaunchId)
            return;
        const wait = Math.max(0, Math.ceil((this._launchedAt ?? -Infinity) + RELAUNCH_MS - GLib.get_monotonic_time() / 1000));
        this._relaunchId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, wait, () => {
            this._relaunchId = 0;
            this._launchedAt = GLib.get_monotonic_time() / 1000;
            try {
                Gio.Subprocess.new([APP_PATH], Gio.SubprocessFlags.NONE);
            } catch (e) {
                console.error(`Contexts: launching ${APP_PATH} failed: ${e.message}`);
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    _isOurs(win) {
        return (win.get_gtk_application_id() ?? win.get_wm_class_instance()) === APP_ID;
    }

    _adopt(win) {
        if (this._win || !(this._client ? this._client.owns_window(win) : this._isOurs(win)))
            return;
        this._win = win;
        this._client?.hide_from_window_list(win);
        win.connectObject(
            'size-changed', () => this._place(),
            'unmanaged', () => {
                win.disconnectObject(this);
                this._win = null;
                this._shown = false;
                this._clearTimeouts();
                this._syncEdge();
            }, this);
        if (!win.above)
            win.make_above();
        win.stick();
        // Resyncs the app after a shell restart that happened while the panel was open.
        this._callApp('hide');
    }

    _onAppSignal(signal, params) {
        if (signal === 'StateChanged') {
            const [pinned, editing] = params.deepUnpack();
            const pinChanged = pinned !== this._pinned;
            this._pinned = pinned;
            this._editing = editing;
            if (pinChanged)
                this._place();
        } else if (signal === 'Dismiss') {
            this._hide();
        }
    }

    _buildEdge() {
        this._destroyEdge();
        const m = Main.layoutManager.primaryMonitor;
        if (!m)
            return;
        this._edge = new St.Widget({
            reactive: true, track_hover: true,
            x: m.x + m.width - EDGE, y: m.y, width: EDGE, height: m.height,
        });
        Main.layoutManager.addChrome(this._edge, {affectsInputRegion: true, trackFullscreen: true});
        this._edge.connect('notify::hover', () => {
            if (this._edge.hover)
                this._startDwell();
        });
        this._syncEdge();
    }

    // Hidden while the panel is open (it would cover the panel's last 2px), and
    // over fullscreen windows, as LayoutManager does for trackFullscreen chrome.
    _syncEdge() {
        if (this._edge)
            this._edge.visible = !this._shown &&
                !(global.window_group.visible && Main.layoutManager.primaryMonitor?.inFullscreen);
    }

    _destroyEdge() {
        if (!this._edge)
            return;
        Main.layoutManager.removeChrome(this._edge);
        this._edge.destroy();
        this._edge = null;
    }

    _startDwell() {
        if (this._dwellId || this._shown)
            return;
        this._dwellId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, DWELL_MS, () => {
            this._dwellId = 0;
            const [x, y, mods] = global.get_pointer();
            if (this._isOnEdge(x, y) && (mods & Clutter.ModifierType.BUTTON1_MASK) === 0)
                this._show(y);
            return GLib.SOURCE_REMOVE;
        });
    }

    _isOnEdge(x, y) {
        const m = Main.layoutManager.primaryMonitor;
        return m && x >= m.x + m.width - EDGE && x < m.x + m.width && y >= m.y && y < m.y + m.height;
    }

    _workArea() {
        return Main.layoutManager.getWorkAreaForMonitor(Main.layoutManager.primaryIndex);
    }

    _show(pointerY) {
        const actor = this._win?.get_compositor_private();
        if (!actor || this._shown || Main.sessionMode.isLocked || Main.overview.visible)
            return;
        this._rememberFocus();
        const wa = this._workArea();
        this._anchorY = pointerY;
        this._upward = wa.y + wa.height - pointerY < UPWARD_BELOW;
        this._shown = true;
        this._callApp('show', new GLib.Variant('b', this._upward));
        this._place();
        if (!this._win.above)
            this._win.make_above();
        this._syncEdge();

        actor.remove_all_transitions();
        actor.opacity = 0;
        actor.translation_y = this._upward ? SLIDE : -SLIDE;
        actor.ease({
            opacity: 255, translation_y: 0,
            duration: ANIM_MS, mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        });
        this._pollId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, POLL_MS, () => this._poll());
    }

    // The app makes its content transparent and click-through only once the fade has finished.
    _hide() {
        if (!this._shown)
            return;
        this._shown = false;
        this._clearTimeouts();
        this._restoreFocus();
        this._syncEdge();
        const actor = this._win?.get_compositor_private();
        if (!actor) {
            this._callApp('hide');
            return;
        }
        actor.ease({
            opacity: 0, translation_y: this._upward ? SLIDE : -SLIDE,
            duration: ANIM_MS, mode: Clutter.AnimationMode.EASE_IN_QUAD,
            onComplete: () => {
                if (!this._shown)
                    this._callApp('hide');
            },
        });
    }

    // Top-right; the header sits under the pointer, or at the top of the work area when pinned.
    _place() {
        if (!this._win || !this._shown)
            return;
        const wa = this._workArea();
        const frame = this._win.get_frame_rect();
        const x = wa.x + wa.width - frame.width - MARGIN;
        let y;
        if (this._pinned)
            y = wa.y + MARGIN;
        else if (this._upward)
            y = this._anchorY + HEADER_CENTER - frame.height;
        else
            y = this._anchorY - HEADER_CENTER;
        y = Math.max(wa.y, Math.min(y, wa.y + wa.height - frame.height));
        if (x !== frame.x || y !== frame.y)
            this._win.move_frame(true, x, y);
    }

    // Stays open while the pointer is near the panel or on the edge, or while pinned or editing.
    _poll() {
        const [x, y] = global.get_pointer();
        const r = this._win.get_frame_rect();
        const near = x >= r.x - HOVER_SLACK && x < r.x + r.width + HOVER_SLACK &&
            y >= r.y - HOVER_SLACK && y < r.y + r.height + HOVER_SLACK;
        if (near || this._isOnEdge(x, y) || this._pinned || this._editing) {
            this._leftAt = 0;
            return GLib.SOURCE_CONTINUE;
        }
        const now = GLib.get_monotonic_time() / 1000;
        this._leftAt ||= now;
        if (now - this._leftAt < LEAVE_MS)
            return GLib.SOURCE_CONTINUE;
        this._pollId = 0;
        this._hide();
        return GLib.SOURCE_REMOVE;
    }

    _clearTimeouts() {
        if (this._dwellId)
            GLib.source_remove(this._dwellId);
        if (this._pollId)
            GLib.source_remove(this._pollId);
        this._dwellId = this._pollId = this._leftAt = 0;
    }

    _rememberFocus() {
        this._previousFocus?.disconnectObject(this);
        const focused = global.display.focus_window;
        this._previousFocus = focused && focused !== this._win ? focused : null;
        this._previousFocus?.connectObject('unmanaged', () => {
            this._previousFocus = null;
        }, this);
    }

    // A hidden panel must not keep the keyboard: hand it back to the window that had it.
    _restoreFocus() {
        const previous = this._previousFocus;
        previous?.disconnectObject(this);
        this._previousFocus = null;
        if (this._win && global.display.focus_window === this._win)
            this._focusAway(previous);
    }

    // Prefers `preferred`, but never switches workspace for it.
    _focusAway(preferred) {
        const time = global.display.get_current_time_roundtrip();
        const workspace = global.workspace_manager.get_active_workspace();
        const target = preferred?.located_on_workspace(workspace) && !preferred.minimized
            ? preferred
            : global.display.get_tab_list(Meta.TabList.NORMAL, workspace).find(w => w !== this._win);
        if (target)
            target.activate(time);
        else
            global.display.unset_input_focus(time);
    }

    _callApp(action, param = null) {
        callApp(action, param);
    }
}

function callApp(action, param = null) {
    Gio.DBus.session.call(APP_ID, OBJECT_PATH, 'org.gtk.Actions', 'Activate',
        new GLib.Variant('(sava{sv})', [action, param ? [param] : [], {}]),
        null, Gio.DBusCallFlags.NO_AUTO_START, 1000, null,
        (conn, res) => {
            try {
                conn.call_finish(res);
            } catch (e) {
                console.warn(`Contexts: ${action} failed: ${e.message}`);
            }
        });
}
