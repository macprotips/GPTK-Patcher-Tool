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
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
