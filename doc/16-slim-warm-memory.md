# 16 — Slim Warm Memory（hide 卸 blur + 更快 reclaim）

> 状态：**M1.2 / M1.3 / M1.1 已落地**（见 [16-plan.md](./16-plan.md)）  
> 日期：2026-08-19  
> 关联：[15-hotcorner-zero-latency-memory.md](./15-hotcorner-zero-latency-memory.md)、[12-memory-perf.md](./12-memory-perf.md)

## 0. 问题

Overlay hide 后 `phys_footprint` 长期停在 100MB+，回不到 ~40MB Idle。  
Z1 Warm park 保留全屏窗树（含 `NSVisualEffectView`），仅把 blur 设为 `Inactive`，材质与 backing 仍占内存；图标 30s 才 purge；Warm→Cold 默认 15 分钟过长。

## 1. 目标

| 指标 | 目标 |
|------|------|
| hide 后尽快回落 | 卸 blur + 5s icon purge |
| Warm→Cold | Idle **3 分钟**或 memory pressure |
| 热区 | 仍 `warm-reuse`（保留 `NSWindow`）；`showCritical` 再挂 blur |
| 回归 | soft-min / peek / 多屏不破 |

## 2. 方案（M1.2 → M1.3 → M1.1）

| ID | 项 | 做法 |
|----|----|------|
| M1.2 | hide 卸 VisualEffect | `stripWarmBlurView`；`ensureBlurViewAttached` 在 showCritical |
| M1.3 | 图标更快清 | delayed purge **5s** |
| M1.1 | Warm 超时 | **3 分钟** cold destroy |

## 3. 状态机

```
Hide → orderOut + strip blur + filter/folder clear + 5s icon purge
     → Warm（NSWindow + 轻量 chrome，无 VisualEffect）
Idle ≥3min / pressure → destroyOverlayWindow（Cold）
showCritical + window≠nil → warm-reuse + ensureBlur + orderFront
```

## 4. 禁止

- hide 后默认整窗 destroy（毁掉热区）
- 合并 Overlay / Taskbar icon cache
- 砍 soft-min / peek
