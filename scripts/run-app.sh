#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
open "build/GPTK Patcher Tool.app"
