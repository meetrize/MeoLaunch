# 11 — 任务栏芯片右键菜单（技术方案）

> 状态：**已实现**（2026-07-31）。  
> 关联：[10-taskbar.md](./10-taskbar.md)  
> 日期：2026-07-31

## 1. 目标与现状

**现状**：`MLTaskbarView` 右键仅「钉住 / 取消钉住」，经 delegate 调 `taskbarView:didRequestPinToggleAtIndex:`。

**目标菜单结构**（窗口芯片；钉住未运行见 §3）：

```text
关闭
最小化 / 还原              ← 文案随状态切换
进入全屏 / 退出全屏        ← 文案随 AXFullScreen 切换
────────
钉住 / 取消钉住            ← 保留现有
────────
MeoLaunch ▸
    关于 MeoLaunch
    设置…
    退出 MeoLaunch
```

同迭代强烈建议：

- **空白任务栏右键**：仅 MeoLaunch 子菜单（关于 / 设置 / 退出）
- **打开菜单时现场读状态**（soft / AXFullScreen），不单信 debounce 后的芯片字段

## 2. 架构

```
MLTaskbarView
    │  build NSMenu + action enum
    ▼
MLTaskbarController
    ├── close / minimize↔restore / fullscreen  →  AX + soft-minimize
    ├── pin toggle                             →  pinStore
    └── about / prefs / quit                   →  id<MLTaskbarAppActions> (AppDelegate)
```

| 层 | 职责 |
|----|------|
| `MLTaskbarView` | 组菜单、标题/enabled、弹出；不直接动 AX |
| `MLTaskbarController` | 关窗 / 最小化↔还原 / 全屏 / 钉住；转发应用级动作 |
| `AppDelegate`（`MLTaskbarAppActions`） | 关于、设置、退出 — 与 Status Item 同源 |

推荐 **action enum** + 单一 delegate：

```objc
typedef NS_ENUM(NSInteger, MLTaskbarMenuAction) {
    MLTaskbarMenuActionClose = 0,
    MLTaskbarMenuActionMinimizeToggle,
    MLTaskbarMenuActionFullscreenToggle,
    MLTaskbarMenuActionPinToggle,
    MLTaskbarMenuActionAbout,
    MLTaskbarMenuActionPreferences,
    MLTaskbarMenuActionQuit,
};
```

MeoLaunch 三项经 `weak id<MLTaskbarAppActions> appActions` 注入（`showAbout` / `showPreferences` / `quitApp`），由 AppDelegate 实现。

## 3. 各菜单行为

### 3.1 关闭

- 用芯片 `windowID` 找 `AXUIElement`（复用 `copyAXWindowForItem:`）。
- 优先 `AXUIElementPerformAction(win, kAXCloseAction)`；失败再试关闭按钮 Press。
- soft-hidden：**先 deminiaturize / alpha=1，再 Close**，避免幽灵 soft 记录。
- `PinnedOnly` / 无窗：菜单项禁用。

### 3.2 最小化 / 还原（切换）

| 当前状态 | 文案 | 动作 |
|----------|------|------|
| soft-hidden 或 `item.minimized` | 还原 | `raiseAndFocusWindowForItem:` |
| 可见 | 最小化 | `softMinimizeItem:`（与左键/黄钮同管线） |

`PinnedOnly`：禁用。不要另写一套隐藏逻辑。

### 3.3 全屏

- 读/写 `AXFullScreen`（项目已用 `CFSTR("AXFullScreen")`）。
- 未全屏 →「进入全屏」；已全屏 →「退出全屏」。
- 不支持或读失败：禁用。
- 进入系统全屏后任务栏按现有逻辑 `hidden`，属预期。
- `PinnedOnly` / 无 AX：禁用。

### 3.4 钉住

保持现有逻辑；放在窗口操作与 MeoLaunch 子菜单之间（分隔线）。

### 3.5 MeoLaunch 子菜单

| 项 | 实现 |
|----|------|
| 关于 | 简易 `NSAlert`/小面板：图标 + `CFBundleShortVersionString` / `CFBundleVersion` + 一行版权 |
| 设置 | 现有 `MLPrefsWindow` / `showPrefs:` |
| 退出 | `[NSApp terminate:nil]` |

应用级菜单：任意芯片（含 PinnedOnly）及空白栏均可用。

## 4. 改动文件

| 文件 | 改动 |
|------|------|
| `Sources/UI/MLTaskbarView.h/.m` | enum/delegate；扩展 `rightMouseDown:`；空白栏菜单 |
| `Sources/UI/MLTaskbarController.h/.m` | close / min-toggle / fullscreen；`appActions`；处理 enum |
| `Sources/App/AppDelegate.m` | 实现 `MLTaskbarAppActions`；注入；`showAbout` |
| `Sources/System/MLStrings.m` | 中英 key |
| `doc/10-taskbar.md` | 右键说明与本方案交叉引用 |

文案 key 示例：

- `taskbar.close` / `taskbar.minimize` / `taskbar.restore`
- `taskbar.enter_fullscreen` / `taskbar.exit_fullscreen`
- `taskbar.submenu.meolaunch` / `taskbar.about`
- 设置/退出可复用 `menu.preferences` / `menu.quit`

## 5. 边界与权限

- 无辅助功能：关闭 / 最小化 / 全屏禁用（或提示去系统设置）。
- 多窗同 app：只动该芯片的 `windowID`。
- peek 冻结期间右键仍可用；关窗/最小化后走现有 soft 通知刷新。
- 打开菜单瞬间现场读 soft / AXFullScreen。

## 6. 建议分期功能（非本迭代必做）

| 优先级 | 功能 | 说明 |
|--------|------|------|
| ★ 本迭代 | 空白任务栏右键 | 仅 MeoLaunch 子菜单 |
| ★ 本迭代 | 菜单弹出时刷新状态 | 文案/enabled 准确 |
| 二期 | 显示桌面 | 与 peek 状态机联动 |
| 二期 | 强制退出 | ⌥ 才显示 |
| 二期 | 隐藏应用 | 整 app hide/unhide |
| 二期 | 移到其他显示器 | 多屏 |
| 二期 | 在 Finder 中显示 | `activateFileViewerSelectingURLs` |
| 二期 | 新建窗口 | 行为因 app 而异，慎做 |
| 不做 | 缩略图预览 | 非目标，内存高 |

## 7. 实施顺序

1. Strings + enum/delegate + 菜单骨架（钉住 + MeoLaunch 三项）
2. 最小化/还原切换（复用现成 API）
3. 关闭
4. 全屏
5. About + `appActions` 注入
6. 空白栏右键 + 菜单即时状态
7. 更新 `doc/10-taskbar.md` + 手测 + `./Scripts/build.sh`

## 8. 验收清单

1. 可见窗：右键最小化 → 芯片 minimized → 再右键「还原」→ 几何正确。
2. 还原后：右键关闭 → 未钉住芯片消失 / 已钉住变 PinnedOnly。
3. 全屏切换成功；退出全屏后任务栏按现有逻辑恢复。
4. PinnedOnly：关闭/最小化/全屏禁用；MeoLaunch 子菜单可用。
5. 空白栏右键：仅 MeoLaunch 子菜单可用。
6. 关于显示版本；设置打开 Prefs；退出结束进程。
7. 中英切换后菜单文案正确。
8. `./Scripts/build.sh` 通过。
