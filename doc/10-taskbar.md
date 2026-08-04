# 10 — 底部任务栏（设计方案 + 开发计划）

> 在 MeoLaunch 上增加 Windows 风格的轻量任务栏：**每屏一条**，只显示该屏上的窗口，**图标旁显示标题**，支持钉住。**不显示**仅有进程、无窗口的应用。原则是尽量节约内存。

相关实现任务卡见 [07-agent-playbook.md](./07-agent-playbook.md)（T0–T5）。

---

## 1. 目标与非目标

### 目标（MVP）

| 能力 | 行为 |
|------|------|
| 常驻底栏 | **每块显示器**底部各一条任务栏 |
| 按屏过滤 | 每条任务栏**只显示落在该显示器上的窗口**；钉住且未运行的启动器可在各屏显示 |
| 图标 + 标题 | 每个条目绘制 **小图标 + 截断标题**（见 §4 显示单元） |
| 状态色 | 有可见窗口 / 仅钉住未运行，视觉区分（**不展示「仅有进程无窗口」**） |
| 左键 | 窗口芯片：未激活→前置；已最前→软最小化；已最小化→还原几何。钉住未运行→启动 |
| 右键 | 见 [11-taskbar-context-menu.md](./11-taskbar-context-menu.md)：关闭 / 最小化↔还原 / 全屏 / 钉住 / MeoLaunch▸ |
| 持久化 | 钉住列表写入 `taskbar_pins.json`（仅 path） |

### 非目标（明确不做）

- 窗口缩略图、悬停预览、分组弹出菜单
- 点击精确聚焦到某一个 `CGWindow`（需 AX/私有 API；MVP 只 activate 所属 app）
- 拖文件到图标、替代系统 Dock 的全部行为
- Accessibility 窗口树 / 私有 Dock API
- 复用 Launchpad 的 128px `MLIconCache` 作为任务栏常驻图标
- 为标题单独引入 `NSTextField` 树或 attributed string 缓存池
- **仅有进程、无可见窗口的应用**（不进入任务栏）

---

## 2. 设计原则（控内存）

1. **独立小图标 cache**  
   - 任务栏用 `MLTaskbarIconCache`：默认 **32×32**、LRU **≤48**。  
   - Overlay hide 时 `MLIconCache.purge` **不得**清掉任务栏图标。

2. **元数据极瘦 + 标题有界**  
   - 条目存 `path` / `bundleID` / `pid` / `windowID`（可 0）/ `kind` / `pinned` / **截断后的 `title`**。  
   - 标题入库前截断为 **≤ `MLTaskbarTitleMaxChars`（默认 40）** UTF-16 单元；超出加省略。  
   - Snapshot 采集上限约 **`MLTaskbarMaxWindowEntries × 屏数`**；每屏展示再截到 24。  
   - **不长期持有** `NSRunningApplication` 数组或 `CGWindowList` 原始 CFArray。

3. **单 view 绘制**  
   - `MLTaskbarView` 一个 `NSView` + `drawRect:` 画图标与标题；禁止每条目 `NSButton`/`NSImageView`/`NSTextField`。

4. **事件驱动 + 低频窗口轮询**  
   - 应用增减：`NSWorkspace` launch/terminate 通知。  
   - 窗口标题与有无窗口：默认 **1.0s** 调一次 `CGWindowListCopyWindowInfo`，抽出瘦条目后**立即释放**原始列表。  
   - 标题未变则可不发通知（可选字符串指纹 / 计数比较），减少无意义 redraw。

5. **与 Overlay 解耦 z-order**  
   - Overlay show 时任务栏 `orderOut`，hide 后恢复，避免叠层纠缠，也少一层常驻合成（见 §5.5）。

6. **标题权限降级**  
   - 较新系统上其他 app 的 `kCGWindowName` 可能为空（需屏幕录制等权限）。  
   - **空标题一律回退**到应用显示名（`CFBundleDisplayName` / `localizedName` / path lastComponent），不弹权限死循环；可选在 Prefs 提示「授权后可显示真实窗口标题」。
---

## 3. 模块划分

```
AppDelegate
    │
    ├── MLTaskbarController          每屏一条 NSWindow + View；按屏过滤窗口
    │       └── MLTaskbarView        单 view drawRect 绘制
    │
    ├── MLRunningAppsMonitor         运行态 + 有无窗口
    │
    ├── MLTaskbarPinStore            钉住列表（JSON paths）
    │
    └── MLTaskbarIconCache           独立小图标 LRU
```

- 不进 Core C：运行态依赖 AppKit / `CGWindow`，放 `Sources/System` + `Sources/UI`。
- 不与 `MLLayoutStore` 混用：Launchpad 布局 ≠ 任务栏钉住。

### 文件落点

```
Sources/System/
  MLRunningAppsMonitor.h/.m
  MLTaskbarPinStore.h/.m
  MLTaskbarIconCache.h/.m
Sources/UI/
  MLTaskbarController.h/.m
  MLTaskbarView.h/.m
Sources/App/
  AppDelegate.m                    /* start/stop 接线 */
```

持久化路径：

```
~/Library/Application Support/meoLaunch/taskbar_pins.json
```

---

## 4. 数据模型与显示单元

### 4.1 显示单元（产品语义）

任务栏条目以 **「该显示器上的可见窗口」为主**；**不显示**仅有进程、无可见窗口的应用。

| 情况 | 条目数 | 图标 | 标题文案 | 出现在哪条栏 |
|------|--------|------|----------|--------------|
| App 在本屏有 N 个可见窗口 | N 格 | app icon | 窗口标题（空则显示名） | **仅该窗口所在屏** |
| 运行中但无可见窗口 | **不显示** | — | — | — |
| 仅钉住、未运行 | 1 格 | app icon | 应用显示名 | **各屏任务栏都可显示**（启动器） |

窗口归属屏：与 `NSScreen.frame` 相交面积最大者；跨屏窗口归到面积最大的那块屏。

同一 app 多窗口时：**不合并成一格**。钉住仍按 app：任一窗口条目右键钉住 = pin 该 `path`。

超限时：每屏可见窗口取前 `MLTaskbarMaxWindowEntries`（24）；Monitor 总采集上限约为 `24 × 屏数`。

### 4.2 条目模型

```objc
enum {
    MLTaskbarTitleMaxChars = 40,
    MLTaskbarMaxWindowEntries = 24,
};

typedef NS_ENUM(NSInteger, MLTaskbarItemKind) {
    MLTaskbarItemPinnedOnly = 0,   /* 钉住且未运行 */
    MLTaskbarItemRunningNoWindow,  /* 保留枚举；UI 不再产出此类条目 */
    MLTaskbarItemRunningWindow,    /* 对应一个可见窗口 */
};

@interface MLTaskbarItem : NSObject
@property (nonatomic, copy) NSString *path;       /* .app 路径；钉住主键 */
@property (nonatomic, copy) NSString *bundleID;   /* 可空 */
@property (nonatomic, assign) pid_t pid;          /* 未运行 = 0 */
@property (nonatomic, assign) CGWindowID windowID; /* 无窗口 = 0；仅 RunningWindow */
@property (nonatomic, copy) NSString *title;      /* 已截断；绘制用 */
@property (nonatomic, assign) MLTaskbarItemKind kind;
@property (nonatomic, assign) BOOL pinned;
@end
```

### 4.3 合并规则（每屏独立 rebuild）

1. **钉住且未运行**：本屏显示 1 条 `PinnedOnly`。
2. **钉住且本屏有窗口**：只显示本屏窗口条（`pinned=YES`）；若进程在跑但本屏无窗口 → **本屏不显示**。
3. **未钉住的本屏窗口**：追加窗口条。
4. **永不添加** `RunningNoWindow` / 其它屏上的窗口。
5. 过滤：自身 `MeoLaunch`；仅 Regular；忽略 layer≠0、零面积、系统 UI。

顺序：先钉住相关（pin 顺序），再未钉住本屏窗口。

### 4.4 视觉约定

| kind | 图标 | 标题 | 指示 |
|------|------|------|------|
| `PinnedOnly` | alpha ≈ 0.55 | 同 alpha | 无或淡点 |
| `RunningWindow` | 正常 | 正常 | 强调底条 |

布局（单格）：

```
[ 4pad | 32 icon | 6 | title… | 8pad ]
```

- 单格最大宽度默认 **160pt**（可配）；标题用 `NSLineBreakByTruncatingTail` 在剩余宽度内绘制。
- 条目间距默认 **6–8pt**；总宽超出屏宽时：**缩小单格最大宽度**（下限约 72pt，仅图标+极短标题）或隐藏最右侧未钉住项（钉住优先保留）。禁止横向无限变宽导致整屏纹理巨大。

### 4.5 瘦窗口记录（Monitor 内部 → Snapshot）

```objc
@interface MLTaskbarWindowInfo : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) CGWindowID windowID;
@property (nonatomic, copy) NSString *title; /* 已截断 */
@property (nonatomic, assign) CGRect bounds; /* 用于归属显示器 */
@end
```

只保留绘制/合并需要的字段（含 **bounds 用于归属屏**）；**不存** layer、ownerName 长串（ownerName 仅过滤时用完即弃）。

---

## 5. 接口草案

### 5.1 `MLRunningAppsMonitor`（System）

```objc
FOUNDATION_EXPORT NSNotificationName const MLRunningAppsDidChangeNotification;

@interface MLRunningAppsSnapshot : NSObject
@property (nonatomic, copy, readonly) NSArray<NSString *> *runningAppPaths; /* Regular only */
@property (nonatomic, copy, readonly) NSSet<NSString *> *pathsWithVisibleWindows;
/** Visible windows, already capped & titles truncated. Empty titles omitted at source → filled by controller fallback. */
@property (nonatomic, copy, readonly) NSArray<MLTaskbarWindowInfo *> *windows;
@end

@interface MLRunningAppsMonitor : NSObject
@property (nonatomic, assign) NSTimeInterval windowPollInterval; /* default 1.0s */
@property (nonatomic, assign) NSUInteger maxWindowEntries;       /* default 24 */
@property (nonatomic, assign) NSUInteger titleMaxChars;          /* default 40 */
@property (nonatomic, strong, readonly) MLRunningAppsSnapshot *snapshot;

- (void)start;
- (void)stop;
@end
```

实现要点：

- Launch/Terminate → 立刻更新 `runningAppPaths`。
- 定时 `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | …)`：
  - 读取 `kCGWindowOwnerPID`、`kCGWindowNumber`、`kCGWindowName`、`kCGWindowLayer`、`kCGWindowBounds`（仅用于过滤零面积，不存入 snapshot）。
  - PID → path：用短生命周期 `NSRunningApplication` 或预先维护的 `pid→path` 小表（随 launch/terminate 更新），**表内只存 path 字符串**。
  - 标题：`ml_taskbar_truncate(name, titleMaxChars)`；`name` 空则 `title = @""`（UI 层回退显示名）。
  - 填满 `windows` 至 `maxWindowEntries` 后停止遍历。
  - **CFRelease / 释放** 原始 list；禁止挂到 ivar。
- 与上一拍比较：`windows` 的 `(windowID, title)` 序列 + running paths 无变化则可不发通知。
- Snapshot 不可变。

### 5.2 `MLTaskbarPinStore`（System）

```objc
FOUNDATION_EXPORT NSNotificationName const MLTaskbarPinsDidChangeNotification;

@interface MLTaskbarPinStore : NSObject
@property (nonatomic, copy, readonly) NSArray<NSString *> *pinnedPaths;

+ (NSURL *)pinsFileURL;

- (BOOL)loadFromDisk;
- (BOOL)saveToDisk;
- (void)scheduleSave; /* 300ms debounce，对齐 LayoutStore */

- (BOOL)pinPath:(NSString *)path;
- (BOOL)unpinPath:(NSString *)path;
- (BOOL)isPinned:(NSString *)path;
- (BOOL)movePinFrom:(NSInteger)from to:(NSInteger)to; /* 可二期 */
@end
```

磁盘格式：

```json
{
  "version": 1,
  "pins": [
    "/Applications/Safari.app",
    "/Applications/Utilities/Terminal.app"
  ]
}
```

只存 path，不存图标或 bundle 元数据。

### 5.3 `MLTaskbarIconCache`（System）

```objc
@interface MLTaskbarIconCache : NSObject
@property (nonatomic, assign) NSUInteger maxEntries; /* default 48 */
@property (nonatomic, assign) CGFloat iconPointSize; /* default 32 */

- (NSImage *)cachedIconForPath:(NSString *)path;
- (void)loadIconForPath:(NSString *)path
               onLoaded:(void (^)(NSString *path, NSImage *image))onLoaded;
- (void)purge; /* 仅进程退出 / stop 时；平时不 purge */
@end
```

| | Launchpad `MLIconCache` | `MLTaskbarIconCache` |
|--|--|--|
| 尺寸 | 128×128 | **32×32** |
| 上限 | 128 | **48** |
| 生命周期 | Overlay hide → purge | **常驻** |
| 预取 | 当前±邻页 | **仅当前可见条目** |

### 5.4 `MLTaskbarView`（UI）

```objc
@protocol MLTaskbarViewDelegate <NSObject>
- (void)taskbarView:(MLTaskbarView *)view didClickItemAtIndex:(NSInteger)index;
- (void)taskbarView:(MLTaskbarView *)view didRequestPinToggleAtIndex:(NSInteger)index;
@end

@interface MLTaskbarView : NSView
@property (nonatomic, weak) id<MLTaskbarViewDelegate> delegate;
@property (nonatomic, copy) NSArray<MLTaskbarItem *> *items;
@property (nonatomic, weak) MLTaskbarIconCache *iconCache;

@property (nonatomic, assign) CGFloat iconSize;      /* 32 */
@property (nonatomic, assign) CGFloat spacing;       /* 8 */
@property (nonatomic, assign) CGFloat barHeight;     /* 40 */
@property (nonatomic, assign) CGFloat itemMaxWidth;  /* 160 */
@property (nonatomic, assign) CGFloat itemMinWidth;  /* 72 */

- (NSInteger)indexAtPoint:(NSPoint)p;
@end
```

绘制要点：

- 每格：`drawInRect` 图标 + `NSString drawInRect:withAttributes:`（共享一份 `NSDictionary` attributes：字体 11–12pt、颜色、段落样式 truncate）。
- **禁止**为标题创建 `NSTextField` / `CATextLayer` 池。
- 宽度自适应：先按 `itemMaxWidth` 排布；若总宽 > bounds，等比压到 ≥ `itemMinWidth`；仍溢出则从右侧丢弃未钉住项（绘制层或 controller 裁剪均可，优先 controller）。

### 5.5 `MLTaskbarController`（UI）

```objc
@interface MLTaskbarController : NSObject
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

- (instancetype)initWithPinStore:(MLTaskbarPinStore *)pins
                         monitor:(MLRunningAppsMonitor *)monitor
                       iconCache:(MLTaskbarIconCache *)icons;

- (void)start;
- (void)stop;
- (void)rebuildItems;
@end
```

窗口约定：

- 每个 `NSScreen` 一条 `borderless` 底栏，高度约 40–44pt，宽随该屏 `visibleFrame`。
- `level` 低于 Overlay，建议 `NSFloatingWindowLevel`。
- `collectionBehavior`：`CanJoinAllSpaces` + `Stationary`。
- Overlay show → **所有** taskbar `orderOut`；Overlay hide → 按当前屏列表重建并恢复。
- 插拔屏：`NSApplicationDidChangeScreenParametersNotification` → 增删/重排各屏任务栏。

---

## 6. 合并与点击逻辑

```
displayName(path):
  bundle display name / localizedName / lastPathComponent

rebuildItems():
  items = []
  pinnedSet = pins
  windowsByPath = group(snapshot.windows)

  for path in pins:
      wins = windowsByPath[path]
      if wins.count > 0:
          for w in wins:
              append item(path, windowID=w.id, title=nonEmpty(w.title, displayName), kind=Window, pinned=YES)
      else if path in snapshot.runningAppPaths:
          append item(path, title=displayName, kind=NoWindow, pinned=YES)
      else:
          append item(path, title=displayName, kind=PinnedOnly, pinned=YES)

  for w in snapshot.windows:
      if w.path in pinnedSet: continue
      append item(..., kind=Window, pinned=NO)

  for path in snapshot.runningAppPaths:
      if path in pinnedSet: continue
      if path in pathsWithVisibleWindows: continue
      append item(path, title=displayName, kind=NoWindow, pinned=NO)

  fitToWidth(items)  /* 可选：丢弃右侧未钉住 */

click(item):  /* 左键，见 §10.3 */
  if PinnedOnly: activate/open path
  else if minimized or soft-hidden: raiseAndFocus + restoreFrame
  else if windowID is topmost user window: softMinimize
  else: raiseAndFocus + activate app

contextMenu(index):  /* 右键，见 11-taskbar-context-menu.md */
  if index < 0: MeoLaunch ▸ (关于 / 设置 / 退出)
  else:
    关闭 | 最小化↔还原 | 全屏进出  (需窗 + Accessibility)
    钉住 / 取消钉住
    MeoLaunch ▸ …

pinToggle(item):
  pinned ? unpin(path) : pin(path)
  scheduleSave + rebuildItems
```

显示名解析：可对 path 做小 LRU（≤32 条字符串），避免每次 `NSBundle` 全量读；**不要**为此加载图标资源。

---

## 7. 内存预算（Idle 增量）

| 组件 | 目标 |
|------|------|
| Taskbar `NSWindow` + 1 view | ≤ 1.5 MB |
| `MLTaskbarIconCache`（≤48 × 32pt） | ≤ 1.5 MB |
| Pin 列表 + items（含 ≤24 条 × ≤40 字 title） | ≤ **100 KB** |
| `pid→path` 小表 + 显示名小缓存 | ≤ 50 KB |
| Monitor 临时 CGWindow 缓冲 | 峰值短暂，不常驻 |
| **Idle 合计增量** | **≤ 3–4 MB**（标题有界时几乎不增） |

验收放宽：任务栏开启后 Idle **≤ 28–30 MB**（相对原 Idle ≤25）。

### 硬约束

1. 禁止任务栏走 `MLIconCache` 128px。
2. 禁止保留 `CGWindowList` 原始数组；只保留瘦 `MLTaskbarWindowInfo` 列表（有上限）。
3. 禁止每条目一个 `NSView` / `NSTextField`。
4. Overlay hide 的 purge 不得清掉 taskbar icon cache。
5. 窗口轮询默认 1s；标题 **入库即截断**；窗口条数 **硬上限 24**。
6. 禁止为每个标题保留未截断原文或历史标题 ring buffer。

---

## 8. 配置扩展

Prefs / schema（见 [06-config-schema.md](./06-config-schema.md)）：

```json
"taskbar": {
  "enabled": true,
  "window_poll_seconds": 1.0
},
"ui": {
  "overlay_icon_cache_max": 128
}
```

其余（`icon_size` / `height` / `title_max_chars` 等）仍硬编码默认值。
---

## 9. 任务卡顺序

推荐实现顺序（与 playbook 一致）：

`T0 → T1 → T3 → T4 → T2 → T5`

- T4：先画 **图标 + 回退标题（显示名）**，验证布局与截断。
- T2：接入真实 `kCGWindowName`、多窗口多格、状态色。

| ID | 内容 |
|----|------|
| **T0** | PinStore 读写 + debounce |
| **T1** | RunningAppsMonitor（先不算窗口/标题） |
| **T2** | 窗口 poll + 瘦窗口列表/标题 + 多格 + 状态色 |
| **T3** | TaskbarIconCache 32px LRU48 |
| **T4** | TaskbarView + Controller：图标 + 标题布局 |
| **T5** | 右键钉住、与 Overlay z-order |

详细验收与禁止项见 [07-agent-playbook.md](./07-agent-playbook.md)。

---

## 10. 自定义最小化 / 恢复 / 工作区 / 全屏藏栏（现行实现）

> 本节描述 MVP 之后已落地的窗口生命周期层；与 §1「非目标」中「不精确聚焦」的早期表述不同——现行点击路径按 **`CGWindowID`** 聚焦并恢复几何。

### 10.1 模块

| 模块 | 职责 |
|------|------|
| `MLMinimizeInterceptor` | 拦截黄钮；记 restoreFrame；立刻软隐藏 |
| `MLMinimizeAnimator` | （保留源码，当前未接入；避免与 Dock 双动画） |
| `MLWindowSoftState` | 以 `CGWindowID` 为主键的 soft-hidden 状态与恢复帧 |
| `MLScreenGeometry` | Quartz ↔ Cocoa ↔ AX 坐标统一换算 |
| `MLWorkAreaEnforcer` | 最大化窗口底部抬到任务栏上沿 |
| `MLTaskbarController` | 全屏时藏栏；点击恢复状态机 |

### 10.2 黄钮最小化（定案）

1. 记录 Cocoa `restoreFrame` + 屏 affinity。  
2. **先** `markSoftHidden`（芯片立即以 minimized 样式保留）。  
3. **立刻**隐藏真实窗口（不再播放本屏黑块代理动画，避免与 Dock genie 双动画）：  
   - **访达（`com.apple.finder`）** 一律 `AXMinimized=true`（不做 CGS alpha）  
   - 其他应用：优先 `CGSSetWindowAlpha(0)`（须读回 alpha≤0.15 才算成功）  
   - 否则 `AXMinimized=true`（系统记住原 frame）  
4. **禁止** 1×1 tuck / 屏外乱改 size（访达会钳制小尺寸导致无法还原）。  
5. soft 记录保留最小化时的 `AXUIElement`，供恢复精确回指。

### 10.3 点击：激活 / 最小化 / 还原

左键窗口芯片（现场判定，不单信 debounce 后的 `item.active`）：

1. **已最小化或 soft-hidden** → 优先用 soft 里保留的 `AXUIElement`；其次 `_AXUIElementGetWindow` 按 `windowID`；标题仅弱兜底；**禁止**用 App 显示名当窗口标题。按 `hideMethod`：alpha→1 或 `AXMinimized=false`，再反复套 `restoreFrame`（先 size 后 position，最长约 1.2s 重试）。Raise + 激活（soft 恢复时 **不用** `ActivateAllWindows`）。**仅当 AX 读回的 frame 与 `restoreFrame` 误差 ≤20pt** 才 `clearVerified`。
2. **已是屏幕 z 序最前的用户窗**（`topmostUserWindowIDExcludingSelf` 匹配；**不**依赖 `frontmostApplication`，避免点任务栏抢焦点后第一次点击被当成「激活」）→ 软最小化。
3. **可见但非最前** → raise + activate 该 `windowID`。
4. 钉住未运行 → 启动 / 激活 app。

黄钮与任务栏再点共用同一软最小化入口，避免两套还原逻辑。

### 10.4 芯片存活硬规则

- soft 集合内的 ID：poll / ghost / prune **不得清除**。  
- Census token 含 `soft:%u`，避免「看不见」被当成关闭。  
- SoftState 变更通知 → Controller 强制立即 `commit`（**显示桌面 peek 冻结期间除外**）。

### 10.5 工作区抬底

对填满 `visibleFrame`（或副屏 `visible≈frame` 时填满 `screen.frame`）的窗口，AX 缩至 `visibleFrame` 减去底栏高度。跳过 soft-hidden、`AXFullScreen`、已贴 work rect 的窗。比较一律走 `MLScreenGeometry`（先把 CG Quartz bounds 转 Cocoa）。

### 10.6 全屏藏栏 / 显示桌面 peek

可见性三态（Overlay 优先）：

| 模式 | 条件 | 行为 |
|------|------|------|
| `hidden` | 前台 App 整屏覆盖窗，或前台 `AXFullScreen`（连续确认） | `orderOut` |
| `peek` | 屏心清空且仍有应用窗（或芯片骤降冻结） | 整窗下移约 28pt；**展示芯片冻结** |
| `normal` | 其它 | 贴 `visibleFrame` 底边 |

规则：
- **不用**单独的 `visibleFrame≈frame`（自动隐藏菜单栏会误伤普通桌面）。
- 盖屏判定仅认**前台**非系统、非访达窗口；避免启动瞬态 / 显示桌面误藏。
- **全部最小化 / 软最小化 ≠ 自动 peek**：被动全部最小化时任务栏必须保持 `normal`（一动不动）。以 soft/min + 芯片隐藏为准；**禁止**用「CG 额外 off-screen 窗」覆盖该规则（辅助窗口会误判并卡死在 peek）。
- **点击桌面进 peek**：全部最小化后点击露出桌面 → 置 `desktopPeekUserArmed`，**强制**整窗 `Y -= PeekOffset`（约半栏高度）。该路径不走 minimize-all ignore 门闩；`applyUserArmedPeekPresentation` 直接改 frame。再点桌面退出并复位。
- **多屏芯片亲和**：`chipScreenAffinityByWid` 记录 windowID→屏。Peek / 显示桌面把窗停到屏外时，**禁止**用瞬时 bounds 重算归属（否则二屏芯片会跑到一/三屏）。冻结按屏深拷贝；解冻先保持冻结芯片，settle 后再按亲和重建。
- 进入 `hidden` 需连续 2 次确认；退出 `peek` **同步**复位 frame 并 `orderFront`，清 fullscreen streak，禁止同帧误藏。
- **展示列表 ≠ 实时快照**：monitor 抖动只写入 `pendingItems`；安静约 0.32s 后才 `commit` 到 `barView`。显示桌面期间拒绝提交「芯片大跌」的候选，并冻结快照。
- 退出 peek：保持旧芯片 → 窗列表安静约 0.45s → **一次**原子提交（粘性窗口约 1.25s 内不接受明显偏少的候选），避免进出时芯片逐个增减。用户点击桌面武装的 peek，仅在桌面中心再次被窗口覆盖时退出。
