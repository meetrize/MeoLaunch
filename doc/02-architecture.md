# 02 — 架构设计

## 1. 进程与运行模式

采用 **单进程双状态**：

```
┌──────────────────────────────────────────────────────┐
│                 meoLaunch.app (1 process)            │
│                                                      │
│  Idle 状态（常驻）                                    │
│  - 隐藏 Dock（LSUIElement = YES，可选）               │
│  - Status Item（菜单栏图标，可选）                     │
│  - HotCornerMonitor 轮询/事件驱动                     │
│  - AppIndex 后台轻量缓存                              │
│                                                      │
│  Active 状态（Overlay 打开）                          │
│  - 全屏透明 NSWindow（当前屏幕）                       │
│  - GridView 绘制图标 + 搜索框                         │
│  - 键盘/滚轮/点击处理                                 │
└──────────────────────────────────────────────────────┘
```

不拆 helper 进程，避免双倍常驻内存。若未来需要提权或沙盒隔离，再拆 `meoLaunchAgent`。

## 2. 模块图

```
                    ┌─────────────────┐
                    │  HotCorner      │
                    │  Monitor        │
                    └────────┬────────┘
                             │ show/hide
                             ▼
┌──────────┐        ┌─────────────────┐        ┌──────────────┐
│ Config   │───────▶│  Overlay        │◀───────│  Input       │
│ Store    │        │  Controller     │        │  Router      │
└──────────┘        └────────┬────────┘        └──────────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
        ┌──────────┐  ┌──────────┐  ┌──────────────┐
        │ AppIndex │  │ Grid     │  │ SearchFilter │
        │ (C)      │  │ Layout(C)│  │ (C)          │
        └────┬─────┘  └──────────┘  └──────────────┘
             │
             ▼
        ┌──────────┐
        │ Icon     │
        │ Cache    │
        └──────────┘
```

## 3. 核心模块职责

### 3.1 `AppIndex`（C）

- 扫描路径：
  - `/Applications`
  - `/System/Applications`
  - `~/Applications`
  - 可选：`/Applications/Utilities`（已含子路径则不必重复）
- 每个条目：`bundle_id`、`display_name`、`path`、`name_normalized`（小写去空白，供过滤）
- 去重：同一 `bundle_id` 或同一规范化 path 只保留一份（用户目录优先于系统）
- 增量刷新：目录 mtime / FSEvents（二期）；MVP 用「打开时重扫 + 定时 60s」

### 3.2 `SearchFilter`（C）

- 输入：UTF-8 关键字（ObjC 侧转 UTF-8）
- 匹配：`display_name` / 文件名 stem 的子串（case-insensitive）
- 二期：拼音首字母（可插可选表，增加内存，默认关闭）
- 输出：过滤后的索引数组（指针数组，不复制条目）

### 3.3 `GridLayout`（C）

```
page_capacity = cols * rows          // 默认 7*5 = 35
page_count    = ceil(n / capacity)
cell(i) → (page, row, col) → frame in view coordinates
```

- 边距、间距、图标尺寸由 Config 计算
- 支持运行时改 `cols`/`rows`，立即重算

### 3.4 `IconCache`（ObjC + C 句柄）

- Key：`path` 或 `bundle_id`
- Value：`NSImage *`（或 CGImage），按需加载
- LRU 上限（如 128 张），超出释放
- Overlay 关闭时可 `purge` 非可见页，压内存

### 3.5 `HotCornerMonitor`（ObjC）

- 读取 Config：角位、触发边长（默认 5–8 pt）、触发延迟（默认 0–50 ms 防误触）
- 实现路径 A（推荐 MVP）：`CVDisplayLink` / `NSTimer` 30–60Hz 读 `NSEvent.mouseLocation`
- 实现路径 B：`CGEventTap` 监听 `kCGEventMouseMoved`（更省 CPU，权限更严）
- 与系统「触发角」冲突：文档说明；可选检测并提示用户关闭系统左上角动作

### 3.6 `OverlayController`（ObjC）

- 创建 `NSWindow`：`borderless`、`opaque=NO`、`level = NSScreenSaverWindowLevel` 或 `kCGMaximumWindowLevelKey` 附近
- `collectionBehavior`：可跨 Space 策略可配置
- 显示动画：极短 fade（80–120ms），可关
- 点击空白 / Esc / 再触触发角 → 关闭
- 点击图标 → `NSWorkspace` 启动 → 关闭

### 3.7 `ConfigStore`

- 路径见 `06-config-schema.md`
- 启动读一次；设置面板写回；文件变更可监视（二期）

## 4. 数据流

### 打开 Overlay

```
HotCorner hit / Hotkey / StatusItem
  → OverlayController.show()
  → AppIndex.refresh_if_stale()
  → SearchFilter.apply("")
  → GridLayout.recompute()
  → GridView.reload + 异步拉取当前页 IconCache
  → makeKeyAndOrderFront + focus search (可选)
```

### 关键字过滤

```
NSTextField.change
  → UTF-8 query
  → SearchFilter.filter(index, query)   // C，同步
  → GridLayout.reset_page(0)
  → GridView.reload
```

### 滚轮翻页

```
scrollWheel deltaY / deltaX 累积
  → 超过阈值 → page +/- 1（钳制边界）
  → 可选页切换动画（transform）
  → 预取相邻页图标
```

## 5. 线程模型

| 工作 | 线程 |
|------|------|
| UI / 事件 / 窗口 | Main |
| 目录扫描 | 后台串行 queue，结果回 Main |
| 图标解码 | 后台，回 Main 设置 image |
| 触发角采样 | Main timer 或独立 runloop source（保持简单：Main） |

**禁止**在后台线程碰 `NSView`/`NSWindow`。

## 6. 内存预算（设计目标）

| 项 | 预算 |
|----|------|
| 进程基线 + Monitor | ~8–12 MB |
| AppIndex（500 条元数据） | ~0.5–1 MB |
| IconCache（当前页 35 + 邻页） | ~10–25 MB（视分辨率） |
| 窗口/layer | ~5 MB |
| **Idle 合计** | **≤ 25 MB** |
| **Active 合计** | **≤ 60 MB** |

手段：不预载全库图标；关闭 Overlay 时 `purge`；不用 WebView；不链接多余 framework。

## 7. 状态机（Overlay）

```
Hidden ──show──▶ Appearing ──▶ Visible
   ▲                               │
   └──────── hide ◀── Dismissing ◀─┘
```

Visible 子状态：`Browsing` / `Filtering`；过滤时强制 `page=0`。
