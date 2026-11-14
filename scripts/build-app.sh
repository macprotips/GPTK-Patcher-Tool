#!/bin/bash
# Builds a universal release binary and assembles a runnable app bundle in build/.
# Usage: scripts/build-app.sh            (then open "build/GPTK Patcher Tool.app")
#        REQUIRE_MOLTENVK=1 scripts/build-app.sh   (fail unless the pinned MoltenVK is packaged)
set -euo pipefail
cd "$(dirname "$0")/.."

# The MoltenVK build the app ships with, so a Vulkan game works without anyone hunting for a
# library. Built by scripts/build-moltenvk.sh standard, at the release moltenvk/VERSION names;
# set MOLTENVK_BUNDLE to package a different folder. Checked before the slow build, so a release
# without it stops at once.
PINNED="$(tr -d '[:space:]' < moltenvk/VERSION)"
BUILDS="$HOME/Library/Application Support/GPTKPatcher/MoltenVK-builds"
BUNDLE_SRC="${MOLTENVK_BUNDLE:-$BUILDS/MoltenVK-standard-$PINNED}"
if [ "${REQUIRE_MOLTENVK:-0}" = 1 ]; then
    if [ ! -f "$BUNDLE_SRC/libMoltenVK.dylib" ]; then
        echo "error: no MoltenVK build at $BUNDLE_SRC. Run scripts/build-moltenvk.sh standard first." >&2
        exit 1
    fi
    if ! head -n 1 "$BUNDLE_SRC/NOTICE.txt" 2>/dev/null | grep -q "^MoltenVK $PINNED "; then
        echo "error: $BUNDLE_SRC is not MoltenVK $PINNED (see its NOTICE.txt). Rebuild it with scripts/build-moltenvk.sh standard." >&2
        exit 1
    fi
elif [ ! -f "$BUNDLE_SRC/libMoltenVK.dylib" ] && [ -z "${MOLTENVK_BUNDLE:-}" ]; then
    # A local build can fall back to whichever standard build is newest.
    NEWEST="$(ls -td "$BUILDS"/MoltenVK-standard-* 2>/dev/null | head -1)"
    if [ -n "$NEWEST" ]; then
        echo "MoltenVK $PINNED is not built; packaging $(basename "$NEWEST") instead. A release needs $PINNED." >&2
        BUNDLE_SRC="$NEWEST"
    fi
fi

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
if [ -f "$BUNDLE_SRC/libMoltenVK.dylib" ]; then
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
