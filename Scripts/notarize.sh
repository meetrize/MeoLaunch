#!/usr/bin/env bash
# Notarize a signed MeoLaunch DMG (or .app) with notarytool.
#
# Requires Developer ID signature on the app/DMG first.
#
# Auth (pick one):
#   A) APPLE_API_KEY_ID + APPLE_API_ISSUER + APPLE_API_KEY_PATH  (.p8)
#   B) APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID
#
# Usage:
#   ./Scripts/notarize.sh dist/MeoLaunch-0.1.0-macos-universal.dmg
#   NOTARIZE_STAPLE=0 ./Scripts/notarize.sh path/to.dmg
#
set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" || ! -e "$TARGET" ]]; then
  echo "Usage: $0 <signed.dmg|signed.app>" >&2
  exit 2
fi

STAPLE="${NOTARIZE_STAPLE:-1}"
ARGS=()

if [[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" && -n "${APPLE_API_KEY_PATH:-}" ]]; then
  ARGS+=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  ARGS+=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
else
  echo "[notarize] Missing Apple auth env." >&2
  echo "  Set APPLE_API_KEY_ID + APPLE_API_ISSUER + APPLE_API_KEY_PATH" >&2
  echo "  or APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID" >&2
  exit 1
fi

echo "[notarize] submit $TARGET"
xcrun notarytool submit "$TARGET" --wait "${ARGS[@]}"

if [[ "$STAPLE" == "1" ]]; then
  echo "[notarize] staple $TARGET"
  xcrun stapler staple "$TARGET"
  xcrun stapler validate "$TARGET" || true
fi

echo "[notarize] OK"
