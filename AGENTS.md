# GPTK Patcher Tool

Native macOS 14+ SwiftUI/AppKit app, built with Swift Package Manager. There are no third-party
dependencies. Keep changes small and reuse the existing scripts and Swift/Foundation APIs.

## Build and run

- `scripts/build-app.sh`: universal release app at `build/GPTK Patcher Tool.app`, signed ad hoc.
- `scripts/run-app.sh`: build and open the app.
- The build script selects an Xcode installation in `/Applications` when `xcode-select` points
  at Command Line Tools. Prefer it over changing the machine's global toolchain selection.
- After code changes, build and run the CLI smoke check:
  `"build/GPTK Patcher Tool.app/Contents/MacOS/GPTKPatcher" --cli --help`.
- Verify packaging changes with `codesign --verify --strict --verbose=2 "build/GPTK Patcher Tool.app"`.
- `scripts/test.sh`: regression checks using disposable fixtures. Add focused checks for
  nontrivial logic. See README for the opt-in official CrossOver integration check.

## Code map

- `GPTKPatcherApp.swift`: app lifecycle and headless CLI.
- `ContentView.swift`, `FileTile.swift`, `ToolkitTile.swift`, `PatchedAppSettings.swift`: UI.
- `PatchEngine.swift`: observable UI state and patch orchestration.
- `PatchJob.swift`: shared patch job, backups, verification, rollback, and receipts.
- `CrossOverBundle.swift`: app validation and discovery.
- `AppSigning.swift`, `FileSafety.swift`: local signatures, transaction backups, and mutation lock.
- `AppSettings.swift`: inherited graphics options and transactional settings edits.
- `GPTKSource.swift`, `DiskImage.swift`, `ToolkitLibrary.swift`: toolkit discovery and import.
- `BottleEnv.swift`, `PatchedApps.swift`, `Shell.swift`: config, registry, and process helpers.
- `Resources/Info.plist`: app version and bundle metadata.

## Patching and release checks

Preserve stock backups, rollback, cancellation, and the distinction between duplicate and
in-place patching. GUI and CLI patch paths share `PatchJob`; consider both when changing it.
Use disposable CrossOver copies and explicit temporary destinations for patching tests.
Do not use the user's installed apps or live bottle sessions as test fixtures unless requested.
The debug-only `GPTKPATCHER_AUTOPATCH` hook performs real patching; it is not a harmless UI
preview flag. Release builds ignore all debug hooks. Keep code-signature verification and
rollback in the shared paths, including app-default config edits and launch repair.

Keep Apple toolkit payloads, CrossOver binaries, signing credentials, and generated build output
out of Git. `scripts/release.sh` uploads to Apple's notarization service; use the local build
script for ordinary development and run the release script only for a requested release.
