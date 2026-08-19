# 15 — 触发角零延迟 + 长时间低内存

> 状态：**Z0–Z8 已落地**（见 [15-plan.md](./15-plan.md)）  
> 日期：2026-08-18  
> 关联：[12-memory-perf.md](./12-memory-perf.md)、[02-architecture.md](./02-architecture.md) §6

## 0. 问题

| 现象 | 观察 |
|------|------|
| 内存爬升 | 运行数天后 `phys_footprint` ≈ **170MB**（远超 Idle ≤25–30MB 目标） |
| 触发角变钝 | 移入触发角后 Overlay 弹出不够快，长时间运行后更明显 |

## 1. 根因（架构级）

### 1.1 速度与内存的错误交换

当前 `MLOverlayController` 在 hide 后 **`destroyOverlayWindow`**（拆全屏窗 + VisualEffect + grid），下次触发角走 `showImmediate` → `ensureWindow` **全量重建**。

- 意图：压 Idle 内存  
- 实际：挡不住任务栏/AX 常驻上涨；每次弹出支付昂贵冷启动；堆反复建毁加剧 **phys_footprint 碎片**

### 1.2 触发角关键路径过重

```
MouseMoved → HotCorner.tick → hotCornerMonitorDidTrigger
  → scheduleRescan + reloadWithAppIndex + showImmediate
      → ensureWindow（可能重建）+ filter + focus + sanitize + watchdog
```

零延迟死敌不是 `delay_ms`（默认已 0），而是 **重建窗 + 主线程被 census/poll 占满 + 同步 reload/sanitize**。

### 1.3 常驻内存真凶

| 来源 | 说明 |
|------|------|
| Taskbar Monitor | 1s poll + census + 每 app `AXObserver` + soft-min 持有 AX |
| `lastSeenWindows` | soft-hidden **永不 prune**，可只增不减 |
| Idle reclaim | 每 5 分钟只清 icon/displayName，**不停 poll、不清 lastSeen** |
| hide 拆窗 | 对 170MB 无效，反而碎片化 |

## 2. 目标

| 指标 | 目标 |
|------|------|
| 触发角 → 首像素 | **≤ 16ms（1 帧）**；体感近零延迟 |
| Idle（开任务栏） | **≤ 40MB** 稳态，72h 无单调爬到 100+ |
| Idle（关任务栏） | **≤ 25MB** |
| Active Overlay | **≤ 60MB**（与既有预算对齐） |
| 回归 | peek / soft-min / 多屏不变量不破（见 taskbar-peek-invariants） |

## 3. 原则

1. **弹出关键路径 ≤ 1 帧**：只做 `orderFront` / `alpha=1`，其余延后。  
2. **Warm Overlay，冷 Taskbar 缓存**：速度靠预热窗；内存靠裁剪 lastSeen/soft + 延迟拆窗。  
3. **主线程给热区让路**：靠近触发角时降频非必要 poll。  
4. **不做**：砍 soft-min/peek；合并 Overlay/Taskbar 图标 cache；拆 helper 进程。

## 4. 方案分期

### Phase A — 零延迟弹出

| ID | 项 | 做法 |
|----|----|------|
| A1 | Warm window | hide → `orderOut` + blur Inactive + 清/延迟清图标；**默认不 destroy**。Idle≥N 分钟或 memory pressure 才 destroy。 |
| A2 | Show 两段式 | `showCritical`：首帧可见；`showDeferred`：下一 turn focus/filter/sanitize。 |
| A3 | 触发角瘦身 | 触发时不 `scheduleRescan`/`reload`；用现成 index 先闪出。 |
| A4 | 预热 | 启动或首次 hide 后保持窗在正确 screen、`orderOut`。 |
| A5 | 边缘让路 | 鼠标进边缘条带时 census/focusPoll 降频；离开恢复。 |
| A6 | （可选）CGEventTap | NSEvent 仍钝时再上；本 Plan 默认不做。 |

### Phase B — 长时间低内存

| ID | 项 | 做法 |
|----|----|------|
| B1 | `lastSeenWindows` 硬顶 | 上限（如 256）；进程退出必清。 |
| B2 | soft-state 体检 | 定期验证 pid/AX；失效释放。 |
| B3 | Idle reclaim 升级 | 含 warm→destroy、pressure 时强制 prune。 |
| B4 | AX 观察者收紧 | 仅对曾有 layer0 窗的 PID 装 observer。 |
| B5 | 图标预算 | 保持/收紧 max_entries；prefetch 仅当前页。 |
| B6 | Prefs 省电 | poll 间隔、可关 blur（可选 UI，可后置）。 |

### Phase C — 可观测

| ID | 项 |
|----|----|
| C1 | Overlay 可见时降频 census/full poll |
| C2 | 热路径 `NSLog` → `MLDebugLog` |
| C3 | 小时级 log：footprint / lastSeen / soft / axWatch / warm\|cold |

## 5. Warm / Cold 状态机

```
Hide → orderOut + Inactive blur + icon purge(或 30s 延迟)
     → 保持 window（Warm）
Idle 超时 / memory pressure → destroyOverlayWindow（Cold）
Trigger + Warm → showCritical（≤1 帧）
Trigger + Cold → ensureWindow 一次，再 showCritical
```

## 6. 关键路径目标形态

```objc
- (void)hotCornerMonitorDidTrigger:(MLHotCornerMonitor *)m {
    if ([self.overlay isVisible]) { [self.overlay hide]; return; }
    [self.overlay showCritical];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.overlay showDeferredChrome];
        [self scheduleRescan]; /* 不挡首帧 */
    });
}
```

## 7. 与既有工作的关系

- P0–P3（[12-memory-perf.md](./12-memory-perf.md)）保留：防抖、共享 census、延迟 purge、后台扫盘等。  
- 本方案补上：**Warm 窗**、**触发角关键路径**、**lastSeen/soft 硬顶**、**可观测**。  
- 产品文档 00–06 不改；本文件 + [15-plan.md](./15-plan.md) 为自动化真源。

## 8. 度量

1. Console：`[MeoLaunch] mem … phys_footprint=`  
2. 小时心跳：`lastSeen` / `soft` / `axWatch` / warm|cold  
3. Instruments：Allocations（72h）+ Time Profiler（触发瞬间）  
4. 构建：`./Scripts/build.sh`；peek：`./Scripts/taskbar_peek_smoke.sh`
