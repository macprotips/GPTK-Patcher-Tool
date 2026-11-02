# GPTK Patcher Tool

CrossOver bundles its own builds of Apple's Game Porting Toolkit, DXMT and MoltenVK, and they are
usually a version or two behind what games need. This swaps them for newer ones, in a duplicate of
CrossOver or in the app itself, and wires up DLSS to MetalFX while it is in there.

[Download the latest release](https://github.com/macprotips/GPTK-Patcher-Tool/releases/latest).
Signed and notarized, so it opens without a Gatekeeper fight.

DXMT and MoltenVK support is **beta**. Patch a duplicate rather than your installed CrossOver
while you try them.

## You need

- macOS 14 or later, Apple Silicon.
- CrossOver 25, 26, or CrossOver Preview 27, launched once and set up.
- A Game Porting Toolkit disk image from Apple's developer downloads. Nothing of Apple's is
  redistributed here, so you supply your own.
- Optional: a DXMT release (`dxmt-vX.XX-builtin.tar.gz`) from
  [3Shain/dxmt](https://github.com/3Shain/dxmt/releases).
- Optional: your own `libMoltenVK.dylib`. One is already included.

## Patching

1. Launch CrossOver once, finish its setup, then quit it and any running bottles.
2. Drop `CrossOver.app` and the toolkit `.dmg` onto the tiles. Either tile takes either file, and
   you can also paste with ⌘V or pick from a file chooser. The full `Game_Porting_Toolkit_x.dmg`
   works as downloaded.
3. Optional: drop a DXMT release or pick a MoltenVK build. Every menu has *Unchanged*, so you can
   update one component and leave the rest alone.
4. Pick **Duplicate CrossOver** or **Patch Existing**, then click **Patch CrossOver**.

A duplicate is saved as `CrossOver (GPTK 4.0b2, MoltenVK 1.4.3).app` in `/Applications`, named
after what went into it. Nothing is overwritten. Patching in place keeps the app's current name and
path so aliases, the Dock and open bottle sessions keep working, and there is a checkbox if you
want the descriptive name instead.

Patching in place has two costs worth knowing. A CrossOver update replaces the whole app and takes
the patch with it, and the local re-signature means macOS asks again for permissions it had already
granted to CodeWeavers' build. Use a duplicate unless you have a reason not to.

Every file the patcher replaces is kept beside the new one as `.stock`, and a cancelled or failed
patch rolls back. Imported toolkits live in
`~/Library/Application Support/GPTKPatcher/Toolkits/<version>/`, DXMT builds alongside in `DXMT/`.

## Settings

Patched copies show up in **Already Patched**. The gear sets the frame rate cap, the Metal
Performance HUD and Metal 4, either as app defaults for every bottle that copy launches or per
bottle, where bottle settings win. One cap covers both translation layers: `D3DM_MAX_FPS` for
D3DMetal and `d3d11.preferredMaxFrameRate` for DXMT. DXMT wants a factor of your refresh rate, so
30 or 60 on a 120 Hz display.

Quit that CrossOver and its bottles before changing app defaults, since the app is re-signed after
a config edit.

If a patched copy is ever reported as damaged, quit it and choose **Repair Launch** from its
right-click menu. That renews the local signature and changes nothing else.

## Vulkan games

Doom (2016), Wolfenstein II and Detroit: Become Human are Vulkan games, so neither the toolkit nor
DXMT touches them. They go through MoltenVK, and CrossOver's bundled build is too old to render
them. The app installs its own.

The included build covers **Doom 2016** and **Wolfenstein II**. It advertises `shaderCullDistance`
and `depthBounds`, which Metal does not have and both games insist on, and it carries current
shader translation, without which the lighting shaders fail to compile and you get a black screen.
No published build has both. [CREDITS](CREDITS.md) says whose work this is.

**Detroit: Become Human needs a different build**, from
[MoltenVK-Detroit](https://github.com/DiAvisoo/MoltenVK-Detroit/releases). Drop the `.zip` in as
it is. That game also needs its own game-side fixes, which their instructions cover.

Worth knowing:

- Keep a library per game and switch from the MoltenVK menu. These builds tell Metal it can do
  things it cannot, which suits one game and can upset another.
- The first launch after a swap sits on a black screen for several minutes while the game compiles
  shaders. Later launches are quick.
- Launch Steam games through Steam. A Steam copy of Doom exits silently otherwise, and it wants
  `+r_renderAPI 1` to start in Vulkan rather than OpenGL.
- The `doometernal` profile in the build script is untested; the game was not on hand.

## Undo

Trash a duplicate and go back to the original. For an in-place patch, download CrossOver again from
CodeWeavers, which restores both the files and their signature. Bottles live elsewhere and are not
touched either way.

## Command line

The same patch path, inside the app bundle:

```sh
"/Applications/GPTK Patcher Tool.app/Contents/MacOS/GPTKPatcher" --cli --help
```

## Building it

A Swift Package Manager executable, SwiftUI and AppKit, no third-party dependencies. Needs a full
Xcode in `/Applications`; Command Line Tools alone will not do.

```sh
scripts/run-app.sh      # build and launch
scripts/build-app.sh    # universal build, ad hoc signed, no launch
scripts/test.sh         # regression checks on disposable fixtures
```

`scripts/build-moltenvk.sh standard` builds the MoltenVK library the app ships with.
`scripts/release.sh` handles Developer ID signing and notarization. The checks use temporary app,
toolkit and config fixtures with real code signing; they never touch installed apps or live
bottles. There is an opt-in check that patches a disposable CrossOver copy end to end:

```sh
GPTKPATCHER_TEST_CROSSOVER="/path/to/disposable/CrossOver.app" \
GPTKPATCHER_TEST_TOOLKIT="/path/to/toolkit/lib" \
scripts/test.sh --filter StabilityTests/testOfficialCrossOverBundle
```

## Licensing and support

This project's code is MIT; see [LICENSE](LICENSE). Nearly everything it installs was written by
someone else, and [CREDITS](CREDITS.md) says who.

Apple's Game Porting Toolkit is not redistributed here and stays under Apple's terms. CrossOver is
CodeWeavers' commercial software, and this modifies a copy you already bought. They do not support
a patched CrossOver, so reproduce anything you want to report to them on an unmodified install
first.
