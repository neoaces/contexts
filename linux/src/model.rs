//! UI state and intents for the panel, ported from `PanelModel.swift`.
//! Window concerns live in `panel.rs`; views read `state()` and call intents.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

use contexts::block::{self, Block, Content, Millis};
use contexts::config;
use contexts::store::Store;
use gtk::{gdk, glib};
use uuid::Uuid;

const UNDO_LEVELS: usize = 20;
const UNDO_OFFER: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Tab {
    #[default]
    Recent,
    History,
}

/// What the plus button offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NewBlock {
    Text,
    Math,
}

#[derive(Clone, Debug, Default)]
pub struct State {
    pub presented: bool,
    /// Near the bottom of the screen the list grows upward from the header instead.
    pub upward: bool,
    /// Pinned: parked at the top-right and stays open.
    pub pinned: bool,
    pub tab: Tab,
    pub choosing_new_block: bool,
    pub editing_list: bool,
    pub pending_deletion: Option<Uuid>,
    pub editing: Option<Uuid>,
    /// Name of the action the undo button would reverse, while it is offered.
    pub undoable_action: Option<&'static str>,
}

#[derive(Clone, Copy, PartialEq)]
enum UndoMode {
    Normal,
    Undoing,
    Redoing,
}

pub struct Model {
    pub store: Rc<Store>,
    state: RefCell<State>,
    /// What the edited block held when editing began, so clearing it out can be undone.
    content_before_editing: RefCell<Option<Content>>,
    /// Block-level undo (delete, restore): each entry is the state to swap back to.
    undo_stack: RefCell<Vec<(Block, &'static str)>>,
    redo_stack: RefCell<Vec<(Block, &'static str)>>,
    undo_mode: Cell<UndoMode>,
    undo_expiry: RefCell<Option<glib::SourceId>>,
    /// A Return or Escape that just confirmed a block; its repeats are ignored until release.
    pub held_commit_key: Cell<Option<gdk::Key>>,
    on_change: RefCell<Option<Rc<dyn Fn()>>>,
    on_dismiss: RefCell<Option<Rc<dyn Fn()>>>,
}

impl Model {
    pub fn new(store: Rc<Store>) -> Rc<Model> {
        let model = Rc::new(Model {
            store,
            state: Default::default(),
            content_before_editing: Default::default(),
            undo_stack: Default::default(),
            redo_stack: Default::default(),
            undo_mode: Cell::new(UndoMode::Normal),
            undo_expiry: Default::default(),
            held_commit_key: Cell::new(None),
            on_change: Default::default(),
            on_dismiss: Default::default(),
        });
        let weak = Rc::downgrade(&model);
        model.store.connect_merged(move || {
            if let Some(model) = weak.upgrade() {
                model.changed();
            }
        });
        model
    }

    /// Views re-sync from `state()` and `listed()`.
    pub fn connect_changed(&self, callback: impl Fn() + 'static) {
        self.on_change.replace(Some(Rc::new(callback)));
    }

    /// Asks the extension to hide the panel.
    pub fn connect_dismiss(&self, callback: impl Fn() + 'static) {
        self.on_dismiss.replace(Some(Rc::new(callback)));
    }

    pub fn state(&self) -> State {
        self.state.borrow().clone()
    }

    pub fn listed(&self) -> Vec<Block> {
        match self.state.borrow().tab {
            Tab::Recent => self.store.recent(),
            Tab::History => self.store.history(),
        }
    }

    // Presentation

    pub fn present(self: &Rc<Self>, upward: bool) {
        self.archive_unused();
        if self.state.borrow().undoable_action.is_some() {
            self.offer_undo();
        }
        self.update(|s| {
            reset_transient(s);
            s.upward = upward;
            s.presented = true;
        });
    }

    /// The panel has left the screen. The undo offer survives, so a delete just
    /// before the pointer left can still be reversed.
    pub fn hidden(self: &Rc<Self>) {
        self.commit_editing();
        if let Some(source) = self.undo_expiry.take() {
            source.remove();
        }
        self.update(|s| {
            reset_transient(s);
            s.presented = false;
            s.choosing_new_block = false;
            s.pinned = false;
        });
    }

    /// Escape outside a text block closes the innermost open state.
    pub fn cancel(self: &Rc<Self>) {
        let state = self.state();
        if state.choosing_new_block {
            self.toggle_new_block_options();
        } else if state.editing_list {
            self.toggle_list_editing();
        } else if state.tab == Tab::History {
            self.show(Tab::Recent);
        } else {
            self.dismiss();
        }
    }

    pub fn dismiss(&self) {
        let callback = self.on_dismiss.borrow().clone();
        if let Some(callback) = callback {
            callback();
        }
    }

    pub fn toggle_pin(self: &Rc<Self>) {
        self.update(|s| {
            s.pinned = !s.pinned;
            if s.pinned {
                s.upward = false;
            }
        });
    }

    pub fn show(self: &Rc<Self>, tab: Tab) {
        self.commit_editing();
        self.update(|s| {
            s.editing_list = false;
            s.pending_deletion = None;
            s.tab = tab;
        });
    }

    // Creating

    pub fn toggle_new_block_options(self: &Rc<Self>) {
        self.update(|s| {
            s.editing_list = false;
            s.pending_deletion = None;
            s.choosing_new_block = !s.choosing_new_block;
        });
    }

    pub fn create(self: &Rc<Self>, option: NewBlock) {
        self.commit_editing();
        let content = match option {
            NewBlock::Text => Content::Text(vec![]),
            NewBlock::Math => Content::Math(String::new()),
        };
        let block = Block::new(content, self.store.device(), block::now());
        self.store.insert(block.clone());
        self.store.set_editing(Some(block.id));
        self.update(|s| {
            s.choosing_new_block = false;
            s.tab = Tab::Recent;
            s.editing = Some(block.id);
        });
    }

    // Editing

    /// A click on a block. Returns whether it should start editing in place:
    /// in delete mode a click only disarms, and in History it restores the block.
    pub fn activate(self: &Rc<Self>, id: Uuid) -> bool {
        let state = self.state();
        if state.editing_list || state.pending_deletion.is_some() {
            self.update(|s| s.pending_deletion = None);
            return false;
        }
        if state.tab == Tab::History {
            self.restore(id);
            return false;
        }
        if state.editing == Some(id) {
            return true;
        }
        self.commit_editing();
        self.store.mark_used(id);
        self.content_before_editing.replace(self.store.block(id).map(|b| b.content));
        self.store.set_editing(Some(id));
        self.update(|s| {
            s.choosing_new_block = false;
            s.editing = Some(id);
        });
        true
    }

    /// Per keystroke; the store writes once typing pauses.
    pub fn edit(&self, id: Uuid, content: Content) {
        let store = self.store.clone();
        store.update(id, content);
    }

    /// Ends editing from the user's side (Return, Escape, clicking elsewhere).
    pub fn end_editing(self: &Rc<Self>) {
        self.commit_editing();
    }

    pub fn prepare_for_termination(self: &Rc<Self>) {
        self.commit_editing();
        self.store.save_if_needed();
    }

    // Deleting, restoring, undo

    pub fn toggle_list_editing(self: &Rc<Self>) {
        self.commit_editing();
        self.update(|s| {
            s.choosing_new_block = false;
            s.pending_deletion = None;
            s.editing_list = !s.editing_list;
        });
    }

    pub fn toggle_deletion(self: &Rc<Self>, id: Uuid) {
        self.update(|s| s.pending_deletion = if s.pending_deletion == Some(id) { None } else { Some(id) });
    }

    pub fn delete(self: &Rc<Self>, id: Uuid) {
        let Some(mut block) = self.store.block(id) else { return };
        block.deleted_at = Some(block::now());
        self.apply(block, "Delete");
        let empty = self.listed().is_empty();
        self.update(|s| {
            s.pending_deletion = None;
            if empty {
                s.editing_list = false;
            }
        });
        self.offer_undo();
    }

    pub fn restore(self: &Rc<Self>, id: Uuid) {
        let Some(mut block) = self.store.block(id) else { return };
        let now = block::now();
        block.archived_at = None;
        block.last_used = now;
        block.surfaced_at = now;
        self.apply(block, "Restore");
        self.update(|s| s.tab = Tab::Recent);
        self.offer_undo();
    }

    pub fn undo(self: &Rc<Self>) {
        self.commit_editing();
        let Some((block, name)) = self.undo_stack.borrow_mut().pop() else { return };
        self.undo_mode.set(UndoMode::Undoing);
        self.apply(block, name);
        self.undo_mode.set(UndoMode::Normal);
    }

    pub fn redo(self: &Rc<Self>) {
        self.commit_editing();
        let Some((block, name)) = self.redo_stack.borrow_mut().pop() else { return };
        self.undo_mode.set(UndoMode::Redoing);
        self.apply(block, name);
        self.undo_mode.set(UndoMode::Normal);
    }

    // Private

    /// Stores `block`'s state (deleted, archived, where it sits in Recent) and
    /// registers the exact inverse, so undo and redo are the same operation.
    /// Only state swaps: text typed in between is kept.
    fn apply(self: &Rc<Self>, mut block: Block, name: &'static str) {
        let Some(previous) = self.store.block(block.id) else { return };
        block.content = previous.content.clone();
        self.store.put(block);
        self.store.save_if_needed();
        let mode = self.undo_mode.get();
        if mode != UndoMode::Normal {
            self.update(|s| s.undoable_action = None);
        }
        let entry = (previous, name);
        match mode {
            UndoMode::Undoing => self.redo_stack.borrow_mut().push(entry),
            UndoMode::Redoing => self.undo_stack.borrow_mut().push(entry),
            UndoMode::Normal => {
                self.undo_stack.borrow_mut().push(entry);
                self.redo_stack.borrow_mut().clear();
            }
        }
        let mut stack = self.undo_stack.borrow_mut();
        if stack.len() > UNDO_LEVELS {
            stack.remove(0);
        }
        drop(stack);
        self.changed();
    }

    fn offer_undo(self: &Rc<Self>) {
        let name = self.undo_stack.borrow().last().map(|(_, name)| *name);
        self.update(|s| s.undoable_action = name);
        if let Some(source) = self.undo_expiry.take() {
            source.remove();
        }
        let weak = Rc::downgrade(self);
        self.undo_expiry.replace(Some(glib::timeout_add_local_once(UNDO_OFFER, move || {
            let Some(model) = weak.upgrade() else { return };
            model.undo_expiry.take();
            model.update(|s| s.undoable_action = None);
        })));
    }

    /// Blocks untouched for the configured interval move to History before the panel shows.
    fn archive_unused(&self) {
        let Some(interval) = config::archive_after() else { return };
        self.store.archive_unused(block::now() - interval.as_millis() as Millis);
    }

    /// A new block left empty is discarded silently. An existing block that was
    /// cleared out is deleted as an undoable action, keeping its previous text.
    fn commit_editing(self: &Rc<Self>) {
        let Some(id) = self.state.borrow().editing else { return };
        let original = self.content_before_editing.take();
        // Re-stamp a changed block so this edit beats anything that arrived
        // mid-edit; clearing the editing id then merges those remote changes in.
        if let Some(current) = self.store.block(id).map(|b| b.content) {
            if Some(&current) != original.as_ref() {
                self.store.update(id, current);
            }
        }
        self.update(|s| s.editing = None);
        self.store.set_editing(None);
        if let Some(mut block) = self.store.block(id).filter(Block::is_blank) {
            match original.filter(|o| !o.is_blank()) {
                Some(original) => {
                    self.store.update(id, original);
                    self.delete(id);
                }
                None => {
                    block.deleted_at = Some(block::now());
                    self.store.put(block);
                }
            }
        }
        self.store.save_if_needed();
        self.changed();
    }

    fn update(&self, change: impl FnOnce(&mut State)) {
        change(&mut self.state.borrow_mut());
        self.changed();
    }

    fn changed(&self) {
        let callback = self.on_change.borrow().clone();
        if let Some(callback) = callback {
            callback();
        }
    }
}

fn reset_transient(state: &mut State) {
    state.editing_list = false;
    state.pending_deletion = None;
    state.tab = Tab::Recent;
}

#[cfg(test)]
mod tests {
    use super::*;
    use contexts::block::TextRun;
    use contexts::folder::SyncFolder;

    #[test]
    fn undo_reverses_delete_and_restore() {
        let context = glib::MainContext::default();
        let _guard = context.acquire().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(SyncFolder::new(dir.path().to_owned(), "ubuntu".into()));
        let model = Model::new(store.clone());
        model.present(false);
        model.create(NewBlock::Text);
        let id = model.state().editing.unwrap();
        model.edit(id, Content::Text(vec![TextRun { text: "hi".into(), ..Default::default() }]));
        model.end_editing();
        assert_eq!(model.listed().len(), 1);

        model.toggle_list_editing();
        model.toggle_deletion(id);
        model.delete(id);
        assert!(model.listed().is_empty());
        assert_eq!(model.state().undoable_action, Some("Delete"));

        model.undo();
        assert_eq!(model.listed().len(), 1, "undo brings the block back");
        model.redo();
        assert!(model.listed().is_empty(), "redo deletes it again");
    }
}
