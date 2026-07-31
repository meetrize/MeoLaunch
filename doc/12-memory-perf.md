# 12 — 内存与响应优化建议（全项目扫描）

> 状态：建议稿；**P0 / P1 已实施**（见 [12-p0-plan.md](./12-p0-plan.md)、[12-p1-plan.md](./12-p1-plan.md)）。基于 2026-07-31 对 `Sources/` + `doc/` 的架构扫描。  
> 关联预算：[02-architecture.md](./02-architecture.md) §6、[10-taskbar.md](./10-taskbar.md) §7。

## 0. 结论先看

| 维度 | 现状判断 | 还有没有优化空间 |
|------|----------|------------------|
| **Idle 内存** | 架构已偏省：Overlay hide 清图标、任务栏独立小 cache、C 侧 index 瘦 | **有，但幅度有限**（约再抠 2–8 MB + 降常驻 CPU） |
| **Active 内存** | 大头是 Overlay 图标 LRU128×128 + 全屏模糊窗 | **有**（预取策略、文件夹合成缓存、hide 策略） |
| **响应速度** | 瓶颈主要在 **主线程 CGWindowList + AX 轮询**，不是图标本身 | **空间最大**（共享 census、降频、搜索防抖、点击减同步 AX） |

**不建议**：为省几 MB 牺牲任务栏正确性（soft-min、Show Desktop 冻结）或砍掉辅助功能能力。  
**优先顺序**：先降主线程抖动（体感）→ 再压 Active 峰值 → 最后抠 Idle 常数。

---

## 1. 架构层：当前内存模型

```
Idle（常驻）
  ├─ AppIndex (C)           ~0.5–1 MB
  ├─ Status Item / HotCorner / HotKey
  ├─ Taskbar × N 屏窗口     ≤1.5 MB 量级预算
  ├─ MLTaskbarIconCache     ≤48 × 32pt，常驻
  └─ MLRunningAppsMonitor   1s 全量 poll + 12Hz census + 每 PID AXObserver

Active（Overlay 打开）
  ├─ 全屏 NSWindow + VisualEffect 模糊
  ├─ MLIconCache            ≤128 × 128pt（hide 时 purge）
  └─ Grid 预取当前±1 页
```

设计原则仍然正确：**单进程、Overlay 与 Taskbar 图标隔离、hide 清大 cache**。继续优化应「减重复采集 / 减主线程」，而不是再拆进程。

---

## 2. 内存热点与建议

### 2.1 高影响

| 项 | 位置 | 问题 | 建议 | 预期 |
|----|------|------|------|------|
| Overlay 图标 | `MLIconCache` 128 条 × 128pt | Active 峰值主因 | ① 预取改为「仅当前页」或「当前+方向页」；② hide 时 **延迟 purge**（如 30s 无再开则清）或 memory pressure 再清；③ 可配置 `max_entries` / 图标 pt | Active −几～十几 MB；二次打开更快 |
| 文件夹合成图 | `MLGridView` `folderCompositeImageAtVisible:` | **每次 draw 新建 NSImage** | 按 folder-id + size 做小 LRU（≤16） | 降 Active 抖动与 CPU |
| 多份 CGWindowList | Monitor + Taskbar visibility | 同一秒内多次全桌面列表 | **共享 WindowCensus**（见 §3） | 主线程与瞬时分配都降 |

### 2.2 中影响

| 项 | 位置 | 建议 |
|----|------|------|
| `lastSeenWindows` | `MLRunningAppsMonitor` | 加软上限或按 PID 裁剪；确认 prune 覆盖「长期最小化又关窗」 |
| `axWatchByPid` | 每 regular app 一个 AXObserver | 只对「曾出现过 layer0 窗」的 PID 装观察者；退出清理已 OK |
| Overlay 窗常驻 | `orderOut` 不销毁 | 保持（再建全屏窗更贵）；可选「长时间 Idle 释放 blur 子树」 |
| `filterIndices` | Overlay | 容量=appCount 且不缩；可在 hide 时 `free` 缩到 0 |
| `MLIconCache.inflight` | purge 不清 | purge 时清空 inflight / generation，避免 hide 后写回 |
| `displayNameCache` | Taskbar stop 不清 | stop 时 `removeAllObjects` |
| 任务栏深拷贝冻结 | Show Desktop | 已可接受；避免额外持有第三份 pending |

### 2.3 低影响 / 已够好

- Pin JSON、标题 ≤40 字、每屏 ≤24 窗芯片  
- Taskbar 32pt LRU48（勿与 Overlay 合并）  
- SoftState 按 windowID + 验证后 clear  

### 2.4 功能取舍（若仍要压 Idle）

| 功能 | 说明 |
|------|------|
| 可关任务栏 | Prefs 开关 → `taskbar stop`（已有能力链）可省 3–4 MB + 全部 window poll |
| 降低 poll | `window_poll_seconds` 提到 1.5–2.0（标题刷新变慢） |
| 关热区轮询 | 仅快捷键打开 Overlay 时可停 60Hz 热区 |
| 显示桌面 peek | 逻辑重；可关 peek 只保留 fullscreen hide（体验退步） |

---

## 3. 响应速度：主瓶颈与建议

### 3.1 主线程负担（最大）

当前稳态大致：

- Census **~12 Hz** × `CGWindowList`  
- 全量 poll **1 Hz** × 双列表 + 多轮 AX（标题 / ghost / minimized）  
- Taskbar visibility **0.2–0.45 s** × 再扫 CG + AXFullScreen  
- `rebuildItemsForBar` **每屏一次** `frontmostTrackedWindowID`（又一次 CG）

**建议 A — 共享 WindowCensus（高 ROI）**

1. 后台或低频主线程：每 100–250ms 采一次「瘦列表」（wid/pid/bounds/layer/alpha）。  
2. Monitor 全量 poll、Taskbar fullscreen/peek、frontmost 查询 **读缓存**，禁止各写各的 `CGWindowListCopyWindowInfo`。  
3. AX 标题 enrich 仍可 1s 一次，但每 PID **只 Copy windows 一次**，派生 title/minimized/ghost。

**建议 B — Census 自适应**

- Idle：4 Hz；有 AX 结构事件 / 指纹变：短时 12 Hz。  
- 省电 + 减主线程。

**建议 C — 轮询移出主线程（中长期）**

- Snapshot 在串行队列构建，immutable 回主线程。  
- AXObserver 仍挂主 runloop；只把「列表拼装」挪走。  
- 风险：时序；需单测 Show Desktop / soft-min。

### 3.2 Overlay 交互

| 项 | 建议 |
|----|------|
| 搜索每键 `reloadData` | **50–80ms 防抖** |
| `drawRect` 同步 `iconForFile` | 只画占位，等 async cache |
| hide 全量 purge | 见 §2.1 延迟 purge → 二次打开更快 |
| `ml_app_index_scan` 在主线程 | 后台扫 → 主线程 swap index |

### 3.3 任务栏交互

| 项 | 建议 |
|----|------|
| 普通开窗也等 0.32s commit | **结构变化立即 commit**；仅 desktop-reveal / 大跌幅走 debounce |
| 右键菜单读 AX 全屏 | 菜单先弹出；全屏项默认可用，点时再读，或异步刷新 title |
| 点击 `topmostUserWindowID` + `copyAXWindow` | 短时缓存 last topmost wid；AX 按 wid 映射表命中 |
| soft restore 6 次重试 | 成功即 cancel 剩余 `dispatch_after` |
| 热区 60Hz | 改为 20–30Hz，或仅靠近边缘时加密 |

### 3.4 日志

热路径大量 `NSLog`（soft-state、minimize、freeze）会拖主线程。Release 用宏关掉或降到 debug。

---

## 4. 推荐实施分期

### P0 — 体感与 CPU（1–2 迭代）✅ 已完成

1. Overlay **搜索防抖**（60ms）  
2. Grid **禁止 draw 同步加载图标**  
3. **rebuild 共享 frontmost** + topmost **80ms TTL**  
4. Census **Idle 4Hz / 变化后 2s 内 12Hz**  
5. Taskbar：**非 reveal 立即 commit**；reveal 仍 debounce  
6. 热路径 **`MLDebugLog`（默认关闭）**；热区 **25Hz**

### P1 — Active 内存与二次打开 ✅ 已完成

1. 文件夹合成图 LRU（≤16）  
2. Overlay hide **延迟 30s purge**  
3. Prefetch **仅当前页**  
4. `inflight` / `filterIndices` / `displayNameCache` 清理缺口

### P2 — 结构升级 ✅ 已完成（整段 snapshot 后台延后）

1. ~~Monitor snapshot 后台组装~~ → **延后**（见 [12-p2-plan.md](./12-p2-plan.md)）  
2. 每 PID 单次 AX windows 多用途（full poll 内缓存）  
3. AppIndex 后台扫描  
4. Prefs：`taskbar.enabled`、`window_poll_seconds`、`overlay_icon_cache_max`（热区沿用已有）

### 不做 / 慎做

- 合并 Overlay 与 Taskbar 图标 cache（违背隔离与 purge 语义）  
- 为省内存去掉 soft-min / peek（回归体验）  
- 缩略图预览（内存与复杂度双升）  
- 拆 helper 进程（常驻可能反而升）

---

## 5. 度量方法（改前改后对比）

1. Instruments：**Allocations** + **Time Profiler**（主线程 `CGWindowList` / `AXUIElement`）  
2. 已有 `MLLogMemory`（phys_footprint）：Idle / Overlay show / hide+1s / hide+30s  
3. 场景脚本：  
   - Idle 5 分钟  
   - 开 Overlay 翻 5 页再关  
   - Show Desktop 进出  
   - 连续开 10 个窗看任务栏延迟  

目标参考（可调）：

| 场景 | 现文档目标 | 优化后期望（方向） |
|------|------------|--------------------|
| Idle + taskbar | ≤28–30 MB | 再降 1–3 MB + CPU 明显降 |
| Overlay Active | ≤60 MB | 峰值更稳，二次打开更快 |
| 任务栏开窗可见 | — | 从 ~320ms 级降到近即时（非 peek） |
| 搜索打字 | — | 无每键整页卡顿 |

---

## 6. 与功能清单的对照

| 功能 | 内存 | 响应 | 优化方向 |
|------|------|------|----------|
| Launchpad Overlay | Active 大 | 搜索/图标 | 防抖、预取、延迟 purge |
| 任务栏 | Idle 中等 | poll/rebuild | 共享 census、分层 commit |
| Soft minimize | 低（AX retain） | 点击/还原重试 | 缓存 AX、取消多余 retry |
| Show Desktop peek | 低（冻结拷贝） | 检测贵 | 用共享 census，勿重复 list |
| 全屏藏栏 | 低 | 0.2s 定时器 | 指纹未变则跳过 |
| 热区 | 极低 | 60Hz | 降频 |
| Prefs / Pin / Layout | 极低 | 已 debounce | 保持 |

---

## 7. 一句话

**还能优化，而且值得做——但下一刀应优先砍「主线程重复扫窗」，而不是再砍功能。**  
内存上 Active 峰值与 Overlay 图标策略还有空间；Idle 已接近架构下限，继续抠的收益会递减。
