#!/usr/bin/env bash
# Interactive manual regression for .cursor/rules/taskbar-peek-invariants.mdc §7.
# Run while MeoLaunch taskbar is active: ./Scripts/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Taskbar Peek Manual Checklist ==="
echo "Ensure MeoLaunch is running with taskbar enabled before starting."
echo ""

pass=0
fail=0
skip=0

ask() {
  local n="$1"
  local text="$2"
  echo ""
  echo "[$n] $text"
  read -r -p "    pass / fail / skip? [p/f/s]: " ans
  case "${ans,,}" in
    p|pass|y|yes) pass=$((pass + 1)); echo "    → recorded PASS" ;;
    f|fail|n|no) fail=$((fail + 1)); echo "    → recorded FAIL" ;;
    s|skip) skip=$((skip + 1)); echo "    → skipped" ;;
    *) echo "    → invalid, counted as skip"; skip=$((skip + 1)) ;;
  esac
}

ask 1 "All minimized → bar stays normal (no Y offset / half-down peek)."
ask 2 "All windows closed → bar stays normal (no auto peek)."
ask 3 "All closed → click desktop → bar slides ~half down; click desktop again → restore."
ask 4 "All minimized → click desktop → bar slides ~half down; click desktop again → full restore."
ask 5 "All minimized → click chip to restore → no peek flash."
ask 6 "Multi-screen: windows on screen 2 → Show Desktop / peek → chips stay on screen 2 bar."
ask 7 "Exit peek → chips return to same screens (no cross-screen hop during settle)."
ask 8 "Same screen: drag pin chip → placeholder gap; drop reorders; restart keeps pin order."
ask 9 "Same screen: drag window chip within window zone → order sticks across poll."
ask 10 "Cross-screen: drag window chip to other bar → real window moves; chip lands at insert; no hop-back."
ask 11 "Cannot drop pin into window zone (or window into pin zone); short click still activates."
ask 12 "During peek/freeze, drag does not start; entering peek cancels an in-progress drag."

echo ""
echo "=== Summary ==="
echo "  PASS: $pass"
echo "  FAIL: $fail"
echo "  SKIP: $skip"

if [[ "$fail" -gt 0 ]]; then
  echo "Checklist FAILED — fix regressions before shipping peek changes."
  exit 1
fi

echo "Checklist OK (automated logic: ./Scripts/taskbar_peek_smoke.sh)"
exit 0
