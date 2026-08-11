#!/usr/bin/env bash
# CI / local entry: set version → universal build → package → checksums.
#
# Usage:
#   ./Scripts/ci_package.sh
#   ./Scripts/ci_package.sh v0.2.0
#   VERSION=0.2.0 UNIVERSAL=1 ./Scripts/ci_package.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
TAG_OR_VERSION="${1:-${VERSION:-}}"
UNIVERSAL="${UNIVERSAL:-1}"
DO_NOTARIZE="${DO_NOTARIZE:-0}"

if [[ -n "$TAG_OR_VERSION" ]]; then
  "$ROOT/Scripts/set_version.sh" "$TAG_OR_VERSION" "${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$ROOT/Sources/App/Info.plist")"

if [[ "$UNIVERSAL" == "1" ]]; then
  export ARCHS="arm64 x86_64"
  echo "==> Universal build (arm64 + x86_64)"
  "$ROOT/Scripts/build.sh" --universal
else
  echo "==> Host-arch build"
  "$ROOT/Scripts/build.sh"
fi

# package.sh rebuilds by default; skip since we already built
ASSET_SUFFIX="${ASSET_SUFFIX:-macos-universal}"
export PACKAGE_ASSET_SUFFIX="$ASSET_SUFFIX"
"$ROOT/Scripts/package.sh" --no-build

# Prefer suffix-named artifacts for releases
shopt -s nullglob
for f in "$DIST"/MeoLaunch-"$VERSION".dmg "$DIST"/MeoLaunch-"$VERSION".zip; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"
  ext="${base##*.}"
  dest="$DIST/MeoLaunch-${VERSION}-${ASSET_SUFFIX}.${ext}"
  if [[ "$f" != "$dest" ]]; then
    mv -f "$f" "$dest"
  fi
done

# Convenience un-suffixed copies (website download links)
if [[ -f "$DIST/MeoLaunch-${VERSION}-${ASSET_SUFFIX}.dmg" ]]; then
  cp -f "$DIST/MeoLaunch-${VERSION}-${ASSET_SUFFIX}.dmg" "$DIST/MeoLaunch-${VERSION}.dmg"
fi
if [[ -f "$DIST/MeoLaunch-${VERSION}-${ASSET_SUFFIX}.zip" ]]; then
  cp -f "$DIST/MeoLaunch-${VERSION}-${ASSET_SUFFIX}.zip" "$DIST/MeoLaunch-${VERSION}.zip"
fi

if [[ "$DO_NOTARIZE" == "1" ]]; then
  DMG="$DIST/MeoLaunch-${VERSION}-${ASSET_SUFFIX}.dmg"
  if [[ -n "${CODESIGN_IDENTITY:-}" && "${CODESIGN_IDENTITY:-}" != "-" ]]; then
    "$ROOT/Scripts/notarize.sh" "$DMG"
  else
    echo "==> Skip notarize (no Developer ID CODESIGN_IDENTITY)"
  fi
fi

(
  cd "$DIST"
  rm -f SHA256SUMS.txt
  shopt -s nullglob
  files=(MeoLaunch-"$VERSION"*.dmg MeoLaunch-"$VERSION"*.zip)
  if [[ "${#files[@]}" -gt 0 ]]; then
    shasum -a 256 "${files[@]}" | tee SHA256SUMS.txt
  fi
)

echo ""
echo "CI package ready in $DIST"
ls -lh "$DIST"/MeoLaunch-"$VERSION"* "$DIST"/SHA256SUMS.txt 2>/dev/null || true
