//! The merge rule both apps implement identically (see `BlockStore.swift`):
//! per block, the newest change wins.

use std::collections::{HashMap, HashSet};

use uuid::Uuid;

use crate::block::{Block, Millis};

pub const TOMBSTONE_LIFETIME: Millis = 90 * 24 * 60 * 60 * 1000;

/// `local` first (keeping the newer of any duplicates), then each newer remote
/// version. The block being edited (`protecting`) ignores remote versions.
pub fn merge(local: Vec<Block>, remote: impl IntoIterator<Item = Block>, protecting: Option<Uuid>) -> Vec<Block> {
    let mut merged: HashMap<Uuid, Block> = HashMap::new();
    for block in local {
        match merged.get(&block.id) {
            Some(current) if !block.supersedes(current) => {}
            _ => {
                merged.insert(block.id, block);
            }
        }
    }
    for block in remote {
        if Some(block.id) == protecting {
            continue;
        }
        match merged.get(&block.id) {
            Some(current) if !block.supersedes(current) => {}
            _ => {
                merged.insert(block.id, block);
            }
        }
    }
    ordered(merged.into_values().collect())
}

/// A tombstone past its lifetime is dropped only once no other device still
/// holds the block live; otherwise that copy would bring it back.
pub fn pruned(blocks: Vec<Block>, others: &[Block], now: Millis) -> Vec<Block> {
    let cutoff = now - TOMBSTONE_LIFETIME;
    let expired = |block: &Block| block.deleted_at.is_some_and(|at| at < cutoff);
    if !blocks.iter().any(expired) {
        return blocks;
    }
    let live_elsewhere: HashSet<Uuid> = others.iter().filter(|b| !b.is_deleted()).map(|b| b.id).collect();
    blocks.into_iter().filter(|b| !expired(b) || live_elsewhere.contains(&b.id)).collect()
}

/// Newest first, the same order the Mac writes.
pub fn ordered(mut blocks: Vec<Block>) -> Vec<Block> {
    blocks.sort_by_key(|b| std::cmp::Reverse((b.surfaced_at, b.id)));
    blocks
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block::{Content, TextRun};

    fn block(text: &str, modified_at: Millis, by: &str) -> Block {
        let runs = vec![TextRun { text: text.into(), ..Default::default() }];
        let mut block = Block::new(Content::Text(runs), by, 0);
        block.modified_at = modified_at;
        block
    }

    fn with_id(mut block: Block, id: Uuid) -> Block {
        block.id = id;
        block
    }

    fn text(block: &Block) -> &str {
        match &block.content {
            Content::Text(runs) => &runs[0].text,
            _ => panic!(),
        }
    }

    #[test]
    fn newer_edit_wins_either_way() {
        let id = Uuid::new_v4();
        let old = with_id(block("old", 1, "mac"), id);
        let new = with_id(block("new", 2, "ubuntu"), id);
        assert_eq!(text(&merge(vec![old.clone()], [new.clone()], None)[0]), "new");
        assert_eq!(text(&merge(vec![new], [old], None)[0]), "new");
    }

    #[test]
    fn edit_and_delete_newest_wins() {
        let id = Uuid::new_v4();
        let edit = with_id(block("edit", 5, "mac"), id);
        let mut delete = with_id(block("edit", 4, "ubuntu"), id);
        delete.deleted_at = Some(4);
        assert!(!merge(vec![delete.clone()], [edit.clone()], None)[0].is_deleted());
        delete.modified_at = 6;
        assert!(merge(vec![edit], [delete], None)[0].is_deleted());
    }

    #[test]
    fn ties_break_by_device_name() {
        let id = Uuid::new_v4();
        let mac = with_id(block("mac", 7, "mac"), id);
        let ubuntu = with_id(block("ubuntu", 7, "ubuntu"), id);
        assert_eq!(text(&merge(vec![mac.clone()], [ubuntu.clone()], None)[0]), "ubuntu");
        assert_eq!(text(&merge(vec![ubuntu], [mac], None)[0]), "ubuntu");
    }

    #[test]
    fn duplicates_in_local_keep_the_newest() {
        let id = Uuid::new_v4();
        let merged = merge(vec![with_id(block("b", 2, "mac"), id), with_id(block("a", 1, "mac"), id)], [], None);
        assert_eq!(merged.len(), 1);
        assert_eq!(text(&merged[0]), "b");
    }

    #[test]
    fn protected_block_ignores_remote() {
        let id = Uuid::new_v4();
        let mine = with_id(block("mine", 1, "ubuntu"), id);
        let theirs = with_id(block("theirs", 9, "mac"), id);
        assert_eq!(text(&merge(vec![mine], [theirs], Some(id))[0]), "mine");
    }

    #[test]
    fn ordered_newest_surfaced_first() {
        let mut a = block("a", 1, "mac");
        let mut b = block("b", 1, "mac");
        a.surfaced_at = 1;
        b.surfaced_at = 2;
        assert_eq!(text(&merge(vec![a, b], [], None)[0]), "b");
    }

    #[test]
    fn prunes_old_tombstones_unless_live_elsewhere() {
        let now = 1_000 * TOMBSTONE_LIFETIME;
        let mut expired = block("x", 1, "ubuntu");
        expired.deleted_at = Some(now - TOMBSTONE_LIFETIME - 1);
        let mut young = block("y", 1, "ubuntu");
        young.deleted_at = Some(now - TOMBSTONE_LIFETIME + 1);
        let mut live_there = expired.clone();
        live_there.id = Uuid::new_v4();
        let mut other_copy = live_there.clone();
        other_copy.deleted_at = None;

        let kept = pruned(vec![expired, young.clone(), live_there.clone()], &[other_copy], now);
        let ids: Vec<Uuid> = kept.iter().map(|b| b.id).collect();
        assert_eq!(ids, vec![young.id, live_there.id]);
    }
}
