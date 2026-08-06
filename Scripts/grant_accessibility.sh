#!/usr/bin/env bash
# Grant kTCCServiceAccessibility to MeoLaunch (or any .app path).
#
# Strategy:
#   1) Try TCC sqlite (fast; needs Terminal/Cursor Full Disk Access on recent macOS)
#   2) Fall back to System Settings UI automation (needs Accessibility for the terminal)
#
# Usage:
#   ./Scripts/grant_accessibility.sh /Applications/MeoLaunch.app
#   ./Scripts/grant_accessibility.sh   # defaults to build/MeoLaunch.app
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/MeoLaunch.app}"
SUDO_PASS="${SUDO_PASS:-dddd}"
SYSTEM_TCC="/Library/Application Support/com.apple.TCC/TCC.db"
USER_TCC="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

if [[ ! -d "$APP_PATH" ]]; then
  echo "grant_accessibility: not an app bundle: $APP_PATH" >&2
  exit 1
fi

generate_csreq_sql() {
  local app="$1"
  local req hex tmp
  req=$(codesign -display -r- "$app" 2>&1 | awk -F ' => ' '/designated/{print $2}')
  if [[ -z "$req" ]] || ! command -v csreq >/dev/null 2>&1; then
    echo "NULL"
    return 0
  fi
  tmp="$(mktemp -t meolaunch_csreq.XXXXXX)"
  if ! echo "$req" | csreq -r- -b "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "NULL"
    return 0
  fi
  hex=$(xxd -p "$tmp" | tr -d '\n')
  rm -f "$tmp"
  if [[ -z "$hex" ]]; then
    echo "NULL"
  else
    echo "X'${hex}'"
  fi
}

build_insert_sql() {
  local client="$1"
  local client_type="$2"
  local csreq_sql="$3"
  local ts="$4"
  cat <<SQL
INSERT OR REPLACE INTO access(
  service,client,client_type,auth_value,auth_reason,auth_version,
  csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,
  indirect_object_code_identity,flags,last_modified
) VALUES(
  'kTCCServiceAccessibility','${client}',${client_type},2,4,1,
  ${csreq_sql},NULL,0,'UNUSED',NULL,0,${ts}
);
SQL
}

sqlite_grant_db() {
  local db="$1"
  local use_sudo="${2:-0}"
  local sql_path sql_bundle err

  [[ -f "$db" ]] || return 1

  sql_path="$(build_insert_sql "$APP_PATH" 1 "$CSREQ_SQL" "$TS")"
  if [[ "$use_sudo" -eq 1 ]]; then
    err=$(echo "$SUDO_PASS" | sudo -S sqlite3 "$db" "$sql_path" 2>&1) || {
      [[ "$err" == *"authorization denied"* ]] && return 2
      echo "$err" >&2
      return 1
    }
  else
    err=$(sqlite3 "$db" "$sql_path" 2>&1) || {
      [[ "$err" == *"authorization denied"* ]] && return 2
      echo "$err" >&2
      return 1
    }
  fi

  if [[ -n "$BUNDLE_ID" ]]; then
    sql_bundle="$(build_insert_sql "$BUNDLE_ID" 0 "$CSREQ_SQL" "$TS")"
    if [[ "$use_sudo" -eq 1 ]]; then
      echo "$SUDO_PASS" | sudo -S sqlite3 "$db" "$sql_bundle" 2>/dev/null || true
    else
      sqlite3 "$db" "$sql_bundle" 2>/dev/null || true
    fi
  fi
  return 0
}

try_sqlite_grant() {
  local rc=0
  sqlite_grant_db "$USER_TCC" 0 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$rc" -eq 2 ]]; then
    : # authorization denied — try system db / UI fallback
  elif [[ "$rc" -ne 0 ]]; then
    return 1
  fi

  rc=0
  sqlite_grant_db "$SYSTEM_TCC" 1 || rc=$?
  [[ "$rc" -eq 0 ]]
}

restart_tccd() {
  echo "$SUDO_PASS" | sudo -S launchctl stop com.apple.tccd 2>/dev/null || true
  sleep 0.3
}

try_ui_grant() {
  local script="$ROOT/Scripts/grant_accessibility_ui.applescript"
  local result err
  if [[ ! -f "$script" ]]; then
    echo "    Missing $script" >&2
    return 1
  fi
  echo "    TCC sqlite blocked — using System Settings UI automation…"
  err=$(osascript "$script" "$APP_PATH" "$SUDO_PASS" 2>&1) || {
    echo "$err" >&2
    return 1
  }
  result="$err"
  echo "    UI grant: $result"
  return 0
}

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
TS="$(date +%s)"
CSREQ_SQL="$(generate_csreq_sql "$APP_PATH")"

echo "==> Grant Accessibility → $APP_PATH"

if try_sqlite_grant; then
  restart_tccd
  echo "    OK (TCC database)"
  exit 0
fi

if try_ui_grant; then
  restart_tccd
  echo "    OK (System Settings)"
  exit 0
fi

cat >&2 <<EOF
    Failed to grant Accessibility automatically.

    macOS blocks direct TCC writes unless your terminal has Full Disk Access.
    Options:
      1) Re-run after granting Cursor/Terminal:
         System Settings → Privacy & Security → Full Disk Access
      2) Or grant MeoLaunch manually:
         System Settings → Privacy & Security → Accessibility
EOF
exit 1
