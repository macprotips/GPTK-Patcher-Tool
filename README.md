# GPTK Patcher Tool

CrossOver ships with a build of Apple's Game Porting Toolkit. This replaces it with a different
one, in a duplicate of CrossOver or in the installed app, and sets up DLSS → MetalFX.

## Requirements

- macOS 14 or later, Apple Silicon.
- CrossOver 25, 26, or CrossOver Preview 27.
- A Game Porting Toolkit disk image from Apple's developer downloads. Nothing from Apple is
  redistributed here; you supply your own copy.

## Development

This is a Swift Package Manager executable using SwiftUI and AppKit, with no third-party
dependencies. Install a full Xcode toolchain in `/Applications`; Command Line Tools alone are
not sufficient for the build script. CrossOver and a toolkit image are only needed to try patching.

From the repository root, build and open the app:

```sh
scripts/run-app.sh
```

To build without launching, run `scripts/build-app.sh`. It builds both arm64 and x86_64, assembles
`build/GPTK Patcher Tool.app`, and signs it ad hoc for local development. If `xcode-select` points
at Command Line Tools, the script automatically uses an Xcode installation from `/Applications`
for that build. You can also open `Package.swift` in Xcode.

Check the bundle and CLI without patching CrossOver:

```sh
codesign --verify --strict --verbose=2 "build/GPTK Patcher Tool.app"
"build/GPTK Patcher Tool.app/Contents/MacOS/GPTKPatcher" --cli --help
```

Run the regression checks with `scripts/test.sh`. They use temporary app, toolkit and config
fixtures, including real code signing and disk-image mounting. They do not patch installed apps
or use live bottles. An optional integration check accepts a disposable stock CrossOver download
and an already extracted toolkit:

```sh
GPTKPATCHER_TEST_CROSSOVER="/path/to/disposable/CrossOver.app" \
GPTKPATCHER_TEST_TOOLKIT="/path/to/toolkit/lib" \
scripts/test.sh --filter StabilityTests/testOfficialCrossOverBundle
```

That check duplicates, patches, changes settings and re-patches the temporary result, then checks
the signatures of both apps. It does not launch CrossOver. For manual patching checks, always use
a disposable copy and a separate destination; patching can modify app files and bottle settings.

`Sources/GPTKPatcher/` contains the UI and patching code; `Resources/Info.plist` holds the app
version and bundle metadata. `scripts/release.sh` handles Developer ID signing and Apple
notarization, with credentials configured as described at the top of that script.

## Using it

1. **Launch the original CrossOver at least once before patching GPTK.** Complete its initial
   setup, then quit CrossOver and any running games or bottles.
2. Drop `CrossOver.app` and the toolkit `.dmg` onto the two tiles. Either tile takes either file.
   Files can also be dropped on the app icon, pasted with ⌘V, or picked with a file chooser. The
   full `Game_Porting_Toolkit_x.dmg` works directly; the evaluation-environment image inside it is
   found automatically.
3. Choose **Duplicate CrossOver** or **Patch Existing**.
4. Click **Patch CrossOver**.

Imported toolkits are kept in `~/Library/Application Support/GPTKPatcher/Toolkits/<version>/` and
picked from the menu on the toolkit tile.

Patched apps appear in the **Patched** list. *Reveal in Finder* shows the app; the gear sets the
D3DMetal frame rate cap, the Metal Performance HUD and Metal 4. **App defaults** apply to bottles
launched with that copy; individual bottle settings take priority. Bottle options show inherited
cap/HUD values, and **Off** explicitly disables them. **Use App Defaults** removes that bottle's
three overrides. Changing app defaults preserves existing bottle overrides. Quit that CrossOver
and its bottle sessions before changing app defaults; the app must be re-signed after a config edit.

If a previously patched copy is reported as damaged, quit it and its bottle sessions, then
right-click its entry in **Patched** and choose **Repair Launch**. This renews the local signature
without changing the toolkit or settings. The CLI equivalent is:

```sh
"build/GPTK Patcher Tool.app/Contents/MacOS/GPTKPatcher" --cli --repair "/path/to/CrossOver (GPTK 4.0b2).app"
```

Repair requires this patcher's receipt and stock toolkit backup. For an unrecognized or incomplete
app, download a fresh copy from CodeWeavers and patch a duplicate. Global Gatekeeper settings
do not need to be changed.

## What patching does

- **Duplicate:** APFS-clones CrossOver and saves it as `CrossOver (GPTK x).app` in `/Applications`,
  or `~/Applications` if that is not writable. A taken name gets a counter; nothing is replaced.
- **Patch Existing:** modifies the selected app and refuses while it or its Wine programs are
  running. Quit those sessions yourself before patching. Afterwards the app is renamed to `CrossOver (GPTK x).app` unless that
  name is taken, and moved into Applications if it was somewhere like Downloads. Re-patching keeps
  any frame rate cap or HUD setting.
- Replaces `apple_gptk` with the toolkit's copy, keeping the original as `apple_gptk.stock`. A
  second patch replaces only the previous patch. On a handled failure or cancellation, the toolkit,
  receipt, configs and signature are restored and an unfinished duplicate is deleted. Failed
  recovery is reported with the retained backup location in **Details**.
- Creates `nvngx.dll` and `nvngx.so` copies of the toolkit's `nvngx-on-metalfx` shim. CrossOver's
  loader redirects a game's `nvngx.dll` to that file; without it DLSS games get no MetalFX.
- Writes `D3DM_ENABLE_METALFX=1` and `DXMT_ENABLE_NVEXT=1` to the app's
  `Contents/SharedSupport/CrossOver/etc/CrossOver.conf`, which CrossOver applies to every bottle it
  launches. A bottle's own `cxbottle.conf` overrides it.
- Verifies the original CrossOver signature before patching. Once all files are in place, signs
  the modified app ad hoc for local use, preserves its existing entitlements and embedded library
  signatures, and enables loading those libraries under the new local identity. Removes quarantine
  metadata from this patched app and verifies its final signature. This changes the app's signing
  identity; the result is not a CodeWeavers-signed or notarized distribution. CrossOver is not
  automatically launched during patching.
- Leaves `gptkpatcher-receipt.json` in the app's SharedSupport folder.

## Compatibility

- CrossOver 25/26 (`lib64/apple_gptk`) and CrossOver Preview 27 (`lib/apple_gptk`). The Preview's
  `lib/apple_gptk3` is left alone; only bottles with `CX_GRAPHICS_BACKEND_VERSION=3` use it. The
  toolkit serves Intel (x86_64) bottles; ARM64 bottles are unaffected.
- GPTK evaluation environments 2.1 through 4.0.

The toolkit's declared minimum macOS version is checked before patching. That metadata does not
guarantee every graphics feature or game works on every supported macOS release. The September
2026 audit exercised CrossOver 26.2, 26.3 and Preview 27 with GPTK 4.0b2 on macOS 27; macOS 26,
CrossOver 25 and individual game compatibility still need their own runtime checks.

## Undo

For a duplicate, trash the patched copy and use the original. For an in-place patch, replace the
app with a fresh CodeWeavers download to restore the original files and signing identity. Your
bottles are stored separately; do not delete their folders.

`apple_gptk.stock` preserves the original toolkit, and config edits keep a `.gptkpatcher.bak`
beside the changed file. Restore an individual config backup only if you intend to discard later
edits to that config. Manually swapping toolkit folders alone does not restore the original code
signature. After a crash or forced termination, preserve any `.apple_gptk.previous` folder and
recovery files rather than deleting them. Automatic rollback covers handled errors and
cancellation, not power loss or a force-killed process.

## Licensing

MIT; see [LICENSE](LICENSE). That covers this project's code.

Apple's Game Porting Toolkit is not included or redistributed here, and stays under Apple's terms.
An imported toolkit keeps the licence, acknowledgements and read-me from its disk image in
`~/Library/Application Support/GPTKPatcher/Toolkits/<version>/Apple Toolkit Documents/`. CrossOver
is CodeWeavers' commercial software; this modifies a copy you already own.

## Support

A patched CrossOver is not supported by CodeWeavers. Problems should be reproduced with an
unmodified CrossOver before contacting their support.
