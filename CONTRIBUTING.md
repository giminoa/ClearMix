# Contributing to ClearMix

Thank you for helping improve ClearMix!

## Before You Start
Please read [AGENTS.md](AGENTS.md) — especially the **Real-Time Audio Thread Rules** — before modifying any code in `Sources/ClearMixCore` or `Sources/CMixRT`.

## Development Workflow
1. Fork the repository and create a topic branch from `main`.
2. Make focused, modular changes and add/update XCTests in `Tests/ClearMixCoreTests/`.
3. Verify locally before opening a PR:
   ```bash
   swift test
   ./Scripts/bundle-app.sh
   ```
4. If you change UI strings, update both Turkish and English entries via `L10n.text`.
5. Never commit build artifacts (`build/`, `.build/`) or personal `settings.json` files.
