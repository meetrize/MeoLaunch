#!/usr/bin/env bash
# Build MeoLaunch and produce a distributable DMG (drag-to-Applications).
#
# Usage:
#   ./Scripts/package.sh
#   ./Scripts/package.sh --no-build          # reuse existing build/MeoLaunch.app
#   CODESIGN_IDENTITY="Developer ID Application: …" ./Scripts/package.sh
#
# Output:
#   dist/MeoLaunch-<version>.dmg
#   dist/MeoLaunch-<version>.zip
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_APP="$ROOT/build/MeoLaunch.app"
DIST="$ROOT/dist"
DO_BUILD=1
KEEP_STAGE=0

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    --keep-stage) KEEP_STAGE=1 ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--no-build] [--keep-stage]

  Builds MeoLaunch.app, ad-hoc (or Developer ID) signs it, then creates:
    dist/MeoLaunch-<version>.dmg   — drag the app onto Applications
    dist/MeoLaunch-<version>.zip   — alternate archive

Environment:
  CODESIGN_IDENTITY   codesign identity (default: ad-hoc "-")
  INSTALL_DIR         unused here; see release_install.sh for local install
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ "$DO_BUILD" -eq 1 ]]; then
  echo "==> [1/5] Release build"
  "$ROOT/Scripts/build.sh"
else
  echo "==> [1/5] Skip build (--no-build)"
fi

if [[ ! -x "$BUILD_APP/Contents/MacOS/MeoLaunch" ]]; then
  echo "Missing app: $BUILD_APP" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$BUILD_APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$BUILD_APP/Contents/Info.plist" 2>/dev/null || echo "0")"
VOL_NAME="MeoLaunch"
DMG_NAME="MeoLaunch-${VERSION}.dmg"
ZIP_NAME="MeoLaunch-${VERSION}.zip"
DMG_PATH="$DIST/$DMG_NAME"
ZIP_PATH="$DIST/$ZIP_NAME"

echo "==> [2/5] Prepare staging (v${VERSION} build ${BUILD_NUM})"
mkdir -p "$DIST"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/meolaunch-pkg.XXXXXX")"
cleanup() {
  if [[ "$KEEP_STAGE" -eq 0 ]]; then
    rm -rf "$STAGE"
  else
    echo "    Stage kept: $STAGE"
  fi
}
trap cleanup EXIT

# Fresh copy into stage
if command -v ditto >/dev/null 2>&1; then
  ditto "$BUILD_APP" "$STAGE/MeoLaunch.app"
else
  cp -R "$BUILD_APP" "$STAGE/MeoLaunch.app"
fi
ln -s /Applications "$STAGE/Applications"

# Optional drop hint for Finder (plain text; opens fine on any locale)
cat > "$STAGE/Install.txt" <<EOF
MeoLaunch ${VERSION}
====================

Drag MeoLaunch.app onto the Applications folder to install.

将 MeoLaunch.app 拖到 Applications 文件夹即可安装。

After first launch, grant Accessibility if you use the hot corner:
首次启动后，如需使用触发角，请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 MeoLaunch。

Hotkey: ⌥Space
EOF

echo "==> [3/5] Code sign"
xattr -cr "$STAGE/MeoLaunch.app" 2>/dev/null || true
IDENTITY="${CODESIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
  if [[ "$IDENTITY" == "-" ]]; then
    echo "    Ad-hoc sign (-)"
    codesign --force --deep --sign - "$STAGE/MeoLaunch.app"
  else
    echo "    Sign with: $IDENTITY"
    codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$STAGE/MeoLaunch.app"
  fi
  codesign --verify --deep --strict "$STAGE/MeoLaunch.app" || {
    echo "    Warning: codesign verify reported issues" >&2
  }
else
  echo "    codesign not found — skipping"
fi

echo "==> [4/5] Create DMG → $DMG_PATH"
rm -f "$DMG_PATH" "$DIST/.${DMG_NAME}.rw.dmg"
# Compressed read-only DMG from staged folder
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

echo "==> [5/5] Create ZIP → $ZIP_PATH"
rm -f "$ZIP_PATH"
# Zip only the app (most common for “download .zip and move to Applications”)
(
  cd "$STAGE"
  ditto -c -k --keepParent "MeoLaunch.app" "$ZIP_PATH"
)

# Copy install helper next to archives for convenience
cp "$ROOT/Scripts/release_install.sh" "$DIST/release_install.sh" 2>/dev/null || true

SIZE_DMG="$(du -h "$DMG_PATH" | awk '{print $1}')"
SIZE_ZIP="$(du -h "$ZIP_PATH" | awk '{print $1}')"

echo ""
echo "Done."
echo "  DMG: $DMG_PATH ($SIZE_DMG)"
echo "  ZIP: $ZIP_PATH ($SIZE_ZIP)"
echo "  Open: open \"$DMG_PATH\""
echo ""
echo "Local install (no DMG): ./Scripts/release_install.sh"
