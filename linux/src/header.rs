//! `[pin] … [new-block options | undo | tabs] [+] [≡]`, like `PanelHeader` in
//! `ContextPanelView.swift`. The slot before + shows one thing at a time, in
//! that priority, so the header never crowds.

use std::cell::Cell;
use std::rc::Rc;

use gtk::prelude::*;

use crate::model::{Model, NewBlock, State, Tab};

pub struct Header {
    pub root: gtk::Box,
    pin: gtk::Button,
    slot: gtk::Stack,
    undo_label: gtk::Label,
    recent: gtk::ToggleButton,
    history: gtk::ToggleButton,
    plus: gtk::Button,
    menu: gtk::Button,
    /// Set while syncing, so tab buttons changed from here aren't taken as clicks.
    syncing: Rc<Cell<bool>>,
}

impl Header {
    pub fn new(model: &Rc<Model>) -> Header {
        let pin = circle("view-pin-symbolic", "Pin to top right");
        let spacer = gtk::Box::builder().hexpand(true).build();

        let options = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        for (title, option) in [("Text", NewBlock::Text), ("Math", NewBlock::Math)] {
            let button = capsule();
            button.set_label(title);
            let model = model.clone();
            button.connect_clicked(move |_| model.create(option));
            options.append(&button);
        }

        let undo = capsule();
        let undo_label = gtk::Label::new(None);
        let undo_content = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        undo_content.append(&gtk::Image::from_icon_name("edit-undo-symbolic"));
        undo_content.append(&undo_label);
        undo.set_child(Some(&undo_content));

        let tabs = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        tabs.add_css_class("contexts-tabs");
        let recent = tab_button("Recent");
        let history = tab_button("History");
        history.set_group(Some(&recent));
        tabs.append(&recent);
        tabs.append(&history);

        let slot = gtk::Stack::builder()
            .hhomogeneous(false)
            .interpolate_size(true)
            .transition_type(gtk::StackTransitionType::Crossfade)
            .transition_duration(70)
            .build();
        slot.add_named(&options, Some("options"));
        slot.add_named(&undo, Some("undo"));
        slot.add_named(&tabs, Some("tabs"));

        let plus = circle("list-add-symbolic", "New block");
        plus.add_css_class("plus");
        let menu = circle("open-menu-symbolic", "Edit blocks");

        let root = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        root.add_css_class("contexts-header");
        for widget in [pin.upcast_ref::<gtk::Widget>(), spacer.upcast_ref(), slot.upcast_ref(), plus.upcast_ref(), menu.upcast_ref()] {
            root.append(widget);
        }

        let syncing = Rc::new(Cell::new(false));
        let m = model.clone();
        pin.connect_clicked(move |_| m.toggle_pin());
        let m = model.clone();
        undo.connect_clicked(move |_| m.undo());
        let m = model.clone();
        plus.connect_clicked(move |_| m.toggle_new_block_options());
        let m = model.clone();
        menu.connect_clicked(move |_| m.toggle_list_editing());
        for (button, tab) in [(&recent, Tab::Recent), (&history, Tab::History)] {
            let (m, syncing) = (model.clone(), syncing.clone());
            button.connect_toggled(move |button| {
                if button.is_active() && !syncing.get() {
                    m.show(tab);
                }
            });
        }

        Header { root, pin, slot, undo_label, recent, history, plus, menu, syncing }
    }

    pub fn sync(&self, state: &State, has_blocks: bool) {
        self.syncing.set(true);
        toggle_class(&self.pin, "active", state.pinned);
        self.pin.set_tooltip_text(Some(if state.pinned { "Unpin" } else { "Pin to top right" }));
        let slot = if state.choosing_new_block {
            "options"
        } else if let Some(action) = state.undoable_action {
            self.undo_label.set_label(&format!("Undo {action}"));
            "undo"
        } else {
            "tabs"
        };
        self.slot.set_visible_child_name(slot);
        self.recent.set_active(state.tab == Tab::Recent);
        self.history.set_active(state.tab == Tab::History);
        toggle_class(&self.plus, "open", state.choosing_new_block);
        self.plus.set_tooltip_text(Some(if state.choosing_new_block { "Close" } else { "New block" }));
        self.menu.set_visible(has_blocks);
        self.menu.set_icon_name(if state.editing_list { "object-select-symbolic" } else { "open-menu-symbolic" });
        self.menu.set_tooltip_text(Some(if state.editing_list { "Done" } else { "Edit blocks" }));
        self.syncing.set(false);
    }
}

/// Header buttons never take keyboard focus, so a block being edited keeps it until the model ends editing.
fn circle(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::builder().icon_name(icon).tooltip_text(tooltip).focus_on_click(false).can_focus(false).build();
    button.add_css_class("contexts-circle");
    button
}

fn capsule() -> gtk::Button {
    let button = gtk::Button::builder().focus_on_click(false).can_focus(false).build();
    button.add_css_class("contexts-capsule");
    button
}

fn tab_button(title: &str) -> gtk::ToggleButton {
    gtk::ToggleButton::builder().label(title).focus_on_click(false).can_focus(false).build()
}

pub fn toggle_class(widget: &impl IsA<gtk::Widget>, class: &str, on: bool) {
    if on {
        widget.add_css_class(class);
    } else {
        widget.remove_css_class(class);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::list::BlockList;
    use contexts::block::{Block, Content, TextRun};
    use contexts::folder::SyncFolder;
    use contexts::store::Store;
    use gtk::glib;

    fn buttons(root: &gtk::Widget, out: &mut Vec<gtk::Button>) {
        if let Some(button) = root.downcast_ref::<gtk::Button>() {
            out.push(button.clone());
        }
        let mut child = root.first_child();
        while let Some(widget) = child {
            buttons(&widget, out);
            child = widget.next_sibling();
        }
    }

    fn find(root: &impl IsA<gtk::Widget>, name: &str) -> Vec<gtk::Button> {
        let mut all = vec![];
        buttons(root.upcast_ref(), &mut all);
        all.into_iter()
            .filter(|b| b.tooltip_text().as_deref() == Some(name) || b.label().as_deref() == Some(name)
                || (name == "Undo" && b.has_css_class("contexts-capsule") && b.label().is_none()))
            .collect()
    }

    fn spin() {
        let context = glib::MainContext::default();
        for _ in 0..50 {
            while context.iteration(false) {}
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    #[test]
    fn delete_then_undo_through_the_widgets() {
        if gtk::init().is_err() {
            return; // no display
        }
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(SyncFolder::new(dir.path().to_owned(), "ubuntu".into()));
        for text in ["one", "two"] {
            store.insert(Block::new(Content::Text(vec![TextRun { text: text.into(), ..Default::default() }]), "ubuntu", contexts::block::now()));
        }
        let model = crate::model::Model::new(store);
        let header = Rc::new(Header::new(&model));
        let list = Rc::new(BlockList::new(&model, 336));
        let (h, l, m) = (header.clone(), list.clone(), Rc::downgrade(&model));
        model.connect_changed(move || {
            let model = m.upgrade().unwrap();
            let state = model.state();
            let blocks = model.listed();
            h.sync(&state, !blocks.is_empty());
            l.sync(&state, &blocks);
        });
        model.present(false);
        spin();

        find(&header.root, "Edit blocks")[0].emit_clicked();
        spin();
        let minus = find(&list.root, "Delete");
        eprintln!("delete-named buttons: {}", minus.len());
        minus.iter().find(|b| b.has_css_class("contexts-minus")).unwrap().emit_clicked();
        spin();
        assert_eq!(model.listed().len(), 1);
        assert_eq!(model.state().undoable_action, Some("Delete"));
        assert_eq!(header.slot.visible_child_name().as_deref(), Some("undo"));

        let undo = find(&header.root, "Undo");
        eprintln!("undo buttons: {}", undo.len());
        undo[0].emit_clicked();
        spin();
        assert_eq!(model.listed().len(), 2, "undo restores the block");
    }
}
