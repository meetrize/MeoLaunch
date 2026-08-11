#!/usr/bin/env bash
# MeoLaunch — 一键安装并授权（放入 DMG，双击运行）
#
# 流程：
#   1. 弹出 macOS 管理员密码框（with administrator privileges）
#   2. 安装到 /Applications、清除隔离属性、adhoc 签名
#   3. 尝试写入辅助功能 TCC；失败则打开系统设置并提示手动勾选
#   4. 启动 MeoLaunch
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC=""
for candidate in \
  "$HERE/MeoLaunch.app" \
  "$HERE/../MeoLaunch.app" \
  "/Volumes/MeoLaunch/MeoLaunch.app"
do
  if [[ -d "$candidate" && -x "$candidate/Contents/MacOS/MeoLaunch" ]]; then
    SRC="$candidate"
    break
  fi
done

DEST="/Applications/MeoLaunch.app"

as_str() {
  # Escape for AppleScript double-quoted string
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

die_gui() {
  local msg
  msg="$(as_str "$1")"
  osascript -e "display dialog \"$msg\" buttons {\"好\"} default button 1 with icon stop with title \"MeoLaunch 安装\"" >/dev/null 2>&1 || true
  echo "ERROR: $1" >&2
  exit 1
}

info_gui() {
  local msg
  msg="$(as_str "$1")"
  osascript -e "display dialog \"$msg\" buttons {\"好\"} default button 1 with icon note with title \"MeoLaunch 安装\"" >/dev/null 2>&1 || true
}

if [[ -z "$SRC" ]]; then
  die_gui "未找到 MeoLaunch.app。

请先打开 MeoLaunch 安装盘，再双击本脚本。"
fi

set +e
osascript <<'EOF'
display dialog "将安装 MeoLaunch 到「应用程序」，并尝试授权「辅助功能」。

下一步会要求输入本机管理员密码（用于安装与清除隔离标记）。

本应用暂无 Apple Developer ID 签名；安装并授权后即可使用热角与 Taskbar。" buttons {"取消", "继续"} default button "继续" cancel button "取消" with title "MeoLaunch 一键安装并授权" with icon note
EOF
CONFIRM_RC=$?
set -e
if [[ "$CONFIRM_RC" -ne 0 ]]; then
  exit 0
fi

# --- privileged work (native password dialog) ---
PRIV="$(mktemp -t meolaunch_install.XXXXXX)"
STATUS_FILE="$(mktemp -t meolaunch_grant.XXXXXX)"
chmod 700 "$PRIV"
cat > "$PRIV" <<'PRIV_EOF'
#!/bin/bash
set -euo pipefail
SRC="$1"
DEST="$2"
STATUS_FILE="$3"

pkill -x MeoLaunch 2>/dev/null || true
sleep 0.3

STAGE="${DEST}.installing"
rm -rf "$STAGE" "$DEST"
mkdir -p "$(dirname "$DEST")"
if command -v ditto >/dev/null 2>&1; then
  ditto "$SRC" "$STAGE"
else
  cp -R "$SRC" "$STAGE"
fi
mv "$STAGE" "$DEST"

# Critical for unsigned downloads: drop Gatekeeper quarantine
xattr -cr "$DEST" 2>/dev/null || true
xattr -d com.apple.quarantine "$DEST" 2>/dev/null || true

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$DEST" 2>/dev/null || true
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
TS="$(date +%s)"

CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
USER_TCC=""
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
  CONSOLE_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  if [[ -n "${CONSOLE_HOME:-}" ]]; then
    USER_TCC="${CONSOLE_HOME}/Library/Application Support/com.apple.TCC/TCC.db"
  fi
fi
SYSTEM_TCC="/Library/Application Support/com.apple.TCC/TCC.db"

CSREQ_SQL="NULL"
if command -v codesign >/dev/null 2>&1 && command -v csreq >/dev/null 2>&1; then
  req=$(codesign -display -r- "$DEST" 2>&1 | awk -F ' => ' '/designated/{print $2}')
  if [[ -n "$req" ]]; then
    tmp="$(mktemp -t meolaunch_csreq.XXXXXX)"
    if echo "$req" | csreq -r- -b "$tmp" 2>/dev/null; then
      hex=$(xxd -p "$tmp" | tr -d '\n')
      [[ -n "$hex" ]] && CSREQ_SQL="X'${hex}'"
    fi
    rm -f "$tmp"
  fi
fi

insert_tcc() {
  local db="$1"
  local client="$2"
  local client_type="$3"
  [[ -f "$db" ]] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  sqlite3 "$db" "INSERT OR REPLACE INTO access(
    service,client,client_type,auth_value,auth_reason,auth_version,
    csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,
    indirect_object_code_identity,flags,last_modified
  ) VALUES(
    'kTCCServiceAccessibility','${client}',${client_type},2,4,1,
    ${CSREQ_SQL},NULL,0,'UNUSED',NULL,0,${TS}
  );" 2>/dev/null
}

GRANT=0
if [[ -n "$USER_TCC" ]]; then
  insert_tcc "$USER_TCC" "$DEST" 1 && GRANT=1 || true
  if [[ -n "$BUNDLE_ID" ]]; then
    insert_tcc "$USER_TCC" "$BUNDLE_ID" 0 && GRANT=1 || true
  fi
fi
insert_tcc "$SYSTEM_TCC" "$DEST" 1 && GRANT=1 || true
if [[ -n "$BUNDLE_ID" ]]; then
  insert_tcc "$SYSTEM_TCC" "$BUNDLE_ID" 0 && GRANT=1 || true
fi

launchctl kickstart -k system/com.apple.tccd 2>/dev/null || \
  launchctl stop com.apple.tccd 2>/dev/null || true

printf '%s' "$GRANT" > "$STATUS_FILE"
chmod 644 "$STATUS_FILE" 2>/dev/null || true
exit 0
PRIV_EOF
chmod +x "$PRIV"

# AppleScript: run privileged installer (shows system password sheet)
SRC_AS="$(as_str "$SRC")"
DEST_AS="$(as_str "$DEST")"
PRIV_AS="$(as_str "$PRIV")"
STATUS_AS="$(as_str "$STATUS_FILE")"

set +e
osascript <<EOF
do shell script "bash \"${PRIV_AS}\" \"${SRC_AS}\" \"${DEST_AS}\" \"${STATUS_AS}\"" with administrator privileges
EOF
RC=$?
set -e
rm -f "$PRIV"

if [[ "$RC" -ne 0 ]]; then
  rm -f "$STATUS_FILE"
  die_gui "安装已取消或失败（未输入正确的管理员密码，或权限不足）。"
fi

if [[ ! -d "$DEST" ]]; then
  rm -f "$STATUS_FILE"
  die_gui "安装失败：未找到 $DEST"
fi

GRANT_STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo 0)"
rm -f "$STATUS_FILE"

if [[ "$GRANT_STATUS" != "1" ]]; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null \
    || open "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility" 2>/dev/null \
    || true
  info_gui "已安装到「应用程序」。

自动写入「辅助功能」可能被系统拦截（常见于较新的 macOS）。

请在已打开的「隐私与安全性 → 辅助功能」中勾选 MeoLaunch，然后点「好」启动应用。"
else
  info_gui "安装完成，辅助功能已尝试授权。

若热角仍无效，请到：系统设置 → 隐私与安全性 → 辅助功能，确认已勾选 MeoLaunch。"
fi

open "$DEST" 2>/dev/null || true

echo "Installed: $DEST (grant=$GRANT_STATUS)"
# Keep Terminal window readable briefly when opened as .command
sleep 1
