#!/bin/bash
# Source this from build/test scripts; selection applies only to the current process.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    PATCHER_XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -n 1 || true)"
    if [[ -z "$PATCHER_XCODE" ]]; then
        echo "Install Xcode in /Applications, or set DEVELOPER_DIR to its Contents/Developer folder." >&2
        return 1
    fi
    export DEVELOPER_DIR="$PATCHER_XCODE/Contents/Developer"
    echo "Using toolchain from $PATCHER_XCODE"
fi
