# P2 可执行 Plan — 结构升级

> 状态：✅ 已完成（整段 snapshot 后台明确延后）  
> 源自 [12-memory-perf.md](./12-memory-perf.md) §4 P2

## 范围

| ID | 项 | 状态 | 做法 |
|----|----|------|------|
| P2-1 | 每 PID 单次 AX windows | ✅ | 一次 full poll 内缓存 `kAXWindowsAttribute`，供 title enrich / ghost / minimized 复用 |
| P2-2 | AppIndex 后台扫描 | ✅ | `rescanApps`：后台 `ml_app_index_scan` → 主线程 swap + layout sync + overlay reload；generation 丢弃过期结果 |
| P2-3 | Prefs / config | ✅ | `taskbar.enabled`、`taskbar.window_poll_seconds`、`ui.overlay_icon_cache_max`；热区沿用已有开关 |
| P2-4 | 接线 | ✅ | AppDelegate 应用配置；Monitor `applyWindowPollInterval:`；Overlay `setIconCacheMaxEntries:`；taskbar start/stop |

## 明确延后（风险高）

- Monitor **整段 snapshot 移后台**（CG + softState 交叉多）  
  本轮用 AX 批处理降低主线程 AX 次数，效果接近「减负」目标。

## 验收

- [x] build 通过  
- [x] Prefs 改 poll / 关任务栏 / 图标上限即时生效  
- [x] 重扫应用时 UI 不长时间卡顿  
