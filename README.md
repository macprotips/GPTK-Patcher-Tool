# GPTK Patcher Tool

CrossOver ships with a build of Apple's Game Porting Toolkit, and a build of DXMT. This replaces
either with a newer one, in a duplicate of CrossOver or in the installed app, and sets up
DLSS → MetalFX.

## Requirements

- macOS 14 or later, Apple Silicon.
- CrossOver 25, 26, or CrossOver Preview 27.
- A Game Porting Toolkit disk image from Apple's developer downloads. Nothing from Apple is
  redistributed here; you supply your own copy.
- Optional, to update DXMT: a release archive (`dxmt-vX.XX-builtin.tar.gz`) from
  [3Shain/dxmt](https://github.com/3Shain/dxmt/releases).
- Optional, to update MoltenVK: a `libMoltenVK.dylib`, or the archive it came in. See
  [Vulkan games](#vulkan-games-doom-wolfenstein-detroit) below.

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
3. Optionally drop a build on the **DXMT** or **MoltenVK** line to update DXMT in the same pass.
   Left alone, CrossOver's own DXMT and MoltenVK are untouched. Every menu lists *Unchanged*
   alongside the imported builds, so any component can be set back to untouched — including the
   toolkit, to update only DXMT. At least one has to be chosen.
4. Choose **Duplicate CrossOver** or **Patch Existing**.
5. Click **Patch CrossOver**.

The patcher checks macOS's first-launch approval marker when you drop, paste, or choose CrossOver.
If the download is still awaiting approval, it refuses the selection and asks you to launch it,
finish setup, quit, and add it again. The check also runs before GUI or CLI patching starts.
It does not open or quit CrossOver for you. This is a check of the download's approval record;
macOS does not provide a complete launch history for every copied or unquarantined app.

Imported toolkits are kept in `~/Library/Application Support/GPTKPatcher/Toolkits/<version>/` and
DXMT builds in `.../GPTKPatcher/DXMT/<version>/`, each picked from its own menu.

Patched apps appear in the **Patched** list. *Reveal in Finder* shows the app; the gear sets the
frame rate cap, the Metal Performance HUD and Metal 4. One cap covers both translation layers: it
writes `D3DM_MAX_FPS` for D3DMetal games and `d3d11.preferredMaxFrameRate` in `DXMT_CONFIG` for
DXMT games, keeping any other DXMT option already set there. DXMT wants a factor of the display's
refresh rate, such as 30 or 60 on a 120 Hz display. **App defaults** apply to bottles
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
- Skips the toolkit entirely when none is chosen, so a patch can update DXMT alone. The
  bundled `apple_gptk` is then left exactly as it was, with no backup made of it. Whatever an
  earlier patch put in the app stays recorded, so a toolkit-only or DXMT-only pass does not make
  the app forget the rest of what it carries.
- Replaces every `libMoltenVK.dylib` the app ships when a MoltenVK build is chosen, keeping each
  original as `libMoltenVK.dylib.stock`. CrossOver 26 has one in `lib64`; CrossOver Preview has one
  per architecture. A build is refused rather than installed if it does not contain the
  architecture a slot needs, since a mismatch breaks Vulkan with no visible cause. Choosing a build
  also sets `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS`, without which Metal allows only 16 sampler
  slots and the lighting shaders in Doom and Wolfenstein II fail to compile, along with
  `MVK_CONFIG_SHADER_COMPRESSION_ALGORITHM` and `MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION`,
  which the Detroit build needs for its cache.
- Replaces `lib/dxmt` when a DXMT build is chosen, keeping the original as `dxmt.stock`.
  Upstream releases ship x86_64 and i386 only, so anything else the bundled build had is
  carried over — CrossOver Preview's `aarch64` DXMT survives the swap.
- Leaves DXMT or MoltenVK untouched when the app already carries the build that is chosen, so
  re-patching an app to update only its toolkit does not disturb them.
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

## Vulkan games (Doom, Wolfenstein, Detroit)

Doom (2016), Wolfenstein II: The New Colossus and Detroit: Become Human are Vulkan games, so
neither the Game Porting Toolkit nor DXMT affects them — they go through **MoltenVK**, which
CrossOver also bundles. The bundled one is too old to render them correctly, so this app installs
a different one.

Nothing is distributed here. Build the library with `scripts/build-moltenvk.sh`, which needs Xcode:

```sh
scripts/build-moltenvk.sh standard
```

That library covers **Doom 2016** and **Wolfenstein II**, both verified. Two things are needed
before either will start a Vulkan device, and no published build has both:

- `shaderCullDistance` and `depthBounds`, which Metal does not have and these games insist on.
  Upstream MoltenVK answers honestly and the game quits. The build advertises them; the limits
  stay at zero, so nothing is promised beyond the capability itself.
- The shader translation from a current MoltenVK. CrossOver's own build has the capability flags
  but is old enough that the lighting shaders fail to compile, which is what a black screen is.

**Detroit: Become Human needs a different build**, from
[MoltenVK-Detroit](https://github.com/DiAvisoo/MoltenVK-Detroit/releases) — drop the `.zip` in as
it is. That game writes a `float4` into an integer colour attachment, which Metal refuses
(`KhronosGroup/MoltenVK#2054`), and fixing it takes a patched SPIRV-Cross as well as a patched
MoltenVK. `scripts/build-moltenvk.sh` does not carry that patch. Detroit also needs its own game
fixes after patching: `"DEPTH_OF_FIELD": 0` in `GraphicOptions.JSON`, a one-byte edit to
`DetroitBecomeHuman.exe`, and a first-run Metal shader cache build. Follow the MoltenVK-Detroit
instructions for those.

The `doometernal` profile adds what Doom Eternal's own community build changes. **It has not been
tested**, because the game was not available to try it on.

Keep a library per game and switch between them from the MoltenVK menu. These builds tell Metal it
can do things it cannot, which suits one game and can upset another.

Steam games launch through Steam, not by running the executable: a Steam copy of Doom exits
silently otherwise. Doom also wants `+r_renderAPI 1` so it starts in Vulkan rather than OpenGL.

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

MIT; see [LICENSE](LICENSE). That covers this project's code. Nearly everything it installs was
written by someone else; [CREDITS](CREDITS.md) says who.

Apple's Game Porting Toolkit is not included or redistributed here, and stays under Apple's terms.
An imported toolkit keeps the licence, acknowledgements and read-me from its disk image in
`~/Library/Application Support/GPTKPatcher/Toolkits/<version>/Apple Toolkit Documents/`. CrossOver
is CodeWeavers' commercial software; this modifies a copy you already own.

## Support

A patched CrossOver is not supported by CodeWeavers. Problems should be reproduced with an
unmodified CrossOver before contacting their support.
