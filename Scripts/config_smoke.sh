#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/config_smoke"
OBJ="$ROOT/build/obj-config-smoke"
mkdir -p "$OBJ"

INC=(
  -I"$ROOT/Sources/Core"
  -I"$ROOT/Sources/System"
)
CFLAGS_C=(-std=c11 -O2 -Wall -Wextra "${INC[@]}")
CFLAGS_M=(-fobjc-arc -O2 -Wall -Wextra "${INC[@]}")

# Need ml_grid.h only via headers; ConfigStore is ObjC + Foundation/AppKit
clang "${CFLAGS_M[@]}" -c "$ROOT/Sources/System/MLConfigStore.m" -o "$OBJ/MLConfigStore.o"
clang "${CFLAGS_M[@]}" -c "$ROOT/Tools/config_smoke.m" -o "$OBJ/config_smoke.o"

clang -o "$OUT" "$OBJ/MLConfigStore.o" "$OBJ/config_smoke.o" \
  -framework Foundation -framework AppKit

echo "[config_smoke] running ..."
"$OUT"
