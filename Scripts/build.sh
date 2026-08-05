#!/usr/bin/env bash
# Build MeoLaunch.app with clang (works with Command Line Tools).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/MeoLaunch.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
OBJ="$BUILD/obj"

mkdir -p "$MACOS" "$RES" "$OBJ"

INC=(
  -I"$ROOT/Sources/App"
  -I"$ROOT/Sources/Core"
  -I"$ROOT/Sources/UI"
  -I"$ROOT/Sources/System"
)

CFLAGS_C=(-std=c11 -O2 -Wall -Wextra "${INC[@]}")
CFLAGS_M=(-fobjc-arc -O2 -Wall -Wextra "${INC[@]}")
LIBS=(-framework AppKit -framework Foundation -framework ApplicationServices -framework Carbon -framework CoreFoundation -framework QuartzCore -framework ServiceManagement -framework CoreServices)

OBJS=()

echo "[build] compiling Core (.c) ..."
for src in "$ROOT"/Sources/Core/*.c; do
  base="$(basename "$src" .c)"
  out="$OBJ/${base}.o"
  clang "${CFLAGS_C[@]}" -c "$src" -o "$out"
  OBJS+=("$out")
done

echo "[build] compiling App/UI/System (.m) ..."
for dir in App UI System; do
  for src in "$ROOT"/Sources/"$dir"/*.m; do
    [[ -f "$src" ]] || continue
    base="$(basename "$src" .m)"
    out="$OBJ/${base}.o"
    clang "${CFLAGS_M[@]}" -c "$src" -o "$out"
    OBJS+=("$out")
  done
done

echo "[build] linking MeoLaunch ..."
clang -o "$MACOS/MeoLaunch" "${OBJS[@]}" "${LIBS[@]}"

echo "[build] assembling bundle ..."
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
echo "        run: ./Scripts/run.sh"
