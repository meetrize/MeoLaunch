#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MeoLaunch.app"

if [[ ! -x "$APP/Contents/MacOS/MeoLaunch" ]]; then
  echo "App not built. Running build.sh ..."
  "$ROOT/Scripts/build.sh"
fi

open "$APP"
echo "[run] opened $APP"
