#!/bin/sh
# Builds the Ubuntu app into ~/.local/bin and links the GNOME Shell extension.
set -eu
cd "$(dirname "$0")/.."

cargo build --release --manifest-path linux/Cargo.toml
install -Dm755 linux/target/release/contexts-linux "$HOME/.local/bin/contexts-linux"
ext="$HOME/.local/share/gnome-shell/extensions/contexts@local"
[ -e "$ext" ] || ln -s "$PWD/gnome-extension/contexts@local" "$ext"
echo "Installed. Restart the shell (Alt+F2, r) to load extension changes."
