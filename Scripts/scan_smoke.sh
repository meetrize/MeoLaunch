#!/usr/bin/env bash
# M1a: compile and run app-index smoke test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/scan_smoke"
OBJ="$ROOT/build/obj-smoke"
mkdir -p "$OBJ"

INC=(-I"$ROOT/Sources/Core")
CFLAGS=(-std=c11 -O2 -Wall -Wextra "${INC[@]}")
LIBS=(-framework CoreFoundation)

OBJS=()
for src in "$ROOT"/Sources/Core/*.c; do
  base="$(basename "$src" .c)"
  clang "${CFLAGS[@]}" -c "$src" -o "$OBJ/${base}.o"
  OBJS+=("$OBJ/${base}.o")
done

clang "${CFLAGS[@]}" -c "$ROOT/Tools/scan_smoke.c" -o "$OBJ/scan_smoke.o"
OBJS+=("$OBJ/scan_smoke.o")

clang -o "$OUT" "${OBJS[@]}" "${LIBS[@]}"
echo "[scan_smoke] running ..."
"$OUT"
