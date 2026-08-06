#!/usr/bin/env bash
# Run all project smoke tests (headless).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

run() {
  echo ""
  echo "=== $1 ==="
  "$ROOT/Scripts/$1"
}

run build_core.sh
run scan_smoke.sh
run filter_smoke.sh
run config_smoke.sh
run layout_smoke.sh
run taskbar_peek_smoke.sh

echo ""
echo "smoke_all OK"
