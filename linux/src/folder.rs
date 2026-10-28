//! The folder shared between devices (e.g. via Syncthing), matching
//! `SyncFolder.swift`. Every device writes only its own `blocks-<device>.json`
//! and reads everyone's, so no file ever has two writers.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, SystemTime};

use gtk::{gio, glib};
use gtk::prelude::*;
use serde_json::{json, Value};

use crate::block::Block;
use crate::config;

pub const SCHEMA: i64 = 2;

/// Each device file's (modified time, size), to tell real changes apart from this device's own writes.
pub type Signature = BTreeMap<String, Option<(SystemTime, u64)>>;

pub struct SyncFolder {
    pub path: PathBuf,
    pub device: String,
    logged_conflicts: RefCell<HashSet<String>>,
}

impl SyncFolder {
    pub fn new(path: PathBuf, device: String) -> SyncFolder {
        SyncFolder { path, device, logged_conflicts: Default::default() }
    }

    /// `~/Contexts` as device `ubuntu`, unless overridden (see `config`).
    pub fn standard() -> SyncFolder {
        SyncFolder::new(config::folder(), config::device())
    }

    pub fn own_file(&self) -> PathBuf {
        self.path.join(format!("blocks-{}.json", self.device))
    }

    /// None when this device has no file yet; an error when it exists but can't be read.
    pub fn read_own(&self) -> io::Result<Option<Vec<Block>>> {
        match fs::read(self.own_file()) {
            Ok(data) => decode(&data).map(Some),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// Other devices' blocks. An unreadable file is skipped (and left alone): it
    /// is someone else's, possibly mid-sync.
    pub fn read_others(&self) -> Vec<Block> {
        self.other_files()
            .into_iter()
            .flat_map(|file| match fs::read(&file).and_then(|data| decode(&data)) {
                Ok(blocks) => blocks,
                Err(error) => {
                    glib::g_warning!("contexts", "Skipping {}: {error}", file.display());
                    vec![]
                }
            })
            .collect()
    }

    pub fn signature(&self) -> Signature {
        let mut files = self.other_files();
        files.push(self.own_file());
        files
            .into_iter()
            .map(|file| {
                let stamp = fs::metadata(&file).ok().and_then(|m| Some((m.modified().ok()?, m.len())));
                (file.file_name().unwrap_or_default().to_string_lossy().into_owned(), stamp)
            })
            .collect()
    }

    /// Writes a predictable temp file, flushes it, then renames it over the real
    /// one, so readers (and Syncthing) only ever see a complete file.
    pub fn write(&self, blocks: &[Block]) -> io::Result<()> {
        fs::create_dir_all(&self.path)?;
        let temp = self.path.join(format!(".blocks-{}.json.tmp", self.device));
        let mut file = fs::File::create(&temp)?;
        file.write_all(encode(&self.device, blocks).as_bytes())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, self.own_file())
    }

    fn other_files(&self) -> Vec<PathBuf> {
        let own = format!("blocks-{}.json", self.device);
        let Ok(entries) = fs::read_dir(&self.path) else { return vec![] };
        let mut files: Vec<PathBuf> = entries
            .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
            .filter(|name| name.starts_with("blocks-") && name.ends_with(".json") && *name != own)
            .filter(|name| {
                let conflict = name.contains(".sync-conflict-");
                if conflict && self.logged_conflicts.borrow_mut().insert(name.clone()) {
                    glib::g_message!("contexts", "Ignoring Syncthing conflict file {name}");
                }
                !conflict
            })
            .map(|name| self.path.join(name))
            .collect();
        files.sort();
        files
    }
}

/// Pretty-printed with sorted keys, like the Mac's files.
pub fn encode(device: &str, blocks: &[Block]) -> String {
    let file = json!({
        "schema": SCHEMA,
        "device": device,
        "blocks": blocks.iter().map(Block::to_json).collect::<Vec<_>>(),
    });
    serde_json::to_string_pretty(&file).expect("JSON values always serialize")
}

/// One malformed block doesn't take the whole file down with it.
pub fn decode(data: &[u8]) -> io::Result<Vec<Block>> {
    let invalid = |message: &str| io::Error::new(io::ErrorKind::InvalidData, message.to_owned());
    let value: Value = serde_json::from_slice(data).map_err(|e| invalid(&e.to_string()))?;
    let file = value.as_object().ok_or_else(|| invalid("not an object"))?;
    file.get("schema").and_then(Value::as_i64).ok_or_else(|| invalid("no schema"))?;
    file.get("device").and_then(Value::as_str).ok_or_else(|| invalid("no device"))?;
    let blocks = file.get("blocks").and_then(Value::as_array).ok_or_else(|| invalid("no blocks"))?;
    Ok(blocks.iter().filter_map(Block::from_json).collect())
}

/// Calls `on_change` (debounced) when anything in the folder changes, and
/// `on_gone` right away when the folder itself is deleted, moved or replaced,
/// since it then needs watching anew. Watches the directory rather than files:
/// sync tools replace files by renaming. Keep the returned monitors alive.
pub fn watch(path: &Path, on_change: impl Fn() + 'static, on_gone: impl Fn() + 'static) -> Vec<gio::FileMonitor> {
    let folder = gio::File::for_path(path);
    let pending: Rc<RefCell<Option<glib::SourceId>>> = Default::default();
    let cancel = {
        let pending = pending.clone();
        move || {
            if let Some(source) = pending.take() {
                source.remove();
            }
        }
    };
    let on_gone = Rc::new(on_gone);
    let mut monitors = vec![];

    if let Ok(monitor) = folder.monitor_directory(gio::FileMonitorFlags::WATCH_MOVES, gio::Cancellable::NONE) {
        monitor.set_rate_limit(200);
        let on_change = Rc::new(on_change);
        let (folder, on_gone, cancel) = (folder.clone(), on_gone.clone(), cancel.clone());
        monitor.connect_changed(move |_, file, _, event| {
            cancel();
            if file.equal(&folder) && is_gone(event) {
                on_gone();
                return;
            }
            let (pending_ref, on_change) = (pending.clone(), on_change.clone());
            pending.replace(Some(glib::timeout_add_local_once(Duration::from_millis(150), move || {
                pending_ref.take();
                on_change();
            })));
        });
        monitors.push(monitor);
    }

    // Moving the folder away reports nothing on the folder itself, so its
    // parent watches for the name being moved, deleted or created.
    if let Some(parent) = folder.parent() {
        if let Ok(monitor) = parent.monitor_directory(gio::FileMonitorFlags::WATCH_MOVES, gio::Cancellable::NONE) {
            monitor.connect_changed(move |_, file, other, event| {
                let touches = file.equal(&folder) || other.is_some_and(|o| o.equal(&folder));
                let replaces = matches!(event, gio::FileMonitorEvent::Created | gio::FileMonitorEvent::MovedIn);
                if touches && (replaces || is_gone(event)) {
                    cancel();
                    on_gone();
                }
            });
            monitors.push(monitor);
        }
    }
    monitors
}

fn is_gone(event: gio::FileMonitorEvent) -> bool {
    matches!(
        event,
        gio::FileMonitorEvent::Deleted
            | gio::FileMonitorEvent::MovedOut
            | gio::FileMonitorEvent::Renamed
            | gio::FileMonitorEvent::Unmounted
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block::{Content, TextRun};

    fn folder(dir: &Path, device: &str) -> SyncFolder {
        SyncFolder::new(dir.to_owned(), device.into())
    }

    #[test]
    fn writes_the_shared_format() {
        let dir = tempfile::tempdir().unwrap();
        let runs = vec![TextRun { text: "a".into(), ..Default::default() }];
        let block = Block::new(Content::Text(runs), "ubuntu", 5);
        folder(dir.path(), "ubuntu").write(std::slice::from_ref(&block)).unwrap();

        let names: Vec<_> = fs::read_dir(dir.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names, ["blocks-ubuntu.json"]);
        let raw: Value = serde_json::from_slice(&fs::read(dir.path().join("blocks-ubuntu.json")).unwrap()).unwrap();
        assert_eq!(raw["schema"], 2);
        assert_eq!(raw["device"], "ubuntu");
        let written = &raw["blocks"][0];
        assert_eq!(written["id"], block.id.to_string());
        assert_eq!(written["runs"], json!([{"t": "a"}]));
        assert!(written["archivedAt"].is_null() && written.as_object().unwrap().contains_key("archivedAt"));
        assert_eq!(written["modifiedAt"], 5);
    }

    #[test]
    fn reads_others_and_skips_conflicts_and_bad_files() {
        let dir = tempfile::tempdir().unwrap();
        let block = Block::new(Content::Math("x".into()), "mac", 1);
        folder(dir.path(), "mac").write(std::slice::from_ref(&block)).unwrap();
        fs::write(dir.path().join("blocks-mac.sync-conflict-20261027-1234.json"), encode("mac", std::slice::from_ref(&block))).unwrap();
        fs::write(dir.path().join("blocks-broken.json"), "{").unwrap();

        let ubuntu = folder(dir.path(), "ubuntu");
        assert_eq!(ubuntu.read_others(), vec![block]);
        assert_eq!(ubuntu.read_own().unwrap(), None);
        fs::write(ubuntu.own_file(), "nope").unwrap();
        assert!(ubuntu.read_own().is_err());
    }

    #[test]
    fn skips_malformed_blocks_only() {
        let good = Block::new(Content::Math("x".into()), "mac", 1).to_json();
        let data = json!({"schema": 2, "device": "mac", "blocks": [good, {"id": "x"}]}).to_string();
        assert_eq!(decode(data.as_bytes()).unwrap().len(), 1);
        assert!(decode(br#"{"blocks": []}"#).is_err());
    }

    #[test]
    fn signature_changes_with_files() {
        let dir = tempfile::tempdir().unwrap();
        let mac = folder(dir.path(), "mac");
        let ubuntu = folder(dir.path(), "ubuntu");
        let before = ubuntu.signature();
        mac.write(&[]).unwrap();
        assert_ne!(ubuntu.signature(), before);
    }
}
