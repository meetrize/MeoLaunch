# 04 — 实现路径与关键细节

## 1. 开发阶段

### Phase 0 — 工程骨架（0.5–1 天）

- Xcode macOS App 工程，`LSUIElement` 可选
- 混编：`.c` / `.h` + `.m` / `.h`
- 空窗口验证、Hardened Runtime 关闭（开发期）、签名本地 Debug

### Phase 1 — App 扫描与网格（2–3 天）

1. C：`app_index_scan()` / `app_index_free()`
2. ObjC：把结果转成轻量 model 或直接持有 C 数组
3. `NSCollectionView` **或** 自定义 `NSView` 手绘网格

**推荐自定义 `NSView` 手绘**，原因：

- 比 CollectionView 更可控、更轻
- Launchpad 式固定网格不必用复杂布局引擎
- 翻页可用两页 layer 切换

伪代码（布局）：

```c
typedef struct {
    int cols, rows;
    float origin_x, origin_y;
    float cell_w, cell_h;
    float icon_size;
} MLGridMetrics;

void ml_grid_metrics_compute(MLGridMetrics *out,
                             float view_w, float view_h,
                             int cols, int rows,
                             float padding, float spacing);
```

### Phase 2 — 搜索与翻页（1–2 天）

- 顶部 `NSTextField`（无边框、居中）
- C 过滤返回 `uint32_t *indices` + `count`
- `scrollWheel:` 累积翻页；底部分页点

### Phase 3 — 触发角与常驻（1–2 天）

```objc
// 简化：定时采样
- (void)tick {
  NSPoint p = [NSEvent mouseLocation];
  NSScreen *s = /* screen containing p */;
  NSRect f = s.frame;
  // Cocoa 坐标：原点左下；左上角热区：
  NSRect hot = NSMakeRect(NSMinX(f), NSMaxY(f) - size, size, size);
  if (NSPointInRect(p, hot)) [self requestShow];
}
```

注意：多屏时 `mouseLocation` 是全局坐标，热区必须按对应 `NSScreen.frame` 计算。

权限检测：

```objc
AXIsProcessTrustedWithOptions(
  (__bridge CFDictionaryRef)@{
    (__bridge id)kAXTrustedCheckOptionPrompt: @YES
  });
```

### Phase 4 — 配置、快捷键、打包（1–2 天）

- JSON 读写（ObjC `NSJSONSerialization`）
- `MASShortcut` 类库**不引入**；用 `Carbon RegisterEventHotKey` 或 `CGEventTap` 监听组合键
- 设置窗口简单 Form
- 图标、Bundle、公证（发布期）

**合计 MVP：约 6–10 人日。**

---

## 2. 关键 API 清单

### 应用发现

```objc
// 枚举目录
[[NSFileManager defaultManager]
  contentsOfDirectoryAtURL:appsURL
  includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsPackageKey]
  options:NSDirectoryEnumerationSkipsHiddenFiles
  error:&err];

// Bundle 信息
NSBundle *b = [NSBundle bundleWithURL:appURL];
NSString *name = b.infoDictionary[@"CFBundleDisplayName"] ?: ...;
```

也可用 Launch Services，但目录扫描对「Applications 文件夹」语义更直观。

### 图标与启动

```objc
NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
[icon setSize:NSMakeSize(128, 128)]; // 再按屏幕 scale 缓存

[[NSWorkspace sharedWorkspace]
  openApplicationAtURL:url
  configuration:[NSWorkspaceOpenConfiguration configuration]
  completionHandler:nil];
```

### 全屏 Overlay 窗口

```objc
NSWindow *w = [[NSWindow alloc]
  initWithContentRect:screen.frame
  styleMask:NSWindowStyleMaskBorderless
  backing:NSBackingStoreBuffered
  defer:NO];
w.opaque = NO;
w.backgroundColor = [NSColor clearColor];
w.level = NSScreenSaverWindowLevel;
w.collectionBehavior =
  NSWindowCollectionBehaviorCanJoinAllSpaces |
  NSWindowCollectionBehaviorFullScreenAuxiliary;
w.ignoresMouseEvents = NO;
```

内容视图加 `NSVisualEffectView` + 自定义 `MLGridView`。

### 全局快捷键（示例思路）

- `RegisterEventHotKey` + `InstallEventHandler`（经典、轻）
- 或本地/全局 `NSEvent` monitor（需权限时注意）

---

## 3. C 核心建议头文件

```c
/* ml_app_index.h */
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct MLAppEntry {
    char *path;           /* UTF-8 */
    char *display_name;   /* UTF-8 */
    char *name_fold;      /* 小写折叠，供搜索 */
} MLAppEntry;

typedef struct MLAppIndex {
    MLAppEntry *items;
    size_t count;
    size_t capacity;
} MLAppIndex;

int  ml_app_index_scan(MLAppIndex *idx, const char **roots, size_t root_count);
void ml_app_index_clear(MLAppIndex *idx);

/* 过滤：out_indices 由调用方预分配 count 大小，返回匹配数 */
size_t ml_app_index_filter(const MLAppIndex *idx,
                           const char *query_utf8,
                           uint32_t *out_indices,
                           size_t out_cap);

/* ml_grid.h */
typedef struct MLGridConfig {
    int cols, rows;
    float padding, spacing;
    float icon_size; /* 0 = auto */
} MLGridConfig;

typedef struct MLCellFrame {
    float x, y, w, h;
    float icon_x, icon_y, icon_s;
    float label_y;
} MLCellFrame;

void ml_grid_cell_frame(const MLGridConfig *cfg,
                        float view_w, float view_h,
                        int index_in_page,
                        MLCellFrame *out);

static inline int ml_grid_page_capacity(const MLGridConfig *c) {
    return c->cols * c->rows;
}
```

ObjC 通过 bridging 直接 `#import "ml_app_index.h"`。

---

## 4. 性能要点

1. **图标绝不在扫描阶段同步全量加载** — 只存 path
2. **当前页 + 左右邻页** 预取；其余不进缓存
3. **过滤**只动索引数组，不动 `MLAppEntry` 本体
4. **触发角**用 20–30 Hz 足够；或 event tap 更省电
5. **字符串**：扫描时一次生成 `name_fold`，过滤时 `strstr`
6. **绘制**：`drawRect` 只画当前页；或 CALayer 每格一个（注意 layer 数量 35 可接受）

## 5. 坑点

| 坑 | 处理 |
|----|------|
| Cocoa 坐标原点在左下 | 触发角 Y 用 `NSMaxY(screen.frame) - size` |
| 多屏 frame 可能负坐标 | 热区必须相对具体 `NSScreen` |
| 系统触发角抢事件 | 文档提示；优先 shortcut 兜底 |
| App Sandbox | 分发若走沙盒，扫 `/Applications` 通常可读；全局监听受限，**建议非沙盒 + Hardened Runtime + 公证** |
| 缩放因子 | 图标缓存 key 带 `backingScaleFactor` |
| 中文名搜索 | 用系统显示名；拼音二期 |
| 焦点偷取 | Overlay `makeKeyAndOrderFront`；关闭后把焦点还回原 App（记录 `NSWorkspace.frontmostApplication`） |

## 6. 测试清单

- [ ] 空 `~/Applications` 不崩溃
- [ ] 200+ App 滚动翻页无卡顿
- [ ] 快速进出触发角无闪烁（延迟参数）
- [ ] 过滤后滚轮页数正确
- [ ] 无辅助功能时降级可用
- [ ] 改 cols/rows 立即重排
- [ ] 休眠唤醒后 Monitor 仍工作
- [ ] 外接显示器插拔后热区正确

## 7. 发布

1. Developer ID 签名
2. `notarytool` 公证
3. Sparkle 自动更新（二期，可选；注意引入第三方需评估体积）
4. dmg / pkg 安装；可选安装 LaunchAgent 登录启动
