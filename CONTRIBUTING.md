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

## Releasing / Sürüm Çıkarma
Ad-hoc bundles are fine for local testing, but a downloadable release needs an Apple Developer ID.

One-time setup, after the membership is active:

```bash
xcrun notarytool store-credentials clearmix-notary \
  --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
security find-identity -v -p codesigning   # note the "Developer ID Application: …" identity
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
```

Then one command signs, notarizes, staples and verifies the DMG:

```bash
./Scripts/release.sh            # uses NOTARY_PROFILE=clearmix-notary by default
```

`SKIP_NOTARIZATION=1 ./Scripts/release.sh` signs only, which is useful to check the signature without a notary round trip. Everything lands in `build/dist/`; `gh release upload` (printed at the end) attaches it to the tag.
