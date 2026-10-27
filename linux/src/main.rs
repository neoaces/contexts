mod panel;

use adw::prelude::*;
use gtk::glib;

pub const APP_ID: &str = "local.contexts";

fn main() -> glib::ExitCode {
    // Also the X11 WM_CLASS instance, which the extension matches as a fallback.
    glib::set_prgname(Some(APP_ID));
    let app = adw::Application::builder().application_id(APP_ID).build();
    app.connect_startup(panel::install);
    // A second launch lands here in the running instance; the panel only opens from the edge.
    app.connect_activate(|_| {});
    app.run()
}
