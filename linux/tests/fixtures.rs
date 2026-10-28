//! The merge cases in `fixtures/sync-v2/`, shared with the Mac app's tests.
//! Each case merges its device files (as `case.json`'s device, default
//! `ubuntu`) and must match `expected.json` as data, not bytes.

use std::fs;
use std::path::Path;

use contexts::block;
use contexts::folder::SyncFolder;
use contexts::sync;
use serde_json::Value;

#[test]
fn shared_fixtures() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures/sync-v2");
    let mut cases: Vec<_> = fs::read_dir(&root).unwrap().map(|e| e.unwrap().path()).collect();
    cases.sort();
    assert!(cases.len() >= 7, "fixtures missing");
    for case in cases {
        let meta: Value = fs::read(case.join("case.json")).map_or(Value::Null, |d| serde_json::from_slice(&d).unwrap());
        let device = meta["device"].as_str().unwrap_or("ubuntu").to_owned();
        let now = meta["now"].as_i64().unwrap_or_else(block::now);

        let folder = SyncFolder::new(case.clone(), device);
        let own = folder.read_own().unwrap().unwrap_or_default();
        let others = folder.read_others();
        let merged = sync::merge(own.clone(), own.into_iter().chain(others.clone()), None);
        let settled = sync::pruned(merged, &others, now);

        let actual = normalized(settled.iter().map(block::Block::to_json).collect());
        let expected: Value = serde_json::from_slice(&fs::read(case.join("expected.json")).unwrap()).unwrap();
        let expected = normalized(expected["blocks"].as_array().unwrap().clone());
        assert_eq!(actual, expected, "case {}", case.file_name().unwrap().to_string_lossy());
    }
}

/// Sorted by lowercased id, with missing `archivedAt`/`deletedAt` as null.
fn normalized(mut blocks: Vec<Value>) -> Vec<Value> {
    for block in &mut blocks {
        let fields = block.as_object_mut().unwrap();
        let id = fields["id"].as_str().unwrap().to_lowercase();
        fields.insert("id".into(), id.into());
        for key in ["archivedAt", "deletedAt"] {
            fields.entry(key).or_insert(Value::Null);
        }
    }
    blocks.sort_by_key(|b| b["id"].as_str().unwrap().to_owned());
    blocks
}
