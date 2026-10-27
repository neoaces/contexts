# Contexts

A right-edge quicklook for macOS 26. Rest the pointer on the right edge of the screen and a Liquid Glass panel drops down from that point with your recent blocks.

Block kinds: rich text and math (LaTeX).

## Build & run

```sh
./scripts/build-app.sh
open build/Contexts.app
```

Contexts runs as an accessory app with no Dock icon and no menu bar. Quit it with ⌘Q while a block is being edited, or with `pkill Contexts`.

## Use

- **Show:** rest the pointer on the right edge for a moment. The header appears under the pointer and blocks drop below it. Near the bottom of the screen they stack upward instead.
- **New text block:** click **+**, then **Text**. You're typing immediately; an empty block is discarded when you leave it.
- **Edit:** click anywhere in a block's text. Return confirms the block; Shift-Return starts a new line. Escape or clicking elsewhere also ends editing. ⌘B, ⌘I and ⌘U toggle bold, italic and underline.
- **Math:** click **+**, then **Math**, and type LaTeX without `$` delimiters on the single source line. The preview below it updates as you type. Return confirms.
- **Delete:** swipe left on a block with two fingers to uncover **Delete**, or click **≡**, then **⊖**. Swipe right or click the block to close it again.
- **Undo:** after a delete or restore, an **Undo** button appears in the header for 5 seconds. ⌘Z and ⇧⌘Z also work once you've clicked the panel. Inside a block, ⌘Z undoes typing.
- **History:** blocks unused for 30 minutes move to the **History** tab when the panel next opens. Click one to bring it back. Change the delay with `defaults write local.contexts archiveAfterMinutes -int 60`; `0` turns archiving off.
- **Pin:** click the pin at the top left. The panel moves to the top-right of the screen and stays open; its buttons hide while the pointer is away and come back when it returns. Click the pin again, or press Escape, to unpin.
- **Escape:** ends editing, then closes the options, delete mode, and History, then hides the panel.

Blocks are saved to `~/Contexts/blocks-mac.json`, in a format shared with the planned Ubuntu app.
- Each device writes only its own `blocks-<device>.json` and merges everyone's, so the folder can be synced with Syncthing without conflicts.
- Change the folder or the device name with `defaults write local.contexts syncFolder <path>` / `deviceName <name>`.
- The first launch of this version migrates the old `~/Library/Application Support/Contexts/blocks.json` and keeps it as `blocks.v1-backup.json`.

## Ubuntu (in progress)

A GTK app (`linux/`) and a GNOME Shell 46 extension (`gnome-extension/contexts@local/`) for Ubuntu 24.04 on X11.

```sh
sudo apt install build-essential pkg-config libgtk-4-dev libadwaita-1-dev
./scripts/install-linux.sh          # app to ~/.local/bin, extension linked
gnome-extensions enable contexts@local
```

Restart the shell with Alt+F2, `r` to load extension changes. Logs: `journalctl -f -o cat /usr/bin/gnome-shell`.

## Layout

```
Sources/Contexts/
  App/      main.swift, AppDelegate (wiring), MainMenu (key equivalents only)
  Blocks/   Block + NewBlockOption, BlockStore (persistence), RichText (RTF codec), RichTextView
  Panel/    EdgeHotZones (edge triggers), PanelController (window), PanelModel (state + intents),
            ContextPanelView (header), BlockList (rows, cards, delete controls)
```

To add a block kind (image, PDF, math), add a case to `Block.Content`, an option to `NewBlockOption`, and a view branch in `BlockCard`.
