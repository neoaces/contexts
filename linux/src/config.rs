//! Settings from the environment, the stand-in for the Mac app's `defaults`.
//! The extension launches the app, so set them in `~/.config/environment.d/`.

use std::path::PathBuf;
use std::time::Duration;

/// `CONTEXTS_DEVICE`, default `ubuntu`: names this device's `blocks-<device>.json`.
pub fn device() -> String {
    var("CONTEXTS_DEVICE").unwrap_or_else(|| "ubuntu".into())
}

/// `CONTEXTS_FOLDER`, default `~/Contexts`: the folder shared with other devices.
pub fn folder() -> PathBuf {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    match var("CONTEXTS_FOLDER") {
        Some(path) => match path.strip_prefix("~/") {
            Some(rest) => home.join(rest),
            None => PathBuf::from(path),
        },
        None => home.join("Contexts"),
    }
}

/// `CONTEXTS_ARCHIVE_MINUTES`, default 30: how long a block may go unused
/// before it moves to History. 0 turns archiving off.
pub fn archive_after() -> Option<Duration> {
    let minutes = var("CONTEXTS_ARCHIVE_MINUTES").and_then(|m| m.parse().ok()).unwrap_or(30u64);
    (minutes > 0).then(|| Duration::from_secs(minutes * 60))
}

fn var(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}
