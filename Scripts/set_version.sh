#!/usr/bin/env bash
# Write CFBundleShortVersionString / CFBundleVersion into Info.plist.
#
# Usage:
#   ./Scripts/set_version.sh 0.2.0
#   ./Scripts/set_version.sh v0.2.0          # strips leading v
#   ./Scripts/set_version.sh 0.2.0 42        # marketing + build number
#   VERSION=0.2.0 BUILD_NUMBER=42 ./Scripts/set_version.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/App/Info.plist"

RAW="${1:-${VERSION:-}}"
BUILD_NUM="${2:-${BUILD_NUMBER:-}}"

if [[ -z "$RAW" ]]; then
  echo "Usage: $0 <version> [build_number]" >&2
  exit 2
fi

VERSION="${RAW#v}"
VERSION="${VERSION#V}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$ ]]; then
  echo "Invalid version: $VERSION (expect semver like 0.1.0)" >&2
  exit 2
fi

if [[ -z "$BUILD_NUM" ]]; then
  # Prefer numeric run id / timestamp-friendly default from git commit count
  if git -C "$ROOT" rev-list --count HEAD >/dev/null 2>&1; then
    BUILD_NUM="$(git -C "$ROOT" rev-list --count HEAD)"
  else
    BUILD_NUM="$(date +%Y%m%d%H%M)"
  fi
fi

if [[ ! -f "$PLIST" ]]; then
  echo "Missing Info.plist: $PLIST" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$PLIST"

echo "[set_version] CFBundleShortVersionString=$VERSION CFBundleVersion=$BUILD_NUM"
echo "              → $PLIST"
