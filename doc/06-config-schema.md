# 06 — 配置 Schema

## 1. 路径

```
~/Library/Application Support/meoLaunch/config.json
```

若目录不存在则创建，并写入默认配置。

可选并行：

```
~/Library/Preferences/com.meetrice.meolaunch.plist
```

**MVP 只用 JSON 一处**，降低复杂度。

## 2. 默认配置

```json
{
  "version": 1,
  "grid": {
    "cols": 7,
    "rows": 5,
    "padding": 48,
    "spacing": 28,
    "icon_size": 0,
    "show_labels": true
  },
  "hot_corner": {
    "enabled": true,
    "corner": "top_left",
    "size_pt": 4,
    "delay_ms": 0,
    "action": "show"
  },
  "hotkey": {
    "enabled": true,
    "key_code": 49,
    "modifiers": ["option"]
  },
  "search": {
    "autofocus": true,
    "pinyin": false
  },
  "paging": {
    "wheel_threshold": 8,
    "animate": true
  },
  "scan": {
    "roots": [
      "/Applications",
      "/System/Applications",
      "~/Applications"
    ],
    "include_hidden": false,
    "refresh_seconds": 60
  },
  "ui": {
    "blur": true,
    "fade_ms": 100,
    "menubar_icon": true,
    "lsuielement": true,
    "overlay_icon_cache_max": 128
  },
  "taskbar": {
    "enabled": true,
    "window_poll_seconds": 1.0
  },
  "menubar": {
    "memory_free": {
      "enabled": false,
      "interval_seconds": 2.0
    }
  },
  "launch_at_login": false
}
```

## 3. 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `version` | int | schema 版本，便于迁移 |
| `grid.cols` / `rows` | int | 网格；默认 7×5 |
| `grid.icon_size` | number | `0` = 按窗口自适应 |
| `hot_corner.corner` | string | `top_left` / `top_right` / `bottom_left` / `bottom_right` / `off` |
| `hot_corner.size_pt` | number | 热区正方形边长 |
| `hot_corner.delay_ms` | int | 停留多久才触发 |
| `hot_corner.action` | string | `show` \| `toggle` |
| `hotkey.key_code` | int | Carbon/虚拟键码；49 ≈ Space |
| `hotkey.modifiers` | string[] | `command` `option` `control` `shift` |
| `paging.wheel_threshold` | number | 滚轮累积阈值 |
| `scan.roots` | string[] | `~` 展开为 home |
| `ui.lsuielement` | bool | 不进 Dock（改后需重启生效） |
| `ui.overlay_icon_cache_max` | int | Overlay 图标 LRU 上限（32–256，默认 128） |
| `taskbar.enabled` | bool | 是否显示任务栏（默认 true） |
| `taskbar.window_poll_seconds` | number | 窗口轮询间隔秒（0.5–5.0，默认 1.0） |
| `menubar.memory_free.enabled` | bool | 菜单栏显示整机**剩余**内存 %（默认 false） |
| `menubar.memory_free.interval_seconds` | number | 采样间隔秒（1.0–5.0，默认 2.0） |

## 4. 读写策略

- 启动：读盘 → 校验 → 缺字段补默认 → 若曾损坏则备份为 `config.json.bak` 并重建
- 设置 UI：防抖 300ms 写盘
- 不在主线程做大文件 IO（配置很小，可主线程；保持简单）

## 5. 迁移

```
version < 当前 → 按字段映射升级 → 写回新 version
```

未知字段保留（前向兼容）或丢弃（MVP 可丢弃）。
