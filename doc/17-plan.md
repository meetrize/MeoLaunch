# 17-Plan — Slim Icon + Fast Show（自动化任务卡）

> **当前自动化队列真源**（优先于已全部 done 的 16-plan）。  
> 用户说「继续」「全自动开发」「按 17-plan」「Slim Icon」等 → 读下方 **Status**，执行第一个 `pending`。  
> 设计：[17-slim-icon-fast-show.md](./17-slim-icon-fast-show.md)

## Status

| ID | 状态 | 备注 |
|----|------|------|
| S0 | done | Slim 栅格化；禁多分辨率 copy/TIFF；磁盘键 `_*px.png` |
| S1 | done | Hot≤64；当前+邻页预取；L0 45s purge；L1 保留 |
| S2 | done | showCritical 同轮 prefetch；并发 10；合并重绘保持 |
| S3 | done | mem 日志带 `icons=`；弱机可关 prefs blur（已有） |

## 执行协议

1. **一次一卡**；验收后可立即下一张。  
2. 每卡结束：`./Scripts/build.sh` 必须通过。  
3. 禁止第三方库；不改 `doc/00`–`doc/06` 正文（overview 索引除外）。  
4. Commit 仅在用户明确要求时；message 用简体中文。  
5. 改完把 Status 标 `done` 并写备注。  
6. 遵守 peek 不变量：`.cursor/rules/taskbar-peek-invariants.mdc`。

---

## 任务卡

### S0 — Slim 栅格化（P0，必做）

- **改**：`Sources/System/MLIconCache.m`（及必要时 `.h`）
- **做**：
  1. `iconForFile` 后按 `ceil(pointSize * scale)` **栅格化成单层 bitmap**，再包成仅一 representation 的 `NSImage`（或等价）
  2. **禁止**对 Workspace 多分辨率图 `[copy]` 后直接进 cache
  3. 写盘：对该 bitmap 出 PNG；**删除**关键/写盘路径上的 `TIFFRepresentation` 绕路
  4. 加载槽位内用 `@autoreleasepool`，原图出池即释放
- **验收**：`./Scripts/build.sh`；打开 Overlay 后 footprint 应远低于 GB 级（目测 Active ≤120MB 量级）
- **禁止**：提高并发却不栅格化；合并 Taskbar cache

### S1 — 页级 Hot + 磁盘

- **改**：`MLIconCache`、`MLGridView`、`MLOverlayController`（purge 时机）
- **做**：
  1. Hot RAM 以当前页为主（可选邻页）；硬顶与页容量对齐（如 ≤64）
  2. 磁盘键使用 **pixel** 边长；空目录跳过探测（保持）
  3. hide：延迟清 L0（建议 30–60s）或压力清；**不清 L1**
- **验收**：`./Scripts/build.sh`；二次打开磁盘命中仍快

### S2 — 热区 / 翻页体感

- **改**：`MLOverlayController` `showCritical`、`MLGridView` prefetch
- **做**：
  1. 确认 orderFront 后同轮 prefetch 首页（已有则核验，勿拖回 deferred）
  2. 翻页立即 prefetch 目标页；合并重绘保持
  3. 并发度按一页需求微调（约 8–12），避免无益抬峰值
- **验收**：`./Scripts/build.sh`；热区 warm-reuse 仍可用

### S3 — 可选收尾

- **改**：backdrop / `MLLogMemory`（按需）
- **做**：弱机可降 blur；日志可带 icon 条目数或估算字节
- **验收**：`./Scripts/build.sh`
