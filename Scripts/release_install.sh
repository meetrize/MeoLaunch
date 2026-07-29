#!/usr/bin/env bash
# One-click release build + install MeoLaunch into Applications.
#
# Usage:
#   ./Scripts/release_install.sh
#   ./Scripts/release_install.sh --no-open
#   INSTALL_DIR="$HOME/Applications" ./Scripts/release_install.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_APP="$ROOT/build/MeoLaunch.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/MeoLaunch.app"
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

echo "==> [1/5] Release build"
"$ROOT/Scripts/build.sh"

if [[ ! -x "$BUILD_APP/Contents/MacOS/MeoLaunch" ]]; then
  echo "Build failed: missing $BUILD_APP" >&2
  exit 1
fi

echo "==> [2/5] Ad-hoc code sign (local Developer ID not required)"
# Clear extended attrs that can block launch after copy
xattr -cr "$BUILD_APP" 2>/dev/null || true
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$BUILD_APP" 2>/dev/null || \
    echo "    (codesign skipped / failed — continuing)"
fi

echo "==> [3/5] Quit running MeoLaunch (if any)"
pkill -x MeoLaunch 2>/dev/null || true
# Also quit copies launched from /Applications
sleep 0.4

echo "==> [4/5] Install → $DEST"
mkdir -p "$INSTALL_DIR"

install_copy() {
  # Atomic-ish replace: stage then swap
  local stage="${DEST}.installing"
  rm -rf "$stage"
  if command -v ditto >/dev/null 2>&1; then
    ditto "$BUILD_APP" "$stage"
  else
    cp -R "$BUILD_APP" "$stage"
  fi
  rm -rf "$DEST"
  mv "$stage" "$DEST"
  xattr -cr "$DEST" 2>/dev/null || true
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$DEST" 2>/dev/null || true
  fi
}

if ! install_copy 2>/dev/null; then
  echo "    Direct install failed (permission?). Retrying with sudo…"
  sudo mkdir -p "$INSTALL_DIR"
  sudo rm -rf "${DEST}.installing" "$DEST"
  if command -v ditto >/dev/null 2>&1; then
    sudo ditto "$BUILD_APP" "$DEST"
  else
    sudo cp -R "$BUILD_APP" "$DEST"
  fi
  sudo xattr -cr "$DEST" 2>/dev/null || true
  if command -v codesign >/dev/null 2>&1; then
    sudo codesign --force --deep --sign - "$DEST" 2>/dev/null || true
  fi
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")"

echo "==> [5/5] Done"
echo "    Installed: $DEST"
echo "    Version:   $VERSION ($BUILD)"
echo "    Tip: grant Accessibility for hot corner if prompted."

if [[ "$OPEN_AFTER" -eq 1 ]]; then
  echo "    Opening…"
  open "$DEST"
fi
