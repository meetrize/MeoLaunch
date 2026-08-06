#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/layout_smoke"
OBJ="$ROOT/build/obj_layout_smoke"
mkdir -p "$OBJ" "$(dirname "$OUT")"

INC=(-I"$ROOT/Sources/Core" -I"$ROOT/Sources/System")
CFLAGS_C=(-std=c11 -O2 -Wall -Wextra "${INC[@]}")
CFLAGS_M=(-fobjc-arc -O2 -Wall -Wextra "${INC[@]}")

clang "${CFLAGS_C[@]}" -c "$ROOT/Sources/Core/ml_util.c" -o "$OBJ/ml_util.o"
clang "${CFLAGS_C[@]}" -c "$ROOT/Sources/Core/ml_app_index.c" -o "$OBJ/ml_app_index.o"
clang "${CFLAGS_C[@]}" -c "$ROOT/Sources/Core/ml_layout.c" -o "$OBJ/ml_layout.o"
clang "${CFLAGS_M[@]}" -c "$ROOT/Sources/System/MLDebouncedSave.m" -o "$OBJ/MLDebouncedSave.o"
clang "${CFLAGS_M[@]}" -c "$ROOT/Sources/System/MLLayoutStore.m" -o "$OBJ/MLLayoutStore.o"
clang "${CFLAGS_M[@]}" -c "$ROOT/Tools/layout_smoke.m" -o "$OBJ/layout_smoke.o"

clang -o "$OUT" "$OBJ/ml_util.o" "$OBJ/ml_app_index.o" "$OBJ/ml_layout.o" \
  "$OBJ/MLDebouncedSave.o" "$OBJ/MLLayoutStore.o" "$OBJ/layout_smoke.o" \
  -framework Foundation -framework AppKit

echo "[layout_smoke] running ..."
TMP="$(mktemp -t meolaunch-layout)"
export MEOLAUNCH_LAYOUT_PATH="$TMP"
"$OUT"
rm -f "$TMP"
