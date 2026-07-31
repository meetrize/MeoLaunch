# P0 可执行 Plan — 内存/响应（源自 doc/12-memory-perf.md §4）

> 状态：**已完成**（2026-07-31）  
> 范围：仅 P0；P1/P2 见 [12-memory-perf.md](./12-memory-perf.md)

## 已落地

| ID | 项 | 做法 |
|----|----|------|
| P0-1 | Overlay 搜索防抖 | `MLOverlayController` 60ms timer |
| P0-2 | Grid 禁同步图标 | `MLGridView` draw/folder/drag 只走 cache + `requestIconForPath` |
| P0-3 | 共享 frontmost | rebuild 一次算 `rebuildPassFrontmostWID`；点击 topmost **80ms TTL** |
| P0-4 | Census 自适应 | Idle **4Hz**；token 变后 **2s 内 12Hz** |
| P0-5 | 分层 commit | `looksLikeDesktopReveal` 才 debounce；否则立即 paint |
| P0-6 | 热路径日志 | `MLDebugLog.h`（默认关；`-DML_ENABLE_DEBUG_LOG=1` 打开） |
| P0-7 | 热区降频 | `MLHotCornerMonitor` **25Hz** |

## 验收

- `./Scripts/build.sh` 通过  
- Overlay 打字更顺；开窗任务栏更即时；Show Desktop 仍应不闪  

## 非目标（下轮 P1）

延迟 purge、文件夹合成 LRU、Monitor 整段移后台、完整共享 WindowCensus 模块
