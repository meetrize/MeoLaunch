# 20 — 任务栏「无窗仍运行」芯片（N-Plan）

> 显示 **Regular 应用进程仍在、但全局已无任何窗口芯片**（可见 / 最小化 / soft-hidden 皆无）的应用，并与有窗芯片视觉区分。  
> 自动化任务卡：[20-plan.md](./20-plan.md)

相关：任务栏基线 [10-taskbar.md](./10-taskbar.md)、右键菜单 [11-taskbar-context-menu.md](./11-taskbar-context-menu.md)、peek 不变量 `.cursor/rules/taskbar-peek-invariants.mdc`。

---

## 1. 目标与非目标

### 目标

| 能力 | 行为 |
|------|------|
| 无窗运行态 | `runningAppPaths ∖ pathsWithVisibleWindows` → 产出 `MLTaskbarItemRunningNoWindow` |
| 范围 | 全部 Regular（含未钉住）；非 Regular / MeoLaunch 仍过滤 |
| 多屏 | **仅主屏**一条；次屏不追加 NoWindow |
| 视觉 | 圆角芯片 + 显示名；图标/标题淡化；虚线描边；非 active/minimized 实心样式 |
| 左键 | activate + open（开新窗）；禁止 soft-min / raise windowID |
| 右键 | 最小化/全屏禁用；关闭结束进程；Pin / 音频可用 |
| Peek | NoWindow **不计** `windowChipCount`；不破坏「全关窗 ≠ 自动 peek」 |

### 非目标

- 每屏一条无窗芯片
- 改变 CG 窗口过滤或 Regular 策略
- 把 soft-min / 最小化窗口改成 NoWindow
- 第三方库

---

## 2. 数据与合并

### 「有窗」定义

`MLRunningAppsSnapshot.pathsWithVisibleWindows` 已含该 path（可见、最小化、soft-hidden）→ **不算**无窗。

### 主屏判定

`bar.window.screen == NSScreen.mainScreen`（或 frame 相等兜底）。

### 合并顺序（每屏 `rebuildItemsForBar:`）

1. 本屏 `RunningWindow`（现逻辑）
2. Pin 区：本屏无窗口的钉住项 → `PinnedOnly`；**例外**：主屏且 path ∈ globalNoWindow → **跳过**（改由 NoWindow 表达，`pinned=YES`）
3. 追加窗口芯片
4. **仅主屏**：对 `globalNoWindow` 产出 `RunningNoWindow`（`windowID=0`，title=显示名）  
   - 顺序：先 pin 顺序中的无窗钉住项，再其余 `runningAppPaths` 顺序  
   - 硬顶 **16**；钉住优先保留

### 场景表

| 场景 | 主屏 | 次屏 |
|------|------|------|
| 未钉住 + 进程在 + 全局无窗 | 1× `RunningNoWindow` | 无 |
| 已钉住 + 进程在 + 全局无窗 | 1× `RunningNoWindow`（pinned） | `PinnedOnly` |
| 已钉住 + 未运行 | `PinnedOnly` | `PinnedOnly` |
| 任意屏有窗 / soft-min / 最小化 | 仅窗口芯片 | 同现逻辑 |

---

## 3. 视觉

| kind | 样式 |
|------|------|
| `PinnedOnly` | 裸图标（无芯片底） |
| `RunningWindow` | 实心圆角芯片 + 正常 alpha；active/min 变体 |
| `RunningNoWindow` | 淡 fill + **虚线**描边；图标/标题 alpha ≈ 0.55–0.65；标题=应用显示名 |

宽度参与与窗口芯片相同的 `fitItems` 压缩（非 pin 裸宽）。音频角标若进程有输出仍可绘制。

---

## 4. 交互

- **左键**：同 `PinnedOnly` → `activateApplication` + `openApplicationAtPath`。
- **右键**：最小化/全屏禁用；**关闭 = 结束进程**；钉住、音频静音可用。
- **拖拽**：落在窗口区（非 Pin 区）；禁止拖入 Pin 区。
- **Peek**：`windowChipCount*` 只计 `RunningWindow`；freeze 深拷贝可含 NoWindow。

---

## 5. 实现落点

| 模块 | 文件 |
|------|------|
| 合并 | `Sources/UI/MLTaskbarController+Items.m` |
| 绘制 | `Sources/UI/MLTaskbarView.m` |
| 点击/菜单 | `Sources/UI/MLTaskbarController+WindowActions.m` |
| 拖拽区 | `Sources/UI/MLTaskbarController+Drag.m`（必要时） |
| 数据源 | 已有 `MLRunningAppsSnapshot.runningAppPaths` / `pathsWithVisibleWindows` |

---

## 6. 验收要点

1. 关光某 Regular 应用全部窗口、进程仍在 → 主屏出现淡化虚线芯片；次屏无对应 NoWindow。
2. 钉住同场景：主屏为 NoWindow（非裸 Pin）；次屏仍为裸 Pin。
3. 再开窗口 → NoWindow 消失，出现 `RunningWindow`。
4. 左键 NoWindow → 应用激活并出现新窗。
5. `./Scripts/build.sh` + `./Scripts/taskbar_peek_smoke.sh` 绿。
