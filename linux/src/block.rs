//! One block, in the sync format shared with the Mac app (schema 2), matching
//! `Sources/Contexts/Blocks/Block.swift`. Nothing is ever removed: a delete
//! sets `deleted_at`, so it syncs like any edit.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};
use uuid::Uuid;

/// Milliseconds since the Unix epoch: the one time format shared with other devices.
pub type Millis = i64;

pub fn now() -> Millis {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as Millis)
}

/// A stretch of text with one combination of styles. Runs, not offsets, because
/// Swift, GTK and Rust count characters differently.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TextRun {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
}

impl TextRun {
    pub fn same_style(&self, other: &TextRun) -> bool {
        (self.bold, self.italic, self.underline) == (other.bold, other.italic, other.underline)
    }

    fn from_json(value: &Value) -> Option<TextRun> {
        let fields = value.as_object()?;
        let flag = |key| match fields.get(key) {
            None | Some(Value::Null) => Some(false),
            Some(value) => value.as_bool(),
        };
        Some(TextRun {
            text: fields.get("t")?.as_str()?.to_owned(),
            bold: flag("b")?,
            italic: flag("i")?,
            underline: flag("u")?,
        })
    }

    /// Styles that are off are left out, keeping the file small and readable.
    fn to_json(&self) -> Value {
        let mut fields = Map::new();
        fields.insert("t".into(), self.text.clone().into());
        for (key, on) in [("b", self.bold), ("i", self.italic), ("u", self.underline)] {
            if on {
                fields.insert(key.into(), true.into());
            }
        }
        Value::Object(fields)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Content {
    Text(Vec<TextRun>),
    Math(String),
    /// A kind this build doesn't know (e.g. from a newer app). Kept verbatim, never shown.
    Unknown(Map<String, Value>),
}

impl Content {
    pub fn is_blank(&self) -> bool {
        match self {
            Content::Text(runs) => runs.iter().all(|run| run.text.chars().all(char::is_whitespace)),
            Content::Math(latex) => latex.chars().all(char::is_whitespace),
            Content::Unknown(_) => false,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Block {
    pub id: Uuid,
    pub content: Content,
    /// When the block was created or last restored; Recent is ordered by it.
    pub surfaced_at: Millis,
    pub last_used: Millis,
    pub archived_at: Option<Millis>,
    pub deleted_at: Option<Millis>,
    pub modified_at: Millis,
    pub modified_by: String,
}

impl Block {
    pub fn new(content: Content, device: &str, at: Millis) -> Block {
        Block {
            id: Uuid::new_v4(),
            content,
            surfaced_at: at,
            last_used: at,
            archived_at: None,
            deleted_at: None,
            modified_at: at,
            modified_by: device.to_owned(),
        }
    }

    pub fn is_archived(&self) -> bool {
        self.archived_at.is_some()
    }

    pub fn is_deleted(&self) -> bool {
        self.deleted_at.is_some()
    }

    pub fn is_shown(&self) -> bool {
        !self.is_deleted() && !matches!(self.content, Content::Unknown(_))
    }

    pub fn is_blank(&self) -> bool {
        self.content.is_blank()
    }

    /// Newest change wins; the device name breaks exact ties the same way on every machine.
    pub fn supersedes(&self, other: &Block) -> bool {
        (self.modified_at, &self.modified_by) > (other.modified_at, &other.modified_by)
    }

    /// None for a malformed block; the file it came from is still read.
    pub fn from_json(value: &Value) -> Option<Block> {
        let fields = value.as_object()?;
        let millis = |key| fields.get(key)?.as_i64();
        let optional = |key| match fields.get(key) {
            None | Some(Value::Null) => Some(None),
            Some(value) => value.as_i64().map(Some),
        };
        let content = match fields.get("kind")?.as_str()? {
            "text" => Content::Text(
                fields.get("runs")?.as_array()?.iter().map(TextRun::from_json).collect::<Option<_>>()?,
            ),
            "math" => Content::Math(fields.get("latex")?.as_str()?.to_owned()),
            _ => Content::Unknown(fields.clone()),
        };
        Some(Block {
            // Parsing makes ids compare case-insensitively (Swift writes them uppercase in memory).
            id: Uuid::parse_str(fields.get("id")?.as_str()?).ok()?,
            content,
            surfaced_at: millis("surfacedAt")?,
            last_used: millis("lastUsed")?,
            archived_at: optional("archivedAt")?,
            deleted_at: optional("deletedAt")?,
            modified_at: millis("modifiedAt")?,
            modified_by: fields.get("modifiedBy")?.as_str()?.to_owned(),
        })
    }

    /// Unknown kinds are written back exactly as read.
    pub fn to_json(&self) -> Value {
        let (kind, key, body) = match &self.content {
            Content::Unknown(fields) => return Value::Object(fields.clone()),
            Content::Text(runs) => ("text", "runs", Value::Array(runs.iter().map(TextRun::to_json).collect())),
            Content::Math(latex) => ("math", "latex", latex.clone().into()),
        };
        let mut fields = Map::new();
        fields.insert("id".into(), self.id.to_string().into());
        fields.insert("kind".into(), kind.into());
        fields.insert(key.into(), body);
        fields.insert("surfacedAt".into(), self.surfaced_at.into());
        fields.insert("lastUsed".into(), self.last_used.into());
        fields.insert("archivedAt".into(), self.archived_at.into());
        fields.insert("deletedAt".into(), self.deleted_at.into());
        fields.insert("modifiedAt".into(), self.modified_at.into());
        fields.insert("modifiedBy".into(), self.modified_by.clone().into());
        Value::Object(fields)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn round_trips_text_with_styles() {
        let value = json!({
            "id": "0B4F3C1E-2D9A-4C51-9F0E-6A7D2B1C8E44", "kind": "text",
            "runs": [{"t": "Hello ", "b": true}, {"t": "world", "i": true, "u": true}],
            "surfacedAt": 1, "lastUsed": 2, "archivedAt": null, "deletedAt": null,
            "modifiedAt": 3, "modifiedBy": "mac",
        });
        let block = Block::from_json(&value).unwrap();
        let written = block.to_json();
        assert_eq!(written["id"], "0b4f3c1e-2d9a-4c51-9f0e-6a7d2b1c8e44");
        assert_eq!(written["runs"], json!([{"t": "Hello ", "b": true}, {"t": "world", "i": true, "u": true}]));
        assert_eq!(written["archivedAt"], Value::Null);
        assert!(written.as_object().unwrap().contains_key("deletedAt"));
        assert_eq!(Block::from_json(&written), Some(block));
    }

    #[test]
    fn keeps_unknown_kinds_verbatim() {
        let value = json!({
            "id": "0b4f3c1e-2d9a-4c51-9f0e-6a7d2b1c8e44", "kind": "image", "png": "abc", "extra": [1, 2],
            "surfacedAt": 1, "lastUsed": 2, "modifiedAt": 3, "modifiedBy": "mac",
        });
        let block = Block::from_json(&value).unwrap();
        assert!(!block.is_shown());
        assert_eq!(block.to_json(), value);
    }

    #[test]
    fn rejects_malformed_blocks() {
        let base = json!({
            "id": "0b4f3c1e-2d9a-4c51-9f0e-6a7d2b1c8e44", "kind": "math", "latex": "x",
            "surfacedAt": 1, "lastUsed": 2, "modifiedAt": 3, "modifiedBy": "mac",
        });
        assert!(Block::from_json(&base).is_some());
        for (key, bad) in [("id", json!("nope")), ("modifiedAt", json!("3")), ("deletedAt", json!(true)), ("latex", json!(1))] {
            let mut value = base.clone();
            value[key] = bad;
            assert!(Block::from_json(&value).is_none(), "{key}");
        }
    }

    #[test]
    fn blank_means_only_whitespace() {
        let run = |t: &str| TextRun { text: t.into(), ..Default::default() };
        assert!(Content::Text(vec![]).is_blank());
        assert!(Content::Text(vec![run(" \n"), run("\t")]).is_blank());
        assert!(!Content::Text(vec![run(" a")]).is_blank());
        assert!(Content::Math("  ".into()).is_blank());
    }
}
