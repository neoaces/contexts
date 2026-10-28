//! The text view behind every block, like `BlockEditor.swift`. Rich text uses
//! it for both reading and editing, so a block never jumps when selected and
//! the selecting click also places the caret. Math uses it only for the
//! LaTeX source. Return confirms the block; Shift+Return adds a line.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use contexts::block::{Content, TextRun};
use gtk::prelude::*;
use gtk::{gdk, glib, pango};

#[derive(Clone, Copy, PartialEq)]
pub enum Kind {
    RichText,
    Math,
}

/// Bold, italic, underline: what newly typed text gets.
#[derive(Clone, Copy, Default, PartialEq)]
struct Style {
    bold: bool,
    italic: bool,
    underline: bool,
}

type Callback<T> = RefCell<Option<Box<dyn Fn(T)>>>;

pub struct Editor {
    pub view: gtk::TextView,
    kind: Kind,
    tags: [gtk::TextTag; 3],
    /// Set while the buffer is filled from stored content, so it isn't reported as an edit.
    loading: Cell<bool>,
    /// Set between an insertion's start and its styling, which reports the edit.
    inserting: Cell<bool>,
    typing: Cell<Style>,
    composing: Cell<bool>,
    /// What the view currently displays, to notice content replaced from outside.
    shown: RefCell<Option<Content>>,
    on_change: Callback<Content>,
    on_commit: Callback<gdk::Key>,
}

impl Editor {
    pub fn new(kind: Kind) -> Rc<Editor> {
        let buffer = gtk::TextBuffer::new(None);
        let tag = |name: &str| {
            let tag = gtk::TextTag::new(Some(name));
            buffer.tag_table().add(&tag);
            tag
        };
        let bold = tag("bold");
        bold.set_weight(700);
        let italic = tag("italic");
        italic.set_style(pango::Style::Italic);
        let underline = tag("underline");
        underline.set_underline(pango::Underline::Single);

        let view = gtk::TextView::builder()
            .buffer(&buffer)
            .wrap_mode(gtk::WrapMode::WordChar)
            .monospace(kind == Kind::Math)
            .accepts_tab(false)
            .build();
        view.add_css_class("contexts-editor");

        let editor = Rc::new(Editor {
            view,
            kind,
            tags: [bold, italic, underline],
            loading: Cell::new(false),
            inserting: Cell::new(false),
            typing: Cell::new(Style::default()),
            composing: Cell::new(false),
            shown: RefCell::new(None),
            on_change: RefCell::new(None),
            on_commit: RefCell::new(None),
        });
        editor.connect_buffer();
        editor.connect_keys();
        editor.set_editing(false);
        editor
    }

    pub fn connect_change(&self, callback: impl Fn(Content) + 'static) {
        self.on_change.replace(Some(Box::new(callback)));
    }

    /// Called with the key (Return or Escape) that confirmed the block.
    pub fn connect_commit(&self, callback: impl Fn(gdk::Key) + 'static) {
        self.on_commit.replace(Some(Box::new(callback)));
    }

    /// While read-only, the text follows the stored content, which can change
    /// underneath it when another device's edit is merged in.
    pub fn show_content(&self, content: &Content) {
        if self.view.is_editable() || self.shown.borrow().as_ref() == Some(content) {
            return;
        }
        self.shown.replace(Some(content.clone()));
        let buffer = self.view.buffer();
        self.loading.set(true);
        // Irreversible: loading isn't something Ctrl+Z should undo.
        buffer.begin_irreversible_action();
        buffer.set_text("");
        let mut end = buffer.end_iter();
        match content {
            Content::Text(runs) => {
                for run in runs {
                    let tags: Vec<&gtk::TextTag> = self.tags_for(style_of(run)).collect();
                    buffer.insert_with_tags(&mut end, &run.text, &tags);
                }
            }
            Content::Math(latex) => buffer.insert(&mut end, latex),
            Content::Unknown(_) => {}
        }
        buffer.end_irreversible_action();
        self.loading.set(false);
    }

    pub fn content(&self) -> Content {
        let buffer = self.view.buffer();
        match self.kind {
            Kind::Math => Content::Math(buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).into()),
            Kind::RichText => Content::Text(self.runs()),
        }
    }

    pub fn set_editing(&self, editing: bool) {
        let view = &self.view;
        view.set_cursor_from_name(Some(if editing { "text" } else { "default" }));
        if view.is_editable() == editing {
            return;
        }
        view.set_editable(editing);
        view.set_cursor_visible(editing);
        if editing {
            view.set_focusable(true);
            // At the end, unless the click that started editing places it.
            let buffer = view.buffer();
            buffer.place_cursor(&buffer.end_iter());
            self.update_typing_style();
            // On idle: a new row isn't in the window yet, and a math source line may still be hidden.
            let view = view.downgrade();
            glib::idle_add_local_once(move || {
                if let Some(view) = view.upgrade().filter(|v| v.is_editable()) {
                    view.grab_focus();
                }
            });
        } else {
            let buffer = view.buffer();
            buffer.place_cursor(&buffer.start_iter());
            if view.has_focus() {
                if let Some(root) = view.root() {
                    gtk::prelude::RootExt::set_focus(&root, None::<&gtk::Widget>);
                }
            }
            view.set_focusable(false);
            // Clears the undo history: a block's typing can't be undone once it is confirmed.
            buffer.set_enable_undo(false);
            buffer.set_enable_undo(true);
            self.shown.replace(Some(self.content()));
        }
    }

    fn connect_buffer(self: &Rc<Self>) {
        let buffer = self.view.buffer();

        let editor = Rc::downgrade(self);
        buffer.connect_insert_text(move |_, _, _| {
            let Some(editor) = editor.upgrade() else { return };
            if editor.loading.get() {
                return;
            }
            editor.inserting.set(true);
        });

        // After the default handler: style what was just inserted, then report the edit.
        let editor = Rc::downgrade(self);
        buffer.connect_local("insert-text", true, move |values| {
            let editor = editor.upgrade()?;
            if editor.loading.get() || !editor.inserting.replace(false) {
                return None;
            }
            let buffer = values[0].get::<gtk::TextBuffer>().ok()?;
            let end = values[1].get::<gtk::TextIter>().ok()?;
            let text = values[2].get::<String>().ok()?;
            if editor.kind == Kind::RichText {
                let mut start = end;
                start.backward_chars(text.chars().count() as i32);
                let typing = editor.typing.get();
                for (tag, on) in editor.tags.iter().zip([typing.bold, typing.italic, typing.underline]) {
                    if on {
                        buffer.apply_tag(tag, &start, &end);
                    } else {
                        buffer.remove_tag(tag, &start, &end);
                    }
                }
            }
            editor.report_change();
            None
        });

        let editor = Rc::downgrade(self);
        buffer.connect_changed(move |_| {
            let Some(editor) = editor.upgrade() else { return };
            if !editor.loading.get() && !editor.inserting.get() {
                editor.report_change();
            }
        });

        // Moving the caret picks up the style of the text it lands in.
        let editor = Rc::downgrade(self);
        buffer.connect_mark_set(move |buffer, _, mark| {
            let Some(editor) = editor.upgrade() else { return };
            if *mark == buffer.get_insert() && !editor.loading.get() {
                editor.update_typing_style();
            }
        });

        let editor = Rc::downgrade(self);
        self.view.connect_preedit_changed(move |_, preedit| {
            if let Some(editor) = editor.upgrade() {
                editor.composing.set(!preedit.is_empty());
            }
        });
    }

    fn connect_keys(self: &Rc<Self>) {
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let editor = Rc::downgrade(self);
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            let Some(editor) = editor.upgrade() else { return glib::Propagation::Proceed };
            if !editor.view.is_editable() {
                return glib::Propagation::Proceed;
            }
            let shift = modifiers.contains(gdk::ModifierType::SHIFT_MASK);
            let control = modifiers.contains(gdk::ModifierType::CONTROL_MASK);
            // While an input method is composing, every key belongs to it.
            if editor.composing.get() {
                return glib::Propagation::Proceed;
            }
            match key {
                gdk::Key::Return | gdk::Key::KP_Enter | gdk::Key::ISO_Enter if shift => {
                    let buffer = editor.view.buffer();
                    buffer.delete_selection(true, true);
                    buffer.insert_interactive_at_cursor("\n", true);
                    glib::Propagation::Stop
                }
                gdk::Key::Return | gdk::Key::KP_Enter | gdk::Key::ISO_Enter | gdk::Key::Escape => {
                    editor.commit(key);
                    glib::Propagation::Stop
                }
                gdk::Key::b | gdk::Key::B if control && editor.kind == Kind::RichText => {
                    editor.toggle(0);
                    glib::Propagation::Stop
                }
                gdk::Key::i | gdk::Key::I if control && editor.kind == Kind::RichText => {
                    editor.toggle(1);
                    glib::Propagation::Stop
                }
                gdk::Key::u | gdk::Key::U if control && editor.kind == Kind::RichText => {
                    editor.toggle(2);
                    glib::Propagation::Stop
                }
                _ => glib::Propagation::Proceed,
            }
        });
        self.view.add_controller(keys);
    }

    fn commit(&self, key: gdk::Key) {
        if let Some(callback) = &*self.on_commit.borrow() {
            callback(key);
        }
    }

    /// With a selection, applies the style unless all of its start has it
    /// (then removes it); either way, text typed next follows.
    fn toggle(&self, which: usize) {
        let buffer = self.view.buffer();
        let tag = &self.tags[which];
        let mut typing = self.typing.get();
        let flag = match which {
            0 => &mut typing.bold,
            1 => &mut typing.italic,
            _ => &mut typing.underline,
        };
        if let Some((start, end)) = buffer.selection_bounds() {
            let add = !start.has_tag(tag);
            if add {
                buffer.apply_tag(tag, &start, &end);
            } else {
                buffer.remove_tag(tag, &start, &end);
            }
            *flag = add;
            self.report_change();
        } else {
            *flag = !*flag;
        }
        self.typing.set(typing);
    }

    /// The style of the character before the caret (or after it, at the very start).
    fn update_typing_style(&self) {
        let buffer = self.view.buffer();
        let mut at = buffer.iter_at_mark(&buffer.get_insert());
        if !at.is_start() {
            at.backward_char();
        }
        let has = |i: usize| at.has_tag(&self.tags[i]);
        self.typing.set(Style { bold: has(0), italic: has(1), underline: has(2) });
    }

    fn report_change(&self) {
        let content = self.content();
        self.shown.replace(Some(content.clone()));
        if let Some(callback) = &*self.on_change.borrow() {
            callback(content);
        }
    }

    /// Walks tag toggles; adjacent stretches with the same styles merge into one run.
    fn runs(&self) -> Vec<TextRun> {
        let buffer = self.view.buffer();
        let mut runs: Vec<TextRun> = vec![];
        let mut at = buffer.start_iter();
        while !at.is_end() {
            let mut next = at;
            next.forward_to_tag_toggle(None::<&gtk::TextTag>);
            let has = |i: usize| at.has_tag(&self.tags[i]);
            let run = TextRun { text: buffer.text(&at, &next, false).into(), bold: has(0), italic: has(1), underline: has(2) };
            match runs.last_mut() {
                Some(last) if last.same_style(&run) => last.text.push_str(&run.text),
                _ if run.text.is_empty() => {}
                _ => runs.push(run),
            }
            at = next;
        }
        runs
    }

    fn tags_for(&self, style: Style) -> impl Iterator<Item = &gtk::TextTag> {
        self.tags.iter().zip([style.bold, style.italic, style.underline]).filter(|(_, on)| *on).map(|(tag, _)| tag)
    }
}

fn style_of(run: &TextRun) -> Style {
    Style { bold: run.bold, italic: run.italic, underline: run.underline }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ctrl_z_undoes_typing() {
        if gtk::init().is_err() {
            return;
        }
        let editor = Editor::new(Kind::RichText);
        editor.show_content(&Content::Text(vec![TextRun { text: "hello".into(), ..Default::default() }]));
        editor.set_editing(true);
        let buffer = editor.view.buffer();
        eprintln!("can_undo before typing: {}", buffer.can_undo());
        buffer.insert_interactive_at_cursor(" world", true);
        eprintln!("text: {:?} can_undo: {}", editor.content(), buffer.can_undo());
        let ok = editor.view.activate_action("text.undo", None);
        eprintln!("activate text.undo: {:?}", ok);
        eprintln!("after undo: {:?}", editor.content());
        assert_eq!(editor.content(), Content::Text(vec![TextRun { text: "hello".into(), ..Default::default() }]));
    }
}
