# P3 可执行 Plan — 共享 census + Peek 测试 harness

> 状态：✅ 核心完成（日志宏统一延后）  
> 源自 code review Phase 3

## 范围

| ID | 项 | 状态 | 做法 |
|----|----|------|------|
| P3-1 | 共享 `MLWindowCensus` | ✅ | on-screen / all 列表由 Monitor census tick 刷新；Taskbar `+Bars/+Peek/+Items`、SnapshotBuilder、rememberBounds 走缓存 |
| P3-2 | Overlay 文件夹 LRU | ✅ | P1 已落地（`MLIconCache` folder composite） |
| P3-3 | Peek 不变量测试 harness | ✅ | `Tools/taskbar_peek_smoke.m` + `Scripts/taskbar_peek_smoke.sh`（10 项 headless）；`Scripts/taskbar_peek_checklist.sh`（§7 七项手动） |
| P3-4 | 统一 `MLLogMemory` / `MLDebugLog` | ⏭ 延后 | 低 ROI；现有 `#ifdef ML_ENABLE_DEBUG` 分散宏可后续收敛 |

## 验收

- [x] `./Scripts/build.sh` 0 error / 0 warning
- [x] `./Scripts/taskbar_peek_smoke.sh` → `taskbar_peek_smoke OK (10 assertions)`
- [ ] 改 peek / minimize / 多屏逻辑后跑 `./Scripts/taskbar_peek_checklist.sh`（需 GUI）

## 仍直接调 `CGWindowListCopyWindowInfo` 的位置

- `MLWindowCensus.m`（唯一批量采集点）
- 单窗查询：`MLTaskbarController+WindowActions`、`MLCGSAlpha`
