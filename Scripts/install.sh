#!/usr/bin/env bash
# One-click build + install + auto-grant Accessibility.
#
# Usage:
#   ./Scripts/install.sh
#   ./Scripts/install.sh --no-open
#   INSTALL_DIR="$HOME/Applications" ./Scripts/install.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUDO_PASS="${SUDO_PASS:-dddd}"
export SUDO_PASS

OPEN_AFTER=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_AFTER=0 ;;
    --help|-h)
      echo "Usage: $0 [--no-open]"
      echo "  INSTALL_DIR=/path  override install location (default: /Applications)"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

# Reuse release install (build + copy + sign)
if [[ "$OPEN_AFTER" -eq 0 ]]; then
  "$ROOT/Scripts/release_install.sh" --no-open
else
  "$ROOT/Scripts/release_install.sh" --no-open
fi

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/MeoLaunch.app"
BUILD_APP="$ROOT/build/MeoLaunch.app"

echo "==> [6/6] Auto-grant Accessibility"
GRANT_OK=1
if ! "$ROOT/Scripts/grant_accessibility.sh" "$DEST"; then
  GRANT_OK=0
fi
if ! "$ROOT/Scripts/grant_accessibility.sh" "$BUILD_APP"; then
  GRANT_OK=0
fi

echo "==> Done"
echo "    Installed: $DEST"
if [[ "$GRANT_OK" -eq 1 ]]; then
  echo "    Accessibility granted (no manual toggle needed after rebuild)."
else
  echo "    Accessibility auto-grant incomplete — see messages above."
fi

if [[ "$OPEN_AFTER" -eq 1 ]]; then
  echo "    Opening…"
  open "$DEST"
fi
