# 16-Plan — Slim Warm Memory（自动化任务卡）

> **当前自动化队列真源**（优先于已全部 done 的 15-plan）。  
> 用户说「继续」「全自动开发」「按 16-plan」等 → 读下方 **Status**，执行第一个 `pending`。  
> 设计：[16-slim-warm-memory.md](./16-slim-warm-memory.md)

## Status

| ID | 状态 | 备注 |
|----|------|------|
| M1.2 | done | `stripWarmBlurView` / `ensureBlurViewAttached`；finishHide strip；showCritical ensure |
| M1.3 | done | delayed icon purge 5s；日志 `5s idle` |
| M1.1 | done | `kMLOverlayWarmIdleDestroySeconds = 3min` |

## 执行协议

1. **一次一卡**；验收后可立即下一张。  
2. 每卡结束：`./Scripts/build.sh` 必须通过。  
3. 禁止第三方库；不改 `doc/00`–`doc/06` 正文（overview 索引除外）。  
4. Commit 仅在用户明确要求时；message 用简体中文。  
5. 改完把 Status 标 `done` 并写备注。

---

## 任务卡

### M1.2 — hide 卸 VisualEffect

- **改**：`Sources/UI/MLOverlayController.m`
- **做**：
  1. `-stripWarmBlurView`：Inactive → remove → nil；`MLLogMemory(@"hide-strip-blur")`
  2. `-ensureBlurViewAttached`：需要 blur 且 blurView==nil 时重建并插入 contentView 最底层
  3. `finishHide` 调用 strip；`showCritical` 在 ensureWindow 后、applyBackdrop/orderFront 前 ensureBlur
- **验收**：`./Scripts/build.sh`；warm-reuse 仍可用
- **禁止**：hide 默认 destroy 整窗

### M1.3 — 图标 5s purge

- **改**：`scheduleDelayedIconPurge`
- **做**：延迟 **5.0** 秒；日志 `5s idle`
- **验收**：`./Scripts/build.sh`

### M1.1 — Warm 超时 3 分钟

- **改**：`kMLOverlayWarmIdleDestroySeconds = 3.0 * 60.0`
- **验收**：`./Scripts/build.sh`；注释与常量一致
