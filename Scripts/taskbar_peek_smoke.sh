#!/usr/bin/env bash
# Build and run headless taskbar peek invariant smoke tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/taskbar_peek_smoke"
OBJ="$ROOT/build/obj-taskbar-peek-smoke"
mkdir -p "$OBJ"

INC=(
  -I"$ROOT/Sources/App"
  -I"$ROOT/Sources/Core"
  -I"$ROOT/Sources/UI"
  -I"$ROOT/Sources/System"
)
CFLAGS_M=(-fobjc-arc -O2 -Wall -Wextra "${INC[@]}")
LIBS=(-framework AppKit -framework Foundation -framework ApplicationServices -framework QuartzCore -framework CoreFoundation)

compile_m() {
  local src="$1"
  local base
  base="$(basename "$src" .m)"
  clang "${CFLAGS_M[@]}" -c "$src" -o "$OBJ/${base}.o"
}

UI_SOURCES=(
  "$ROOT/Sources/UI/MLTaskbarController.m"
  "$ROOT/Sources/UI/MLTaskbarController+Peek.m"
  "$ROOT/Sources/UI/MLTaskbarController+Items.m"
  "$ROOT/Sources/UI/MLTaskbarController+Bars.m"
  "$ROOT/Sources/UI/MLTaskbarController+WindowActions.m"
  "$ROOT/Sources/UI/MLTaskbarController+Drag.m"
  "$ROOT/Sources/UI/MLTaskbarView.m"
  "$ROOT/Sources/UI/MLTaskbarScreenBar.m"
  "$ROOT/Sources/UI/MLTaskbarConstants.m"
  "$ROOT/Sources/UI/MLMinimizeInterceptor.m"
  "$ROOT/Sources/UI/MLWorkAreaEnforcer.m"
)

SYSTEM_SOURCES=(
  "$ROOT/Sources/System/MLRunningAppsMonitor.m"
  "$ROOT/Sources/System/MLRunningAppsMonitor+SnapshotBuilder.m"
  "$ROOT/Sources/System/MLWindowCensus.m"
  "$ROOT/Sources/System/MLAXAppObserverRegistry.m"
  "$ROOT/Sources/System/MLWindowSoftState.m"
  "$ROOT/Sources/System/MLScreenGeometry.m"
  "$ROOT/Sources/System/MLIconCache.m"
  "$ROOT/Sources/System/MLTaskbarPinStore.m"
  "$ROOT/Sources/System/MLDebouncedSave.m"
  "$ROOT/Sources/System/MLAppLauncher.m"
  "$ROOT/Sources/System/MLAXWindowHelper.m"
  "$ROOT/Sources/System/MLCGSAlpha.m"
  "$ROOT/Sources/System/MLStrings.m"
)

OBJS=()
for src in "${UI_SOURCES[@]}" "${SYSTEM_SOURCES[@]}"; do
  compile_m "$src"
  OBJS+=("$OBJ/$(basename "$src" .m).o")
done

compile_m "$ROOT/Tools/taskbar_peek_smoke.m"
OBJS+=("$OBJ/taskbar_peek_smoke.o")

clang -o "$OUT" "${OBJS[@]}" "${LIBS[@]}"

echo "[taskbar_peek_smoke] running ..."
"$OUT"
