#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/filter_smoke"
OBJ="$ROOT/build/obj-filter-smoke"
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

clang "${CFLAGS[@]}" -c "$ROOT/Tools/filter_smoke.c" -o "$OBJ/filter_smoke.o"
OBJS+=("$OBJ/filter_smoke.o")

clang -o "$OUT" "${OBJS[@]}" "${LIBS[@]}"
echo "[filter_smoke] running ..."
"$OUT"
