#!/bin/bash
# Builds a universal release binary and assembles a runnable app bundle in build/.
# Usage: scripts/build-app.sh            (then open "build/GPTK Patcher Tool.app")
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/toolchain.sh

ARCHS=(--arch arm64 --arch x86_64)
LOG="$(mktemp)"
if ! swift build -c release "${ARCHS[@]}" >"$LOG" 2>&1; then
    cat "$LOG"; rm -f "$LOG"; exit 1
fi
tail -n 1 "$LOG"; rm -f "$LOG"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/GPTKPatcher"

APP="build/GPTK Patcher Tool.app"
rm -rf "$APP" build/GPTKPatcher.app "build/CrossOver GPTK Patcher.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GPTKPatcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# The MoltenVK build the app ships with, so a Vulkan game works without anyone hunting for a
# library. Built by scripts/build-moltenvk.sh; set MOLTENVK_BUNDLE to package a different one.
BUNDLE_SRC="${MOLTENVK_BUNDLE:-}"
if [ -z "$BUNDLE_SRC" ]; then
    BUNDLE_SRC="$(ls -td "$HOME/Library/Application Support/GPTKPatcher/MoltenVK-builds"/MoltenVK-standard-* 2>/dev/null | head -1)"
fi
if [ -n "$BUNDLE_SRC" ] && [ -f "$BUNDLE_SRC/libMoltenVK.dylib" ]; then
    mkdir -p "$APP/Contents/Resources/MoltenVK/standard"
    cp "$BUNDLE_SRC/libMoltenVK.dylib" "$APP/Contents/Resources/MoltenVK/standard/"
    for extra in LICENSE NOTICE.txt; do
        [ -f "$BUNDLE_SRC/$extra" ] && cp "$BUNDLE_SRC/$extra" "$APP/Contents/Resources/MoltenVK/standard/"
    done
    echo "Packaged MoltenVK from $BUNDLE_SRC"
else
    echo "No MoltenVK build to package. Run scripts/build-moltenvk.sh standard first, or set MOLTENVK_BUNDLE." >&2
fi

# Nested code is signed first, as the notarized release build does, so the local app is put
# together the same way.
find "$APP/Contents/Resources" -name '*.dylib' -print0 2>/dev/null |
    while IFS= read -r -d '' lib; do codesign --force --sign - "$lib"; done
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
