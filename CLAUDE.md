# Contexts

Two apps that share one sync folder: the macOS app (`Sources/`, tests in `Tests/`, run with `./scripts/test.sh`) and the Ubuntu app (`linux/` + `gnome-extension/`, `cargo test` in `linux/`). Both must pass the shared merge cases in `fixtures/sync-v2/`.

## Feature log

The Obsidian note `contexts/Contexts Feature Log.md` (vault `~/neonoted` on the Mac) tracks what each OS can do and what the other OS still has to port.
- **Before coding,** read its **Next up** section for the OS you're on.
- **After finishing a feature or a user-visible behavior change,** add a timestamped entry at the top of **Log**, give each OS a status, and put anything the other OS still needs under its **Next up**, with enough detail to build it from the note alone.
- **After porting something,** check it off and mark the entry done.
The note's header has the full rules.

## Releases

Tags are per OS: `mac-x.y.z` (version in `Resources/Info.plist`) and `ubuntu-x.y.z` (version in `linux/Cargo.toml`). The commit message is `Contexts <tag>`. Details are in the Obsidian note `contexts/Contexts Versioning.md`.
