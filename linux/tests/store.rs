//! The store against a real folder and the GLib main loop: stamping, the
//! debounced save, the folder watch and the editing protection.

use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

use contexts::block::{self, Block, Content, TextRun};
use contexts::folder::SyncFolder;
use contexts::store::Store;
use gtk::glib;

/// One test on one thread: the store's GLib sources belong to the default
/// main context, and values made on one thread must not be dropped on another.
#[test]
fn store() {
    let context = glib::MainContext::default();
    let _guard = context.acquire().unwrap();
    stamps_every_user_change();
    saves_once_typing_pauses_and_merges_on_open();
    follows_remote_changes_except_while_editing();
    rewrites_its_file_when_the_folder_is_replaced();
}

/// Runs the main loop until `done` or the timeout.
fn spin_until(timeout: Duration, mut done: impl FnMut() -> bool) -> bool {
    let context = glib::MainContext::default();
    let start = Instant::now();
    while start.elapsed() < timeout {
        while context.iteration(false) {}
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    done()
}

fn text(t: &str) -> Content {
    Content::Text(vec![TextRun { text: t.into(), ..Default::default() }])
}

fn mac_file(dir: &Path, blocks: &[Block]) {
    SyncFolder::new(dir.to_owned(), "mac".into()).write(blocks).unwrap();
}

fn stamps_every_user_change() {
    let dir = tempfile::tempdir().unwrap();
    // The Mac's clock runs a minute ahead of this one.
    let mut future = Block::new(text("a"), "mac", 0);
    future.modified_at = block::now() + 60_000;
    mac_file(dir.path(), &[future.clone()]);
    let store = Store::open(SyncFolder::new(dir.path().to_owned(), "ubuntu".into()));

    store.update(future.id, text("b"));
    let edited = store.block(future.id).unwrap();
    assert_eq!(edited.modified_at, future.modified_at + 1, "moves forward past a clock ahead of ours");
    assert_eq!(edited.modified_by, "ubuntu");

    let fresh = Block::new(text("new"), "ubuntu", 0);
    store.insert(fresh.clone());
    assert!(store.block(fresh.id).unwrap().modified_at >= block::now() - 1_000);

    let before = store.block(future.id).unwrap();
    store.mark_used(future.id);
    let used = store.block(future.id).unwrap();
    assert_eq!((used.modified_at, &used.modified_by), (before.modified_at, &before.modified_by));

    store.archive_unused(block::now() + 1);
    let archived = store.block(future.id).unwrap();
    assert!(archived.is_archived());
    assert_eq!(archived.modified_at, before.modified_at + 1, "auto-archive stamps by the minimum");
    assert_eq!(store.history().len(), 2);
    assert!(store.recent().is_empty());
}

fn saves_once_typing_pauses_and_merges_on_open() {
    let dir = tempfile::tempdir().unwrap();
    let theirs = Block::new(text("from mac"), "mac", 10);
    mac_file(dir.path(), std::slice::from_ref(&theirs));

    let store = Store::open(SyncFolder::new(dir.path().to_owned(), "ubuntu".into()));
    assert_eq!(store.recent(), vec![theirs.clone()]);

    let own = dir.path().join("blocks-ubuntu.json");
    assert!(spin_until(Duration::from_secs(3), || own.exists()), "merged view written after the debounce");
    let written = SyncFolder::new(dir.path().to_owned(), "ubuntu".into()).read_own().unwrap().unwrap();
    assert_eq!(written, vec![theirs]);
    assert!(!dir.path().join(".blocks-ubuntu.json.tmp").exists());
}

fn follows_remote_changes_except_while_editing() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(SyncFolder::new(dir.path().to_owned(), "ubuntu".into()));
    let block = Block::new(text("mine"), "ubuntu", 1);
    store.insert(block.clone());
    store.save_if_needed();
    let mine = store.block(block.id).unwrap();

    // Another device edits it while it's being edited here: ignored for now.
    store.set_editing(Some(block.id));
    let mut theirs = mine.clone();
    theirs.content = text("theirs");
    theirs.modified_at += 10;
    theirs.modified_by = "mac".into();
    mac_file(dir.path(), std::slice::from_ref(&theirs));
    spin_until(Duration::from_millis(600), || false);
    assert_eq!(store.block(block.id).unwrap().content, text("mine"));

    // Editing ends without a change here, so the newer remote edit wins.
    store.set_editing(None);
    assert_eq!(store.block(block.id).unwrap().content, text("theirs"));

    // And a later remote change arrives through the folder watch.
    let mut later = theirs.clone();
    later.content = text("later");
    later.modified_at += 10;
    mac_file(dir.path(), &[later]);
    assert!(spin_until(Duration::from_secs(2), || store.block(block.id).unwrap().content == text("later")));
}

fn rewrites_its_file_when_the_folder_is_replaced() {
    let parent = tempfile::tempdir().unwrap();
    let dir = parent.path().join("Contexts");
    let store = Store::open(SyncFolder::new(dir.clone(), "ubuntu".into()));
    let block = Block::new(text("keep me"), "ubuntu", 1);
    store.insert(block.clone());
    store.save_if_needed();

    fs::rename(&dir, parent.path().join("Contexts.old")).unwrap();
    fs::create_dir(&dir).unwrap();
    let own = dir.join("blocks-ubuntu.json");
    assert!(spin_until(Duration::from_secs(3), || own.exists()), "own file rewritten into the new folder");

    // The new folder is watched too.
    let theirs = Block::new(text("new folder"), "mac", 2);
    mac_file(&dir, std::slice::from_ref(&theirs));
    assert!(spin_until(Duration::from_secs(2), || store.block(theirs.id).is_some()));
    assert!(store.block(block.id).is_some());
}
