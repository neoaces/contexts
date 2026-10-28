//! The blocks under the header, like `BlockList.swift`. Rows exist only while
//! the panel is on screen; each drops in from the header with a short stagger.
//! The newest block sits next to the header, whichever way the list grows.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use contexts::block::{Block, Content};
use contexts::config;
use gtk::glib;
use uuid::Uuid;

use crate::editor::{Editor, Kind};
use crate::header::toggle_class;
use crate::math::MathView;
use crate::model::{Model, State, Tab};

/// Header row height plus the spacing under it.
const HEADER_HEIGHT: i32 = 34 + 8;
const CARD_PADDING: i32 = 12;
const ANIMATION_MS: u32 = 70;
const STAGGER_MS: u64 = 6;
const STAGGER_ROWS: usize = 6;

pub struct BlockList {
    pub root: gtk::ScrolledWindow,
    column: gtk::Box,
    empty_note: gtk::Box,
    rows: RefCell<Vec<Rc<Row>>>,
    model: Rc<Model>,
    width: i32,
    mounted: Cell<bool>,
    newest: Cell<Option<Uuid>>,
}

impl BlockList {
    pub fn new(model: &Rc<Model>, width: i32) -> BlockList {
        let column = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let message = match config::archive_after() {
            Some(after) => format!("Blocks unused for {} minutes move here.", after.as_secs() / 60),
            None => "Archiving is off.".into(),
        };
        let note = gtk::Label::builder().label(message).wrap(true).xalign(0.0).build();
        note.add_css_class("dim-label");
        let empty_note = gtk::Box::new(gtk::Orientation::Vertical, 0);
        empty_note.add_css_class("contexts-card");
        empty_note.append(&note);
        column.append(&empty_note);
        let root = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::External)
            .propagate_natural_height(true)
            .child(&column)
            .build();
        BlockList {
            root,
            column,
            empty_note,
            rows: RefCell::new(vec![]),
            model: model.clone(),
            width,
            mounted: Cell::new(false),
            newest: Cell::new(None),
        }
    }

    /// The tallest the whole panel may get, from the screen edge it grows towards.
    pub fn set_limit(&self, panel_height: i32) {
        self.root.set_max_content_height((panel_height - HEADER_HEIGHT).max(0));
    }

    pub fn sync(&self, state: &State, blocks: &[Block]) {
        if !state.presented {
            if self.mounted.replace(false) {
                for row in self.rows.take() {
                    // A finished leaving row has removed itself already.
                    if row.revealer.parent().as_ref() == Some(self.column.upcast_ref()) {
                        self.column.remove(&row.revealer);
                    }
                }
            }
            return;
        }
        let dropping_in = !self.mounted.replace(true);
        let mut order: Vec<&Block> = blocks.iter().collect();
        if state.upward {
            order.reverse();
        }

        let mut rows = self.rows.borrow_mut();
        // Rows whose collapse finished have already left the column.
        rows.retain(|row| !(row.leaving.get() && row.revealer.parent().is_none()));
        let mut kept: Vec<Rc<Row>> = vec![];
        for block in &order {
            let row = match rows.iter().find(|r| r.id == block.id && r.fits(&block.content)) {
                Some(row) => row.clone(),
                None => Row::new(&self.model, block, state.upward, self.width - 2 * CARD_PADDING),
            };
            row.leaving.set(false);
            row.update(block, state);
            kept.push(row);
        }
        for row in rows.iter() {
            if !kept.iter().any(|k| Rc::ptr_eq(k, row)) && !row.leaving.replace(true) {
                row.revealer.set_reveal_child(false);
            }
        }

        // Kept rows in order, then the note on the side away from the header; leaving rows stay put.
        let mut previous: Option<gtk::Widget> = None;
        for row in &kept {
            if row.revealer.parent().is_none() {
                self.column.append(&row.revealer);
            }
            self.column.reorder_child_after(&row.revealer, previous.as_ref());
            previous = Some(row.revealer.clone().upcast());
        }
        if state.upward {
            self.column.reorder_child_after(&self.empty_note, None::<&gtk::Widget>);
        } else {
            self.column.reorder_child_after(&self.empty_note, previous.as_ref());
        }
        self.empty_note.set_visible(state.tab == Tab::History && kept.is_empty());

        let count = kept.len();
        for (index, row) in kept.iter().enumerate() {
            if row.revealer.reveals_child() {
                continue;
            }
            let from_header = if state.upward { count - 1 - index } else { index };
            if dropping_in && from_header > 0 {
                let revealer = row.revealer.clone();
                let delay = STAGGER_MS * from_header.min(STAGGER_ROWS) as u64;
                glib::timeout_add_local_once(Duration::from_millis(delay), move || revealer.set_reveal_child(true));
            } else {
                row.revealer.set_reveal_child(true);
            }
        }

        // Leaving rows are removed once their collapse has finished.
        let leaving: Vec<Rc<Row>> = rows.iter().filter(|r| r.leaving.get()).cloned().collect();
        *rows = kept;
        rows.extend(leaving);
        drop(rows);

        // Keep the header edge in view on open (upward lists start scrolled to the end)
        // and when a new block appears there.
        let newest = blocks.first().map(|b| b.id);
        let new_block_editing = newest.is_some() && newest != self.newest.replace(newest) && newest == state.editing;
        if (dropping_in && state.upward) || new_block_editing {
            let (root, upward) = (self.root.clone(), state.upward);
            glib::timeout_add_local_once(Duration::from_millis(ANIMATION_MS as u64 + 50), move || {
                let adjustment = root.vadjustment();
                adjustment.set_value(if upward { adjustment.upper() } else { 0.0 });
            });
        }
    }

}

enum Body {
    Text(Rc<Editor>),
    Math(MathView),
}

struct Row {
    id: Uuid,
    revealer: gtk::Revealer,
    minus: gtk::Revealer,
    card: gtk::Box,
    body: Body,
    leaving: Cell<bool>,
}

impl Row {
    fn new(model: &Rc<Model>, block: &Block, upward: bool, content_width: i32) -> Rc<Row> {
        let id = block.id;
        let body = match &block.content {
            Content::Math(_) => Body::Math(MathView::new(content_width)),
            _ => Body::Text(Editor::new(Kind::RichText)),
        };
        let card = gtk::Box::new(gtk::Orientation::Vertical, 0);
        card.add_css_class("contexts-card");
        card.append(match &body {
            Body::Text(editor) => editor.view.upcast_ref::<gtk::Widget>(),
            Body::Math(math) => math.root.upcast_ref(),
        });

        card.set_hexpand(true);

        let minus_button = gtk::Button::builder()
            .icon_name("list-remove-symbolic")
            .tooltip_text("Delete")
            .valign(gtk::Align::Center)
            .focus_on_click(false)
            .can_focus(false)
            .build();
        minus_button.add_css_class("contexts-minus");
        let minus = gtk::Revealer::builder()
            .transition_type(gtk::RevealerTransitionType::SlideRight)
            .transition_duration(ANIMATION_MS)
            .child(&minus_button)
            .build();

        let outer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        outer.append(&minus);
        outer.append(&card);
        let revealer = gtk::Revealer::builder()
            .transition_type(if upward { gtk::RevealerTransitionType::SlideUp } else { gtk::RevealerTransitionType::SlideDown })
            .transition_duration(ANIMATION_MS)
            .child(&outer)
            .build();

        let row = Rc::new(Row {
            id,
            revealer,
            minus,
            card,
            body,
            leaving: Cell::new(false),
        });

        let m = model.clone();
        minus_button.connect_clicked(move |_| m.delete(id));

        // A click starts editing in place; in delete mode it does nothing, in History it restores.
        let click = gtk::GestureClick::new();
        click.set_propagation_phase(gtk::PropagationPhase::Capture);
        let m = model.clone();
        click.connect_pressed(move |gesture, _, _, _| {
            if m.state().editing != Some(id) && !m.activate(id) {
                gesture.set_state(gtk::EventSequenceState::Claimed);
            }
        });
        row.card.add_controller(click);

        let editor = match &row.body {
            Body::Text(editor) => editor.clone(),
            Body::Math(math) => math.source.clone(),
        };
        let (m, weak) = (model.clone(), Rc::downgrade(&row));
        editor.connect_change(move |content| {
            if let (Some(row), Content::Math(latex)) = (weak.upgrade(), &content) {
                if let Body::Math(math) = &row.body {
                    math.update(latex, true);
                }
            }
            m.edit(id, content);
        });
        let m = model.clone();
        editor.connect_commit(move |key| {
            m.held_commit_key.set(Some(key));
            m.end_editing();
        });

        let weak = Rc::downgrade(&row);
        row.revealer.connect_child_revealed_notify(move |revealer| {
            if revealer.is_child_revealed() {
                return;
            }
            let Some(row) = weak.upgrade() else { return };
            if row.leaving.get() {
                if let Some(list) = revealer.parent().and_downcast::<gtk::Box>() {
                    list.remove(revealer);
                }
            }
        });
        row
    }

    /// A row keeps its kind of body; content of another kind needs a new row.
    fn fits(&self, content: &Content) -> bool {
        matches!((&self.body, content), (Body::Math(_), Content::Math(_)) | (Body::Text(_), Content::Text(_)))
    }

    fn update(&self, block: &Block, state: &State) {
        let editing = state.editing == Some(self.id);
        toggle_class(&self.card, "editing", editing);
        match (&self.body, &block.content) {
            (Body::Text(editor), content) => {
                if editing {
                    editor.show_content(content);
                    editor.set_editing(true);
                } else {
                    editor.set_editing(false);
                    editor.show_content(content);
                }
            }
            (Body::Math(math), Content::Math(latex)) => {
                if editing {
                    math.source.show_content(&block.content);
                    math.update(&latex_of(&math.source.content()), true);
                    math.source.set_editing(true);
                } else {
                    math.source.set_editing(false);
                    math.source.show_content(&block.content);
                    math.update(latex, false);
                }
            }
            _ => {}
        }

        self.minus.set_reveal_child(state.editing_list);
    }
}

fn latex_of(content: &Content) -> String {
    match content {
        Content::Math(latex) => latex.clone(),
        _ => String::new(),
    }
}
