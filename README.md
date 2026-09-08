# GPTK Patcher Tool

CrossOver ships with a build of Apple's Game Porting Toolkit. This replaces it with a different
one, in a duplicate of CrossOver or in the installed app, and sets up DLSS → MetalFX.

## Requirements

- macOS 14 or later, Apple Silicon.
- CrossOver 25, 26, or CrossOver Preview 27.
- A Game Porting Toolkit disk image from Apple's developer downloads. Nothing from Apple is
  redistributed here; you supply your own copy.

## Using it

1. Drop `CrossOver.app` and the toolkit `.dmg` onto the two tiles. Either tile takes either file.
   Files can also be dropped on the app icon, pasted with ⌘V, or picked with a file chooser. The
   full `Game_Porting_Toolkit_x.dmg` works directly; the evaluation-environment image inside it is
   found automatically.
2. Choose **Duplicate CrossOver** or **Patch Existing**.
3. Click **Patch CrossOver**.

Imported toolkits are kept in `~/Library/Application Support/GPTKPatcher/Toolkits/<version>/` and
picked from the menu on the toolkit tile.

Patched apps appear in the **Patched** list. *Reveal in Finder* shows the app; the gear sets the
D3DMetal frame rate cap, the Metal Performance HUD and Metal 4, either for every bottle that app
launches or for one bottle. Applying to all bottles clears those keys from the individual bottle
configs, which would otherwise take precedence.

## What patching does

- **Duplicate:** APFS-clones CrossOver and saves it as `CrossOver (GPTK x).app` in `/Applications`,
  or `~/Applications` if that is not writable. A taken name gets a counter; nothing is replaced.
- **Patch Existing:** modifies the selected app and refuses while it is running. Its bottle
  sessions are ended first. Afterwards the app is renamed to `CrossOver (GPTK x).app` unless that
  name is taken, and moved into Applications if it was somewhere like Downloads. Re-patching keeps
  any frame rate cap or HUD setting.
- Replaces `apple_gptk` with the toolkit's copy, keeping the original as `apple_gptk.stock`. A
  second patch replaces only the previous patch. On failure or quit, the folder, receipt and config
  files are restored and an unfinished duplicate is deleted.
- Creates `nvngx.dll` and `nvngx.so` copies of the toolkit's `nvngx-on-metalfx` shim. CrossOver's
  loader redirects a game's `nvngx.dll` to that file; without it DLSS games get no MetalFX.
- Writes `D3DM_ENABLE_METALFX=1` and `DXMT_ENABLE_NVEXT=1` to the app's
  `Contents/SharedSupport/CrossOver/etc/CrossOver.conf`, which CrossOver applies to every bottle it
  launches. A bottle's own `cxbottle.conf` overrides it.
- Opens the app once and quits it if it has never been opened. macOS verifies a downloaded app on
  first launch and a patched bundle fails that check, so a never-opened download would be reported
  as damaged. No other CrossOver may be running at that point. The download record is then removed,
  otherwise macOS runs the app from a translocated copy.
- Leaves `gptkpatcher-receipt.json` in the app's SharedSupport folder.

## Compatibility

- CrossOver 25/26 (`lib64/apple_gptk`) and CrossOver Preview 27 (`lib/apple_gptk`). The Preview's
  `lib/apple_gptk3` is left alone; only bottles with `CX_GRAPHICS_BACKEND_VERSION=3` use it. The
  toolkit serves Intel (x86_64) bottles; ARM64 bottles are unaffected.
- GPTK evaluation environments 2.1 through 4.0.

## Undo

Delete `apple_gptk` inside the app and rename `apple_gptk.stock` back, or trash the duplicate.
Config edits keep a `.gptkpatcher.bak` next to the file they changed.

## Licensing

MIT; see [LICENSE](LICENSE). That covers this project's code.

Apple's Game Porting Toolkit is not included or redistributed here, and stays under Apple's terms.
An imported toolkit keeps the licence, acknowledgements and read-me from its disk image in
`~/Library/Application Support/GPTKPatcher/Toolkits/<version>/Apple Toolkit Documents/`. CrossOver
is CodeWeavers' commercial software; this modifies a copy you already own.

## Support

A patched CrossOver is not supported by CodeWeavers. Problems should be reproduced with an
unmodified CrossOver before contacting their support.
