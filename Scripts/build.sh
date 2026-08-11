#!/usr/bin/env bash
# Build MeoLaunch.app with clang (works with Command Line Tools).
#
# Usage:
#   ./Scripts/build.sh
#   ./Scripts/build.sh --universal          # arm64 + x86_64 → lipo
#   ARCHS="arm64" ./Scripts/build.sh
#   ARCHS="x86_64" ./Scripts/build.sh
#   ARCHS="arm64 x86_64" ./Scripts/build.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/MeoLaunch.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
OBJ="$BUILD/obj"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

ARCHS_DEFAULT="$(uname -m)"
case "${1:-}" in
  --universal|-u)
    ARCHS="arm64 x86_64"
    shift || true
    ;;
  --help|-h)
    cat <<EOF
Usage: $0 [--universal]

  Builds build/MeoLaunch.app

Environment:
  ARCHS                      space-separated: arm64, x86_64 (default: host)
  MACOSX_DEPLOYMENT_TARGET   default 13.0
EOF
    exit 0
    ;;
esac

ARCHS="${ARCHS:-$ARCHS_DEFAULT}"
# shellcheck disable=SC2206
ARCH_LIST=($ARCHS)

mkdir -p "$MACOS" "$RES" "$OBJ"
rm -rf "$OBJ"
mkdir -p "$OBJ"

INC=(
  -I"$ROOT/Sources/App"
  -I"$ROOT/Sources/Core"
  -I"$ROOT/Sources/UI"
  -I"$ROOT/Sources/System"
)

LIBS=(
  -framework AppKit
  -framework Foundation
  -framework ApplicationServices
  -framework Carbon
  -framework CoreFoundation
  -framework QuartzCore
  -framework ServiceManagement
  -framework CoreServices
)

COMMON_FLAGS=(-mmacosx-version-min="$MIN_MACOS" "${INC[@]}")
CFLAGS_C=(-std=c11 -O2 -Wall -Wextra "${COMMON_FLAGS[@]}")
CFLAGS_M=(-fobjc-arc -O2 -Wall -Wextra "${COMMON_FLAGS[@]}")

compile_arch() {
  local arch="$1"
  local arch_obj="$OBJ/$arch"
  local bin_out="$2"
  mkdir -p "$arch_obj"
  local objs=()

  echo "[build] compiling Core (.c) for $arch ..."
  for src in "$ROOT"/Sources/Core/*.c; do
    base="$(basename "$src" .c)"
    out="$arch_obj/${base}.o"
    clang -arch "$arch" "${CFLAGS_C[@]}" -c "$src" -o "$out"
    objs+=("$out")
  done

  echo "[build] compiling App/UI/System (.m) for $arch ..."
  for dir in App UI System; do
    for src in "$ROOT"/Sources/"$dir"/*.m; do
      [[ -f "$src" ]] || continue
      base="$(basename "$src" .m)"
      out="$arch_obj/${base}.o"
      clang -arch "$arch" "${CFLAGS_M[@]}" -c "$src" -o "$out"
      objs+=("$out")
    done
  done

  echo "[build] linking MeoLaunch ($arch) ..."
  clang -arch "$arch" -mmacosx-version-min="$MIN_MACOS" \
    -o "$bin_out" "${objs[@]}" "${LIBS[@]}"
}

BINARIES=()
for arch in "${ARCH_LIST[@]}"; do
  case "$arch" in
    arm64|x86_64) ;;
    *)
      echo "Unsupported ARCH: $arch (use arm64 or x86_64)" >&2
      exit 2
      ;;
  esac
  out_bin="$OBJ/MeoLaunch-$arch"
  compile_arch "$arch" "$out_bin"
  BINARIES+=("$out_bin")
done

echo "[build] assembling bundle ..."
mkdir -p "$MACOS"
if [[ "${#BINARIES[@]}" -eq 1 ]]; then
  cp "${BINARIES[0]}" "$MACOS/MeoLaunch"
else
  echo "[build] lipo universal → $MACOS/MeoLaunch (${ARCH_LIST[*]})"
  lipo -create -output "$MACOS/MeoLaunch" "${BINARIES[@]}"
fi
chmod +x "$MACOS/MeoLaunch"

cp "$ROOT/Sources/App/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$RES"
# Advertise en + zh-Hans so Launch Services / NSURLLocalizedNameKey follow the
# system language when resolving other apps' display names (otherwise the
# process stays English-only and Launchpad labels stay English).
mkdir -p "$RES/en.lproj" "$RES/zh-Hans.lproj"
touch "$RES/en.lproj/.keep" "$RES/zh-Hans.lproj/.keep"
if [[ -f "$ROOT/Sources/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Sources/Resources/AppIcon.icns" "$RES/AppIcon.icns"
fi
for icon in MenuBarIcon.png "MenuBarIcon@2x.png"; do
  if [[ -f "$ROOT/Sources/Resources/$icon" ]]; then
    cp "$ROOT/Sources/Resources/$icon" "$RES/$icon"
  fi
done
if [[ -d "$ROOT/Sources/Resources/Assets.xcassets" ]]; then
  cp -R "$ROOT/Sources/Resources/Assets.xcassets" "$RES/" 2>/dev/null || true
fi

echo "[build] OK — $APP"
echo "        arch: $(lipo -archs "$MACOS/MeoLaunch" 2>/dev/null || uname -m)"
echo "        run: ./Scripts/run.sh"
