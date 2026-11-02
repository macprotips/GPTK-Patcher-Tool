# GPTK Patcher Tool

Swaps the Game Porting Toolkit, DXMT and MoltenVK inside CrossOver for newer builds, and routes
DLSS to MetalFX.

**[Download](https://github.com/macprotips/GPTK-Patcher-Tool/releases/latest)** (signed and
notarized). DXMT and MoltenVK support is beta.

## You need

- macOS 14 or later, Apple Silicon.
- CrossOver 25, 26, or Preview 27, launched once and set up.
- A Game Porting Toolkit disk image from Apple's developer downloads.
- Optional: a [DXMT release](https://github.com/3Shain/dxmt/releases). A MoltenVK build is
  already included.

## Patching

1. Quit CrossOver and any running bottles.
2. Drop `CrossOver.app` and the toolkit `.dmg` onto the tiles. Either tile takes either file.
3. Optional: add a DXMT or MoltenVK build. Anything left on *Unchanged* is not touched.
4. Pick **Duplicate CrossOver** or **Patch Existing**, then click **Patch CrossOver**.

A duplicate is saved to `/Applications` as `CrossOver (GPTK 4.0b2, MoltenVK 1.4.3).app`. Patching
in place keeps the app's name and path, and a CrossOver update will wipe the patch, so prefer a
duplicate.

Originals are kept beside the replacements as `.stock`, and a failed or cancelled patch rolls back.

## Settings

Patched copies appear in **Already Patched**. The gear sets the frame rate cap, the Metal
Performance HUD and Metal 4, as app defaults or per bottle, where bottle settings win. Quit that
CrossOver first. Use **Repair Launch** from the right-click menu if macOS ever calls a patched
copy damaged.

## Vulkan games

Doom (2016), Wolfenstein II and Detroit: Become Human need MoltenVK rather than the toolkit or
DXMT. The included build covers Doom and Wolfenstein. Detroit needs
[MoltenVK-Detroit](https://github.com/DiAvisoo/MoltenVK-Detroit/releases), dropped in as the `.zip`
it downloads as, plus the game-side fixes in their instructions.

The first launch after a swap sits on a black screen for a few minutes while shaders compile.
Launch Steam games through Steam, and give Doom `+r_renderAPI 1`.

## Undo

Trash a duplicate. For an in-place patch, download CrossOver again from CodeWeavers. Bottles are
stored separately and are never touched.

## Building it

Swift Package Manager, SwiftUI, no dependencies. Needs a full Xcode in `/Applications`.

```sh
scripts/run-app.sh      # build and launch
scripts/test.sh         # regression checks
```

`scripts/build-moltenvk.sh standard` builds the included MoltenVK library, and
`scripts/release.sh` signs and notarizes. The command line interface is
`GPTK Patcher Tool.app/Contents/MacOS/GPTKPatcher --cli --help`.

## Licensing

MIT; see [LICENSE](LICENSE). Most of what this installs was written by other people, and
[CREDITS](CREDITS.md) says who. Apple's toolkit is not redistributed. CrossOver is CodeWeavers'
software and they do not support a patched copy.
