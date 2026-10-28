//! Every block this device knows, merged from all devices' files in the sync
//! folder, matching `BlockStore.swift`. Each change is stamped (`modified_at`,
//! `modified_by`) so that, per block, the newest change wins everywhere.

use std::cell::{Cell, RefCell};
use std::fs;
use std::rc::{Rc, Weak};
use std::time::Duration;

use gtk::glib;
use gtk::prelude::*;
use gtk::gio;
use uuid::Uuid;

use crate::block::{self, Block, Content, Millis};
use crate::folder::{self, Signature, SyncFolder};
use crate::sync;

pub struct Store {
    folder: SyncFolder,
    /// Includes deleted blocks (tombstones) and kinds this build can't show.
    blocks: RefCell<Vec<Block>>,
    /// While a block is edited here, remote versions of it are ignored.
    editing: Cell<Option<Uuid>>,
    signature: RefCell<Signature>,
    unsaved: Cell<bool>,
    pending_save: RefCell<Option<glib::SourceId>>,
    monitors: RefCell<Vec<gio::FileMonitor>>,
    on_merged: RefCell<Option<Rc<dyn Fn()>>>,
    notify_queued: Rc<Cell<bool>>,
    /// Off when an unreadable own file couldn't be set aside: writing would destroy it.
    writable: Cell<bool>,
}

impl Store {
    pub fn open(folder: SyncFolder) -> Rc<Store> {
        let store = Rc::new(Store {
            folder,
            blocks: RefCell::new(vec![]),
            editing: Cell::new(None),
            signature: RefCell::new(Signature::new()),
            unsaved: Cell::new(false),
            pending_save: RefCell::new(None),
            monitors: RefCell::new(vec![]),
            on_merged: RefCell::new(None),
            notify_queued: Default::default(),
            writable: Cell::new(true),
        });
        let own = store.load_own();
        store.blocks.replace(own);
        store.merge_folder();
        store.start_watching();
        store
    }

    pub fn device(&self) -> &str {
        &self.folder.device
    }

    /// Called (on idle) when blocks change other than through this store's own methods:
    /// another device's edit, or a file replaced on disk.
    pub fn connect_merged(&self, callback: impl Fn() + 'static) {
        self.on_merged.replace(Some(Rc::new(callback)));
    }

    pub fn recent(&self) -> Vec<Block> {
        let mut blocks: Vec<Block> =
            self.blocks.borrow().iter().filter(|b| b.is_shown() && !b.is_archived()).cloned().collect();
        blocks.sort_by_key(|b| std::cmp::Reverse(b.surfaced_at));
        blocks
    }

    pub fn history(&self) -> Vec<Block> {
        let mut blocks: Vec<Block> =
            self.blocks.borrow().iter().filter(|b| b.is_shown() && b.is_archived()).cloned().collect();
        blocks.sort_by_key(|b| std::cmp::Reverse(b.archived_at));
        blocks
    }

    pub fn block(&self, id: Uuid) -> Option<Block> {
        self.blocks.borrow().iter().find(|b| b.id == id).cloned()
    }

    pub fn insert(self: &Rc<Self>, block: Block) {
        let block = self.stamped(block);
        self.blocks.borrow_mut().push(block);
        self.changed();
    }

    /// Replaces the stored block with the same id (state changes, tombstones, undo).
    pub fn put(self: &Rc<Self>, block: Block) {
        let block = self.stamped(block);
        self.replace(block);
    }

    /// Cheap enough to call per keystroke: writes to disk only once typing pauses.
    pub fn update(self: &Rc<Self>, id: Uuid, content: Content) {
        let Some(mut block) = self.block(id) else { return };
        block.content = content;
        block.last_used = block::now();
        self.put(block);
    }

    /// Not stamped: opening a block isn't a change worth winning a merge with.
    pub fn mark_used(self: &Rc<Self>, id: Uuid) {
        let Some(mut block) = self.block(id) else { return };
        block.last_used = block::now();
        self.replace(block);
    }

    /// Stamped by the minimum, so any real edit made elsewhere (that may not
    /// have arrived yet) still beats an automatic archive.
    pub fn archive_unused(self: &Rc<Self>, cutoff: Millis) {
        let now = block::now();
        let stale: Vec<Block> = self
            .blocks
            .borrow()
            .iter()
            .filter(|b| b.is_shown() && !b.is_archived() && b.last_used < cutoff)
            .cloned()
            .collect();
        for mut block in stale {
            block.archived_at = Some(now);
            block.modified_at += 1;
            block.modified_by = self.folder.device.clone();
            self.replace(block);
        }
        self.save_if_needed();
    }

    /// When editing ends, everything is merged again by the usual newest-wins rule.
    pub fn set_editing(self: &Rc<Self>, id: Option<Uuid>) {
        let previous = self.editing.replace(id);
        if previous.is_some() && previous != id {
            self.signature.take();
            if self.merge_folder() {
                self.queue_notify();
            }
        }
    }

    /// Folds in whatever is on disk first (a file copied in, a peer's latest),
    /// so a save never overwrites a change it hadn't seen.
    pub fn save_if_needed(&self) {
        if let Some(source) = self.pending_save.take() {
            source.remove();
        }
        if !self.unsaved.get() || !self.writable.get() {
            return;
        }
        let others = self.folder.read_others();
        let mut on_disk = self.folder.read_own().ok().flatten().unwrap_or_default();
        on_disk.extend(others.iter().cloned());
        let current = self.blocks.borrow().clone();
        let settled = sync::pruned(sync::merge(current.clone(), on_disk, self.editing.get()), &others, block::now());
        if settled != sync::ordered(current) {
            self.blocks.replace(settled);
            self.queue_notify();
        }
        match self.folder.write(&self.blocks.borrow()) {
            Ok(()) => {
                self.unsaved.set(false);
                self.signature.replace(self.folder.signature());
            }
            Err(error) => glib::g_warning!("contexts", "Saving blocks failed: {error}"),
        }
    }

    /// Pulls in every file's changes (other devices', and this device's own if
    /// it was replaced on disk). Returns whether anything changed.
    fn merge_folder(self: &Rc<Self>) -> bool {
        let signature = self.folder.signature();
        if *self.signature.borrow() == signature {
            return false;
        }
        self.signature.replace(signature);
        let mut on_disk = self.folder.read_own().ok().flatten().unwrap_or_default();
        on_disk.extend(self.folder.read_others());
        let current = self.blocks.borrow().clone();
        let merged = sync::merge(current.clone(), on_disk, self.editing.get());
        if merged == sync::ordered(current) {
            return false;
        }
        self.blocks.replace(merged);
        // Writes the merged view so all files converge.
        self.changed();
        true
    }

    /// The folder can be replaced (copied over, deleted and re-created, re-shared);
    /// the watch then follows the new one and the store re-syncs with it.
    fn start_watching(self: &Rc<Self>) {
        if let Err(error) = fs::create_dir_all(&self.folder.path) {
            glib::g_warning!("contexts", "Creating {} failed: {error}", self.folder.path.display());
        }
        let on_change = weak(self, |store| {
            if store.merge_folder() {
                store.queue_notify();
            }
        });
        // Deferred: the monitors are replaced from inside their own signal.
        let on_gone = weak(self, |store| {
            let store = Rc::downgrade(&store);
            glib::idle_add_local_once(move || {
                let Some(store) = store.upgrade() else { return };
                for monitor in store.monitors.take() {
                    monitor.cancel();
                }
                store.signature.take();
                store.start_watching();
                store.merge_folder();
                store.unsaved.set(true);
                store.save_if_needed();
                store.queue_notify();
            });
        });
        self.monitors.replace(folder::watch(&self.folder.path, on_change, on_gone));
    }

    fn replace(self: &Rc<Self>, block: Block) {
        let mut blocks = self.blocks.borrow_mut();
        let Some(slot) = blocks.iter_mut().find(|b| b.id == block.id) else { return };
        *slot = block;
        drop(blocks);
        self.changed();
    }

    /// `modified_at` always moves forward, even if this clock is behind the last writer's.
    fn stamped(&self, mut block: Block) -> Block {
        let previous = self.block(block.id).map_or(0, |b| b.modified_at);
        block.modified_at = block::now().max(previous + 1);
        block.modified_by = self.folder.device.clone();
        block
    }

    fn changed(self: &Rc<Self>) {
        self.unsaved.set(true);
        if let Some(source) = self.pending_save.take() {
            source.remove();
        }
        let store = Rc::downgrade(self);
        self.pending_save.replace(Some(glib::timeout_add_local_once(Duration::from_secs(1), move || {
            let Some(store) = store.upgrade() else { return };
            store.pending_save.take();
            store.save_if_needed();
        })));
    }

    fn queue_notify(&self) {
        if self.notify_queued.replace(true) {
            return;
        }
        let Some(callback) = self.on_merged.borrow().clone() else {
            self.notify_queued.set(false);
            return;
        };
        let queued = self.notify_queued.clone();
        glib::idle_add_local_once(move || {
            queued.set(false);
            callback();
        });
    }

    /// An unreadable own file is set aside rather than silently overwritten.
    fn load_own(&self) -> Vec<Block> {
        match self.folder.read_own() {
            Ok(own) => own.unwrap_or_default(),
            Err(error) => {
                glib::g_warning!("contexts", "Loading blocks failed: {error}");
                let stamp = block::now() / 1000;
                let file = self.folder.own_file();
                let backup = file.with_extension(format!("unreadable-{stamp}.json"));
                if let Err(error) = fs::rename(&file, &backup).or_else(|_| fs::copy(&file, &backup).map(drop)) {
                    glib::g_warning!("contexts", "Setting aside {} failed, so nothing will be saved: {error}", file.display());
                    self.writable.set(false);
                }
                vec![]
            }
        }
    }
}

fn weak(store: &Rc<Store>, action: impl Fn(Rc<Store>) + 'static) -> impl Fn() + 'static {
    let store: Weak<Store> = Rc::downgrade(store);
    move || {
        if let Some(store) = store.upgrade() {
            action(store);
        }
    }
}
