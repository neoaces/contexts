//! The panel window, and the D-Bus actions and signals the GNOME Shell
//! extension uses to show, hide and place it.
//!
//! The window is mapped once and never unmapped: Mutter treats every re-map as
//! a new window (focus, above and sticky are lost). Hidden, its content is
//! transparent and its input region empty, so it neither shows (not even in the
//! shell's workspace-switch clones) nor catches clicks.

use std::cell::Cell;
use std::rc::Rc;

use adw::prelude::*;
use contexts::folder::SyncFolder;
use contexts::store::Store;
use gtk::{cairo, gdk, gio, glib};

use crate::header::Header;
use crate::list::BlockList;
use crate::model::Model;

/// Content width; the extension keeps the panel 12px from the screen edge.
const WIDTH: i32 = 336;
const OBJECT_PATH: &str = "/local/contexts";
/// Signals to the extension: `StateChanged(pinned, editing)` and `Dismiss()`.
const INTERFACE: &str = "local.contexts.Panel";

const CSS: &str = "
window.contexts-panel { background: none; }
.contexts-card, .contexts-circle, .contexts-capsule, .contexts-tabs {
  background-color: @window_bg_color;
  color: @window_fg_color;
  border: 1px solid alpha(@window_fg_color, 0.1);
  box-shadow: none;
}
.contexts-card { border-radius: 16px; padding: 12px; }
.contexts-card.editing { background-color: mix(@window_bg_color, @accent_bg_color, 0.12); }
button.contexts-circle { min-width: 32px; min-height: 32px; padding: 0; border-radius: 17px; }
button.contexts-capsule { min-height: 32px; padding: 0 14px; border-radius: 17px; font-weight: 500; }
button.contexts-circle:hover, button.contexts-capsule:hover { background-color: mix(@window_bg_color, @window_fg_color, 0.06); }
button.contexts-circle:active, button.contexts-capsule:active { background-color: mix(@window_bg_color, @window_fg_color, 0.12); }
button.contexts-circle.active { color: @accent_color; }
button.plus image { transition: transform 70ms ease-out; }
button.plus.open image { transform: rotate(45deg); }
.contexts-tabs { border-radius: 17px; padding: 2px; }
.contexts-tabs button {
  min-height: 28px; padding: 0 12px; border-radius: 14px;
  background: none; box-shadow: none; font-weight: 500;
  color: alpha(@window_fg_color, 0.6);
}
.contexts-tabs button:checked { background-color: alpha(@window_fg_color, 0.12); color: @window_fg_color; }
button.contexts-minus {
  min-width: 20px; min-height: 20px; padding: 0; margin-right: 8px; border-radius: 10px;
  background-color: @destructive_bg_color; color: @destructive_fg_color;
  -gtk-icon-size: 14px;
}
.contexts-editor, .contexts-editor > text { background: none; color: inherit; }
.contexts-math { border-radius: 10px; padding: 2px 0; }
.contexts-math.editing { background-color: alpha(black, 0.14); padding: 10px 0; }
";

struct Panel {
    window: gtk::ApplicationWindow,
    root: gtk::Box,
    header: Header,
    list: BlockList,
    model: Rc<Model>,
    connection: Option<gio::DBusConnection>,
    /// Last state sent to the extension, so only changes are sent.
    sent: Cell<Option<(bool, bool)>>,
    syncing: Cell<bool>,
    resync: Cell<bool>,
    _hold: gio::ApplicationHoldGuard,
}

pub fn install(app: &adw::Application) {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(CSS);
    gtk::style_context_add_provider_for_display(
        &gdk::Display::default().expect("no display"),
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    let model = Model::new(Store::open(SyncFolder::standard()));
    let panel = Rc::new(Panel::new(app, model));
    panel.add_actions(app);
    panel.connect_signals();
    let weak = Rc::downgrade(&panel);
    panel.model.connect_changed(move || {
        if let Some(panel) = weak.upgrade() {
            panel.sync();
        }
    });
    let weak = Rc::downgrade(&panel);
    panel.model.connect_dismiss(move || {
        if let Some(panel) = weak.upgrade() {
            panel.emit("Dismiss", None);
        }
    });
    let model = panel.model.clone();
    app.connect_shutdown(move |_| model.prepare_for_termination());
    panel.sync();
    // Not present(): that also asks the window manager for focus.
    panel.window.set_visible(true);
}

impl Panel {
    fn new(app: &adw::Application, model: Rc<Model>) -> Self {
        let header = Header::new(&model);
        let list = BlockList::new(&model, WIDTH);
        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .width_request(WIDTH)
            .opacity(0.0)
            .build();
        root.append(&header.root);
        root.append(&list.root);

        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .title("Contexts")
            .decorated(false)
            .resizable(false)
            .child(&root)
            .build();
        window.remove_css_class("background");
        window.add_css_class("contexts-panel");

        Self {
            window,
            root,
            header,
            list,
            model,
            connection: app.dbus_connection(),
            sent: Cell::new(None),
            syncing: Cell::new(false),
            resync: Cell::new(false),
            _hold: app.hold(),
        }
    }

    fn add_actions(self: &Rc<Self>, app: &adw::Application) {
        // `show(upward)`: near the bottom of the screen the list grows up from the header.
        let show = gio::SimpleAction::new("show", Some(glib::VariantTy::BOOLEAN));
        let panel = self.clone();
        show.connect_activate(move |_, arg| panel.show(arg.and_then(|v| v.get()).unwrap_or(false)));
        app.add_action(&show);

        let hide = gio::SimpleAction::new("hide", None);
        let panel = self.clone();
        hide.connect_activate(move |_, _| panel.hide());
        app.add_action(&hide);

        // `limit(height)`: the most the panel may grow to, from where it is placed.
        let limit = gio::SimpleAction::new("limit", Some(glib::VariantTy::INT32));
        let panel = self.clone();
        limit.connect_activate(move |_, arg| {
            if let Some(height) = arg.and_then(|v| v.get::<i32>()) {
                panel.list.set_limit(height);
            }
        });
        app.add_action(&limit);

        let quit = gio::SimpleAction::new("quit", None);
        let app_ref = app.clone();
        quit.connect_activate(move |_, _| app_ref.quit());
        app.add_action(&quit);
    }

    fn connect_signals(self: &Rc<Self>) {
        let panel = self.clone();
        self.window.connect_realize(move |window| {
            let Some(surface) = window.surface() else { return };
            if let Some(x11) = surface.downcast_ref::<gdk4_x11::X11Surface>() {
                // Out of the dock, Alt-Tab and the overview; no focus on the first map.
                x11.set_skip_taskbar_hint(true);
                x11.set_skip_pager_hint(true);
                x11.set_user_time(0);
            }
            panel.set_accepts_input(false);
        });

        // Clicking elsewhere ends editing, as on the Mac.
        let model = self.model.clone();
        self.window.connect_is_active_notify(move |window| {
            if !window.is_active() {
                model.end_editing();
            }
        });
        // Alt+F4 would destroy the one window for good; treat it like Escape.
        let panel = self.clone();
        self.window.connect_close_request(move |_| {
            panel.emit("Dismiss", None);
            glib::Propagation::Stop
        });

        // A held Return or Escape that just confirmed a block must not go on to
        // close the panel: its repeats are dropped until the key is released.
        let held = gtk::EventControllerKey::new();
        held.set_propagation_phase(gtk::PropagationPhase::Capture);
        let model = self.model.clone();
        held.connect_key_pressed(move |_, key, _, _| {
            if model.held_commit_key.get() == Some(key) {
                glib::Propagation::Stop
            } else {
                glib::Propagation::Proceed
            }
        });
        let model = self.model.clone();
        held.connect_key_released(move |_, key, _, _| {
            if model.held_commit_key.get() == Some(key) {
                model.held_commit_key.set(None);
            }
        });
        self.window.add_controller(held);

        // Escape outside a block closes the innermost open state; Ctrl+Z undoes
        // deletes and restores (inside a block, the text view undoes typing).
        let keys = gtk::EventControllerKey::new();
        let model = self.model.clone();
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            let control = modifiers.contains(gdk::ModifierType::CONTROL_MASK);
            let shift = modifiers.contains(gdk::ModifierType::SHIFT_MASK);
            match key {
                gdk::Key::Escape => model.cancel(),
                gdk::Key::z | gdk::Key::Z if control && model.state().editing.is_none() => {
                    if shift {
                        model.redo();
                    } else {
                        model.undo();
                    }
                }
                _ => return glib::Propagation::Proceed,
            }
            glib::Propagation::Stop
        });
        self.window.add_controller(keys);

        // The formula's color follows the theme's foreground at draw time.
        let window = self.window.clone();
        adw::StyleManager::default().connect_dark_notify(move |_| window.queue_draw());
    }

    fn show(&self, upward: bool) {
        self.model.held_commit_key.set(None);
        self.model.present(upward);
        self.set_accepts_input(true);
        self.root.set_opacity(1.0);
    }

    fn hide(&self) {
        self.model.hidden();
        self.root.set_opacity(0.0);
        self.set_accepts_input(false);
    }

    /// Re-entrant changes (a focus change while syncing) run one more pass.
    fn sync(&self) {
        if self.syncing.replace(true) {
            self.resync.set(true);
            return;
        }
        loop {
            self.resync.set(false);
            let state = self.model.state();
            let blocks = self.model.listed();
            self.header.sync(&state, !blocks.is_empty());
            // Blocks grow away from the header: downward, or upward near the bottom of the screen.
            let before = state.upward.then(|| self.list.root.clone().upcast::<gtk::Widget>());
            self.root.reorder_child_after(&self.header.root, before.as_ref());
            self.list.sync(&state, &blocks);
            self.send_state(state.pinned, state.editing.is_some());
            if !self.resync.get() {
                break;
            }
        }
        self.syncing.set(false);
    }

    fn set_accepts_input(&self, accepts: bool) {
        let Some(surface) = self.window.surface() else { return };
        let region = if accepts {
            // X11 clips the shape to the window, so this covers any size.
            cairo::Region::create_rectangle(&cairo::RectangleInt::new(0, 0, i16::MAX.into(), i16::MAX.into()))
        } else {
            cairo::Region::create()
        };
        surface.set_input_region(&region);
    }

    /// While pinned or editing, the extension keeps the panel open when the pointer leaves.
    fn send_state(&self, pinned: bool, editing: bool) {
        let state = (pinned, editing);
        if self.sent.replace(Some(state)) != Some(state) {
            self.emit("StateChanged", Some(&state.to_variant()));
        }
    }

    fn emit(&self, signal: &str, args: Option<&glib::Variant>) {
        let Some(connection) = &self.connection else { return };
        if let Err(error) = connection.emit_signal(None, OBJECT_PATH, INTERFACE, signal, args) {
            glib::g_warning!("contexts", "Emitting {signal} failed: {error}");
        }
    }
}
