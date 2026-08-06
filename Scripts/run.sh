#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MeoLaunch.app"

if [[ ! -x "$APP/Contents/MacOS/MeoLaunch" ]]; then
  echo "App not built. Running build.sh ..."
  "$ROOT/Scripts/build.sh"
fi

# Re-sign so TCC csreq matches the binary we are about to grant.
xattr -cr "$APP" 2>/dev/null || true
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

"$ROOT/Scripts/grant_accessibility.sh" "$APP" 2>/dev/null || \
  echo "[run] Accessibility auto-grant skipped (run ./Scripts/install.sh once with sudo)"

open "$APP"
echo "[run] opened $APP"
