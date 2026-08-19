# 15-Plan — 触发角零延迟 + 低内存（自动化任务卡）

> **当前自动化队列真源**。用户说「继续自动化 / 全自动开发 / 继续」时：读下方 **Status**，执行第一个 `pending`，验收通过后标 `done`，**同一会话可连续执行下一卡**（本 Plan 允许连做，直到用户打断或全部 done）。  
> 设计说明：[15-hotcorner-zero-latency-memory.md](./15-hotcorner-zero-latency-memory.md)  
> 约束：`.cursor/rules/meolaunch-m0.mdc`、`.cursor/rules/taskbar-peek-invariants.mdc`、`.cursor/rules/hotcorner-memory-z-plan.mdc`

## Status

| ID | 状态 | 备注 |
|----|------|------|
| Z0 | done | 小时心跳 + HotCorner triggered→MLDebugLog；`overlayResidenceState` |
| Z1 | done | hide→warm park；15min/pressure→cold destroy；warm-reuse 日志 |
| Z2 | done | showCritical / showDeferredChrome；showImmediate 异步 deferred |
| Z3 | done | 热区仅 showCritical；下一 turn deferred + scheduleRescan |
| Z4 | done | 80pt 条带→census 1Hz + 停 focusPoll |
| Z5 | done | lastSeen≤256；terminate 清 lastSeen+soft |
| Z6 | done | soft 死 pid 体检；pressure 压 lastSeen 水位；接 Idle reclaim |
| Z7 | done | Overlay 可见：census 1Hz、poll 3s、停 focusPoll（AX 收紧延后） |
| Z8 | done | build + peek smoke 通过；本文收尾 |

## 执行协议

1. **一次一卡**；本 Plan 允许验收后**立即**开下一张 pending（全自动）。  
2. 每卡结束：`./Scripts/build.sh` 必须通过。  
3. 涉及 peek/minimize/多屏：跑 `./Scripts/taskbar_peek_smoke.sh`。  
4. 禁止 CocoaPods/SPM/第三方库；禁止改 `doc/00`–`doc/06` 产品规格（overview 索引除外）。  
5. Commit 仅在用户明确要求时创建；message 用简体中文。  
6. 改完把本文件 Status 对应行改为 `done`，备注写清关键 API/文件。

---

## 任务卡

### Z0 — 可观测心跳 + 热路径日志

- **输入**：15 §4 Phase C、§8  
- **改**：`MLIdleMemoryReclaimer` 或新建小助手；`AppDelegate` / `MLHotCornerMonitor`；必要时 `MLRunningAppsMonitor` 暴露计数  
- **做**：  
  1. 每小时（或可配置，默认 3600s）打一条：`phys_footprint`、`lastSeen.count`、`softState.count`、`axWatch.count`、overlay `warm|cold|visible`  
  2. `HotCorner triggered` 等热路径改用 `MLDebugLog`（默认关）  
- **验收**：`./Scripts/build.sh`；启动后日志无刷屏 HotCorner；可手动调短间隔验证心跳格式  
- **禁止**：改 show/hide 行为

### Z1 — Warm Overlay（hide 不默认 destroy）

- **输入**：15 §5  
- **改**：`MLOverlayController.m/.h`、`MLIdleMemoryReclaimer` / AppDelegate reclaim 回调  
- **做**：  
  1. `finishHide`：**不要**默认 `destroyOverlayWindow`；改为 `orderOut`、blur Inactive、取消 watchdog/monitors、可选延迟 icon purge（保留现有 30s generation）  
  2. 增加 `isOverlayWindowWarm`（或等价）  
  3. Idle 超时（建议默认 **15 分钟**）或 `underMemoryPressure` 时再 `destroyOverlayWindow`  
  4. 保留 `destroyOverlayWindow` 实现供 Cold 路径  
- **验收**：反复 show/hide 不重建窗（可打日志 `warm-reuse`）；Idle 超时或 pressure 后下次 show 走 ensureWindow；`build.sh`  
- **禁止**：改触发角逻辑；破坏 hide 后内存不失控（icon 仍须 purge/延迟 purge）

### Z2 — Show 两段式

- **输入**：15 §6  
- **改**：`MLOverlayController`、必要时 `AppDelegate`  
- **做**：  
  1. `showCritical`：ensureWindow（若需）、正确 screen frame、backdrop、`visible=YES`、`alpha=1`、`orderFrontRegardless`（及最低限度 makeKey）— **首帧可见**  
  2. `showDeferredChrome`：filter/reload、focusSearch、sanitize、watchdog、escape/outside monitors（若 critical 未装）  
  3. 菜单/热键可先 `showCritical` 再 deferred；fade 仍可用但热区走无 fade  
- **验收**：`build.sh`；从 Cold/Warm 打开 Overlay 功能完整（搜索、Esc、点击外部）  
- **禁止**：在 showCritical 里做全量 sanitize 循环或同步扫盘

### Z3 — 触发角关键路径瘦身

- **输入**：15 §6  
- **改**：`AppDelegate.m` `hotCornerMonitorDidTrigger:`  
- **做**：可见则 hide；否则 **只** `showCritical`，下一 turn `showDeferredChrome` + `scheduleRescan`；**不要**在回调里同步 `reloadWithAppIndex`（deferred 内用现成 index）  
- **验收**：`build.sh`；触发角打开仍显示应用；新装 app 仍可通过后续 rescan 出现  
- **禁止**：增加 delay_ms；在 tick 里做重活

### Z4 — 边缘条带降频

- **输入**：15 Phase A5  
- **改**：`MLHotCornerMonitor`（或 AppDelegate）、`MLRunningAppsMonitor` 提供 `setCensusBoosted:` / 暂停 focusPoll API  
- **做**：鼠标进入距配置角 **≤80pt** 条带时通知 Monitor 降频（census 最低、停 focusPoll）；离开恢复。Overlay 已 visible 时可保持降频  
- **验收**：`build.sh`；远离角落时行为与现网一致；靠近时无功能性回归（任务栏可略钝）  
- **禁止**：在 MouseMoved 里同步 `CGWindowList`

### Z5 — lastSeenWindows 硬顶

- **输入**：15 Phase B1  
- **改**：`MLRunningAppsMonitor(+SnapshotBuilder)`  
- **做**：硬顶（建议 **256**）；超出按最旧 `seenOrder` 淘汰（**跳过**当前 soft-hidden）；app terminate 时清该 pid 相关 lastSeen  
- **验收**：`build.sh`；`taskbar_peek_smoke.sh`；软隐藏窗不被误删导致芯片消失  
- **禁止**：去掉 soft 保护语义（仅加上限与 terminate 清理）

### Z6 — soft-state 体检 + Idle reclaim

- **输入**：15 Phase B2–B3  
- **改**：`MLWindowSoftState`、`MLIdleMemoryReclaimer`、AppDelegate `performReclaim`  
- **做**：  
  1. 定期/ idle reclaim：pid 不存在或 AX 失效则移除 soft record 并 CFRelease  
  2. Idle reclaim：调用 overlay warm→destroy（超时逻辑）、overlay `reclaimIdleCachesIfHidden`、pressure 时 prune lastSeen 至更低水位  
- **验收**：`build.sh`；soft-min 正常窗仍可还原；压力下 footprint 日志下降  
- **禁止**：清空仍有效的 soft-hidden

### Z7 — Overlay 可见降频 + AX 收紧（可选）

- **输入**：15 Phase B4、C1  
- **改**：`MLRunningAppsMonitor`、`MLAXAppObserverRegistry`、Overlay willShow/didHide 钩子  
- **做**：  
  1. Overlay visible：census/full poll 明显降频  
  2. （若时间允许）仅对曾出现 layer0 窗的 PID 装 AX observer；新窗再补装  
- **验收**：`build.sh`；`taskbar_peek_smoke.sh`；Overlay 打开时任务栏可不更新，关闭后恢复  
- **禁止**：破坏 Show Desktop peek 冻结逻辑

### Z8 — 回归与文档收尾

- **输入**：本 Plan 全部 done  
- **改**：`doc/15-*.md` Status；必要时 `doc/12-memory-perf.md` 加一句指向 15  
- **做**：全量 `build.sh` + `taskbar_peek_smoke.sh`；核对 Status 全 done；简述验收说明写入 15-plan 文末  
- **验收**：上述命令通过；无 pending  
- **禁止**：新功能

---

## 完成后写在这里

- **构建**：`./Scripts/build.sh` OK（arm64）；`./Scripts/taskbar_peek_smoke.sh` → 10 assertions OK（2026-08-18）。
- **已落地**：Warm Overlay、showCritical 热区路径、边缘/Overlay 降频、lastSeen 硬顶、soft 体检、小时心跳。
- **已知限制 / 延后**：Z7 可选「仅 layer0 PID 装 AX observer」未做（避免 peek 回归）；A6 CGEventTap 未做。
- **建议手动测**：触发角反复开合看 `warm-reuse`；跑 1–2 天看 Console `heartbeat` 是否还爬到 100MB+。
- **运行**：`./Scripts/run.sh`
