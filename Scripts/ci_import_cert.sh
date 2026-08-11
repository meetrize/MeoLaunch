#!/usr/bin/env bash
# Import a Developer ID .p12 (base64) into a temporary keychain for CI codesign.
#
# Env:
#   APPLE_CERTIFICATE_BASE64   required
#   APPLE_CERTIFICATE_PASSWORD required
#   KEYCHAIN_PASSWORD          optional (random if unset)
#
# Exports:
#   RUNNER_TEMP/meolaunch.keychain-db (side effect)
#   Prints identity name hint to GITHUB_ENV as CODESIGN_IDENTITY if detectable
#
set -euo pipefail

if [[ -z "${APPLE_CERTIFICATE_BASE64:-}" || -z "${APPLE_CERTIFICATE_PASSWORD:-}" ]]; then
  echo "[ci_import_cert] APPLE_CERTIFICATE_BASE64 / APPLE_CERTIFICATE_PASSWORD not set — skip"
  exit 0
fi

KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-$(openssl rand -base64 32)}"
KC="${RUNNER_TEMP:-/tmp}/meolaunch.keychain-db"
CERT_PATH="${RUNNER_TEMP:-/tmp}/meolaunch-cert.p12"

echo "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$CERT_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KC"
security import "$CERT_PATH" -P "$APPLE_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KC"
security list-keychain -d user -s "$KC"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KC"

# Prefer Developer ID Application identity
IDENTITY="$(security find-identity -v -p codesigning "$KC" | awk -F'\"' '/Developer ID Application/{print $2; exit}')"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning "$KC" | awk -F'\"' '/\"/{print $2; exit}')"
fi

if [[ -n "$IDENTITY" ]]; then
  echo "CODESIGN_IDENTITY=$IDENTITY" >> "${GITHUB_ENV:-/dev/null}"
  echo "[ci_import_cert] Using identity: $IDENTITY"
else
  echo "[ci_import_cert] Warning: no codesigning identity found in keychain" >&2
fi

rm -f "$CERT_PATH"
