# 13 — 菜单栏系统剩余内存百分比（技术方案）

> 状态：**已实现**（2026-07-31）  
> 关联：[06-config-schema.md](./06-config-schema.md)、[12-memory-perf.md](./12-memory-perf.md)

---

## 0. 结论

| 项 | 规格 |
|----|------|
| 位置 | 系统菜单栏，MeoLaunch 图标旁独立文字 StatusItem |
| 显示 | 整机**剩余**内存整数百分比，如 `35%`（`free/physical`） |
| 刷新 | 默认 2s（1–5s） |
| Prefs | `菜单栏显示剩余内存 %`；默认关闭 |
| 关闭 | 停 timer + `removeStatusItem`（省 KB 级 + 唤醒） |

---

## 1. 实现落点

| 文件 | 职责 |
|------|------|
| `Sources/System/MLMemoryStatusController.*` | 采样 `HOST_VM_INFO64`、格式化 `N%`、启停 StatusItem |
| `MLConfigStore` | `menubar.memory_free.enabled` / `interval_seconds` |
| `MLPrefsWindow` | checkbox |
| `AppDelegate` | `applyMemoryStatusFromConfig` |
| `MLStrings` | Prefs + tooltip |

口径：`used ≈ (active + wired + compressor) * page`；`free% = round(100 * (physical-used) / physical)`。  
Tooltip：`剩余内存：35% · 12.4 GB`。

---

## 2. 验收

- [x] build 通过  
- [ ] Prefs 开启后菜单栏出现 `N%`，约 2s 更新  
- [ ] 关闭后文字项消失  
- [ ] 不影响 Overlay / Taskbar peek  
