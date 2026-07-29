#!/usr/bin/env bash
# Compile Core C sources only (smoke test, no AppKit).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/core-objs"
mkdir -p "$OUT"

CFLAGS=(-std=c11 -O2 -Wall -Wextra -I"$ROOT/Sources/Core")

echo "[build_core] compiling Sources/Core/*.c ..."
for src in "$ROOT"/Sources/Core/*.c; do
  base="$(basename "$src" .c)"
  clang "${CFLAGS[@]}" -c "$src" -o "$OUT/${base}.o"
done

echo "[build_core] OK — objects in $OUT"
