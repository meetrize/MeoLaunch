# 17 — Slim Icon + Fast Show（控 Active 内存 + 热区首屏/翻页）

> 状态：**S0–S3 已落地**（见 [17-plan.md](./17-plan.md)）  
> 日期：2026-09-03  
> 关联：[16-slim-warm-memory.md](./16-slim-warm-memory.md)、[15-hotcorner-zero-latency-memory.md](./15-hotcorner-zero-latency-memory.md)、[12-memory-perf.md](./12-memory-perf.md)

## 0. 现象

| 指标 | 现状（用户实测） | 目标 |
|------|------------------|------|
| Idle | ~40 MB | 保持 ≤45 MB |
| 触发 Overlay 后 | **~1.25 GB** | Active **≤120 MB**（理想 ≤90） |
| 热区首次弹出 | 明显慢 | 窗 ≤1 帧；首页图标尽快出齐 |
| 翻页（含首次） | 图标慢慢冒 | 当前页优先并发填满 |

Idle 已基本达标；**Active 暴涨与首开慢是同一根因**，不是「再多清几次 RAM」能解决的。

## 1. 根因（代码级）

当前 `MLIconCache` 关键路径：

```text
iconForFile → setSize(格子 pt) → [icon copy] → 整份 NSImage 进 RAM
                                         └→ TIFFRepresentation → PNG 写盘
```

问题：

1. **`setSize` 不裁剪表示**  
   Workspace 返回的 `NSImage` 常带 256 / 512 / **1024** 多套 bitmap。`setSize` 只改「首选绘制尺寸」，大图仍在。
2. **`[icon copy]` 拷贝全部 representation**  
   一页 35 个 × 多套大图，再乘并发 12 与临时对象 → 瞬时堆轻松上 GB。
3. **`TIFFRepresentation` 写盘**  
   把多分辨率展开成巨大 TIFF，再转 PNG；与加载并发叠在一起，放大峰值。
4. **全屏 `NSVisualEffectView`**  
   高分屏 backing 可占几十～百余 MB，是 Active 基线，但**解释不了单独冲到 1.25G**；主凶仍是图标位图。

结论：**必须先「栅格化成单层小图」再缓存**；磁盘层只存显示尺寸 PNG；加载槽位绝不持有多分辨率原图。

## 2. 目标冲突与兼顾原则

| 诉求 | 含义 |
|------|------|
| 内存最小 | Idle 回 40MB；Visible 也不要多占几百 MB |
| 热区快 | Warm 窗 + `showCritical`；图标尽快有像素 |
| 翻页快 | 当前页优先；允许**少量** RAM 换速度 |

**不可行**：一边保留完整 Workspace `NSImage`，一边指望 Active 小。  
**可行**：用 **Slim 位图（单层 CGImage / 单 representation NSImage）+ 磁盘缩略图 + 页级 Hot RAM** 同时满足两边。

```text
速度靠：Warm 窗 + Slim 磁盘命中 + 当前页并发栅格化
内存靠：永不缓存多分辨率原图；RAM 只留当前±0/1 页 Slim；hide 尽快卸 blur + 清 Hot
```

## 3. 推荐架构：三层 Slim Icon

```text
┌─────────────────────────────────────────────────────────┐
│ L0 Hot RAM     当前页（可选 +1 邻页）Slim 位图，≤ ~40 张 │
│ L1 Disk PNG    显示像素尺寸缩略图（Caches），跨会话       │
│ L2 Workspace   iconForFile → 立即栅格化 → 丢弃原图       │
└─────────────────────────────────────────────────────────┘

Visible:  L0 命中秒画；miss → L1；miss → L2（栅格化后写入 L0+L1）
Hide:     卸 blur；L0 短延迟或随 Cold 清；L1 保留
Pressure: 清 L0；必要时可保留 L1
```

### 3.1 Slim 栅格化（P0，内存与速度共同前提）

对每个 path：

1. `iconForFile` 得到原图（临时）。
2. 按 `ceil(icon_s * backingScaleFactor)` 生成 **一张** RGBA bitmap（典型 128–256 px 边，而非 1024）。
3. 用该 bitmap 构造**仅含一个 representation** 的 `NSImage`（或直接缓存 `CGImage` + 绘制时包装）。
4. **立刻释放** Workspace 原图；禁止对其 `copy` / `TIFFRepresentation`。
5. 写盘：对该 bitmap 做 PNG（异步 utility 队列），禁止 TIFF 绕路。

粗算（2x、边长 160 px、35 个当前页）：

| 项 | 约占用 |
|----|--------|
| Slim RAM 一页 | 35 × 160² × 4 ≈ **3.4 MB** |
| 邻页再一页 | +3.4 MB |
| 全屏 blur（视分辨率） | ~30–80 MB |
| **Active 合计量级** | **远低于 1.25G**（目标 ≤120 MB） |

### 3.2 页级 Hot / 磁盘 Warm（P1）

| 层 | 策略 |
|----|------|
| Hot RAM | 默认 **仅当前页**；翻页时预取目标页；LRU 硬顶改为「页容量×2」或固定 ≤64 Slim 张 |
| Disk | 保留；键 = `sha(path) + pixelSize`；空目录跳过探测（已有） |
| 写盘 | 异步、不占加载信号量（已有）——改为写 **Slim PNG** |

hide 后：

- **L0**：与 Warm 对齐或更短（建议 **30–60s** 清 Hot；压力立即清）。  
- **L1**：不清。  
- 窗：继续 Slim Warm（无 blur）。

二次打开：L1 命中 → 解码小 PNG（毫秒级）→ 快于 `iconForFile`，且峰值可控。

### 3.3 热区与翻页时序（P1）

```text
HotCorner
  → showCritical：warm-reuse / ensureBlur / orderFront（≤1 帧）
  → 同轮（orderFront 之后）：layoutChrome + 绑定首页 + prefetch 当前页 Slim
  → showDeferredChrome：搜索焦点等非关键路径

Page flip
  → 立刻 prefetch 新页（并发栅格化 / 磁盘）
  → 合并 setNeedsDisplay（每 runloop 一次，已有）
  → 可选：离开页的 L0 条目可降级淘汰，控制 RAM
```

允许的「少量内存换速度」：

- 可见期间保留 **当前页 + 下一方向页** Slim（约 +3–4 MB）。  
- **不要**为速度恢复多分辨率 `NSImage` 缓存。

### 3.4 Blur / 窗（P2，次要）

| 项 | 说明 |
|----|------|
| 保持 | hide 卸 `NSVisualEffectView`；Warm 保留 `NSWindow` |
| 可选 | 低端机 / 低功耗用半透明 `tint` 替代 FullScreenUI（省 backing，观感略降） |
| 禁止 | hide 默认整窗 destroy（毁掉热区零延迟） |

## 4. 明确不做什么

- 合并 Overlay / Taskbar icon cache  
- 为省内存砍 soft-min / peek  
- 继续缓存 Workspace 多分辨率原图  
- 用更大并发（如 32）硬扛 `iconForFile` 而不栅格化（只会把峰值打得更高）  
- 预载全部应用图标进 RAM

## 5. 指标与验收

| 场景 | 验收 |
|------|------|
| Idle ≥1 min | `phys_footprint` ≈ 40MB 量级 |
| 热区打开首页出齐后 | Active **≤120 MB**（日志 `show` / `show-critical`） |
| 关闭后 60s | 回落到接近 Idle（blur 已卸 + Hot 已清） |
| 热区 | warm-reuse 时窗 ≤1 帧；冷窗可多一帧建窗 |
| 首开 / 翻页 | 当前页图标明显快于「逐个慢慢冒」；磁盘命中时接近秒显 |
| 回归 | soft-min / peek / 多屏 / 搜索 |

观测：已有 `MLLogMemory` / heartbeat；实施期可临时加 `iconRAM=count bytes≈`（可选）。

## 6. 实施分期

| ID | 内容 | 预期 |
|----|------|------|
| **S0** | Slim 栅格化：加载后只存单层小图；写盘改 PNG from bitmap；禁止 copy 多分辨率原图 | Active 从 ~GB 回到百 MB 内；首开不再被 TIFF 拖死 |
| **S1** | Hot 仅当前页（+可选邻页）；hide 清 Hot；磁盘键用 pixelSize；翻页预取 | 可见内存稳；翻页快 |
| **S2** | 热区时序确认 / 合并重绘 / 并发度按页容量微调（如 8–12） | 体感稳 |
| **S3** | （可选）弱机 blur 降级；图标字节数日志 | 锦上添花 |

**优先级：S0 必须先做**——不做栅格化，其它优化都会被多分辨率原图淹没。

## 7. 状态机（更新后）

```text
Idle/Cold     ~40MB，无 Overlay 大图，L1 磁盘可在
     │ hot corner
     ▼
showCritical  Warm 窗 + blur + 当前页 L0 填充中
     │
     ▼
Visible       blur + L0(当前页 Slim) + 可选邻页  ≈ ≤120MB
     │ hide
     ▼
Warm park     无 blur；L0 延迟清；L1 保留
     │ 超时 / pressure
     ▼
Cold          destroy 窗；L0 空；L1 保留
```

## 8. 一句话

**速度靠 Slim 磁盘 + 页级并发栅格化；内存靠「永不持有 Workspace 大图」。**  
1.25G 是缓存策略错误，不是「Overlay 天生就要 1G」。
