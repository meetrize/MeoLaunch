#!/usr/bin/env bash
# A0 spike: enumerate Core Audio process objects; optional --mute <pid>.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/audio_spike"
OBJ="$ROOT/build/obj-audio-spike"
mkdir -p "$OBJ"

INC=(
  -I"$ROOT/Sources/System"
)
CFLAGS_M=(-fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-13.0}" "${INC[@]}")
LIBS=(-framework Foundation -framework AppKit -framework CoreAudio)

clang "${CFLAGS_M[@]}" -c "$ROOT/Sources/System/MLAudioProcessSupport.m" -o "$OBJ/MLAudioProcessSupport.o"
clang "${CFLAGS_M[@]}" -c "$ROOT/Sources/System/MLAppAudioMuteController.m" -o "$OBJ/MLAppAudioMuteController.o"
clang "${CFLAGS_M[@]}" -c "$ROOT/Scripts/audio_spike_main.m" -o "$OBJ/audio_spike_main.o"

clang -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-13.0}" \
  -o "$OUT" \
  "$OBJ/MLAudioProcessSupport.o" \
  "$OBJ/MLAppAudioMuteController.o" \
  "$OBJ/audio_spike_main.o" \
  "${LIBS[@]}"

echo "[audio_spike] built $OUT"
"$OUT" "$@"
