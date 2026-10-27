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
use gtk::{cairo, gdk, gio, glib};

/// Content width; the extension keeps the panel 12px from the screen edge.
const WIDTH: i32 = 336;
const OBJECT_PATH: &str = "/local/contexts";
/// Signals to the extension: `StateChanged(pinned, editing)` and `Dismiss()`.
const INTERFACE: &str = "local.contexts.Panel";

const CSS: &str = "
window.contexts-panel { background: none; }
.contexts-card {
  background-color: @window_bg_color;
  color: @window_fg_color;
  border-radius: 16px;
  padding: 12px;
}
";

struct Panel {
    window: gtk::ApplicationWindow,
    content: gtk::Box,
    header: gtk::Box,
    pin: gtk::ToggleButton,
    entry: gtk::Entry,
    connection: Option<gio::DBusConnection>,
    /// Last state sent to the extension, so only changes are sent.
    sent: Cell<Option<(bool, bool)>>,
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

    let panel = Rc::new(Panel::new(app));
    panel.add_actions(app);
    panel.connect_signals();
    // Not present(): that also asks the window manager for focus.
    panel.window.set_visible(true);
}

impl Panel {
    fn new(app: &adw::Application) -> Self {
        let pin = gtk::ToggleButton::builder()
            .icon_name("view-pin-symbolic")
            .tooltip_text("Pin")
            .focus_on_click(false)
            .can_focus(false)
            .build();
        pin.add_css_class("circular");
        let header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        header.append(&pin);
        header.append(&gtk::Label::builder().label("Contexts").hexpand(true).xalign(1.0).build());
        let entry = gtk::Entry::builder().placeholder_text("Type here").build();

        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(8)
            .width_request(WIDTH)
            .opacity(0.0)
            .build();
        content.add_css_class("contexts-card");
        content.append(&header);
        content.append(&entry);

        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .title("Contexts")
            .decorated(false)
            .resizable(false)
            .child(&content)
            .build();
        window.remove_css_class("background");
        window.add_css_class("contexts-panel");

        Self {
            window,
            content,
            header,
            pin,
            entry,
            connection: app.dbus_connection(),
            sent: Cell::new(None),
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

        let panel = self.clone();
        self.window.connect_is_active_notify(move |window| {
            // Clicking elsewhere ends editing, as on the Mac.
            if !window.is_active() {
                clear_focus(window);
            }
            panel.send_state();
        });
        let panel = self.clone();
        self.window.connect_focus_widget_notify(move |_| panel.send_state());
        let panel = self.clone();
        self.pin.connect_toggled(move |_| panel.send_state());
        // Alt+F4 would destroy the one window for good; treat it like Escape.
        let panel = self.clone();
        self.window.connect_close_request(move |_| {
            panel.emit("Dismiss", None);
            glib::Propagation::Stop
        });

        // Escape ends editing, then unpins, then closes the panel.
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let panel = self.clone();
        keys.connect_key_pressed(move |_, key, _, _| {
            if key != gdk::Key::Escape {
                return glib::Propagation::Proceed;
            }
            if panel.is_editing() {
                clear_focus(&panel.window);
            } else if panel.pin.is_active() {
                panel.pin.set_active(false);
            } else {
                panel.emit("Dismiss", None);
            }
            glib::Propagation::Stop
        });
        self.window.add_controller(keys);
    }

    fn show(&self, upward: bool) {
        let first = if upward { Some(self.entry.upcast_ref::<gtk::Widget>()) } else { None };
        self.content.reorder_child_after(&self.header, first);
        self.set_accepts_input(true);
        self.content.set_opacity(1.0);
    }

    fn hide(&self) {
        clear_focus(&self.window);
        self.pin.set_active(false);
        self.content.set_opacity(0.0);
        self.set_accepts_input(false);
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

    fn is_editing(&self) -> bool {
        self.window.is_active()
            && GtkWindowExt::focus(&self.window).is_some_and(|w| w.is_ancestor(&self.entry))
    }

    /// While pinned or editing, the extension keeps the panel open when the pointer leaves.
    fn send_state(&self) {
        let state = (self.pin.is_active(), self.is_editing());
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

fn clear_focus(window: &gtk::ApplicationWindow) {
    GtkWindowExt::set_focus(window, None::<&gtk::Widget>);
}
