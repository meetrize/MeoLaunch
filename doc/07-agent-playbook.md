# 07 — Agent Playbook（自动化开发）

> 用户说「继续自动化」时：读取下方 **Status**，执行第一个 `pending` 任务卡，验收通过后标 `done`，再停下等待下一次指令（除非用户要求连做多卡）。

## Status

| ID | 状态 | 备注 |
|----|------|------|
| M0 | done | 工程骨架 + C/ObjC 桩 + clang `.app` 构建 |
| M1a | done | Core 扫描：三路径 + 去重 + CFBundle 显示名；`Scripts/scan_smoke.sh` |
| M1b | done | 7×5 网格绘制、异步 IconCache、单击启动并关闭 Overlay |
| M2a | done | ml_filter + 搜索框实时过滤；Esc 清空/关闭 |
| M2b | done | 滚轮累积翻页、底部分页点、过滤后重算页数 |
| M3a | done | 左上角触发角 + AX 权限引导；进入热区 show |
| M3b | done | Carbon ⌥Space 全局热键 toggle Overlay |
| M4 | done | config.json 读写 + Prefs（行列/触发角）持久化 |
| M5 | done | 鼠标所在屏 Overlay、fade、IconCache LRU+关闭 purge、插拔屏重置 |
| T0 | done | 任务栏 PinStore：`taskbar_pins.json` 读写 + debounce |
| T1 | done | RunningAppsMonitor：launch/terminate，先不算窗口 |
| T3 | done | TaskbarIconCache：32px LRU≤48，与 Overlay cache 隔离 |
| T4 | done | TaskbarView + Controller：图标 + 显示名标题布局；点击 activate/launch |
| T2 | done | 窗口 1s poll：瘦窗口列表/截断标题、多窗口多格、状态色 |
| T5 | done | 右键钉住、Overlay show/hide 时 taskbar orderOut/恢复 |

## 执行协议

1. **一次只做一卡**，改完立刻跑该卡验收命令。
2. C 符号前缀 `ml_`，ObjC 类型前缀 `ML`；**禁止**引入 CocoaPods / SPM / 第三方库。
3. C 头文件变更须同步 [04-implementation.md](./04-implementation.md) 与本文件任务卡「涉及文件」。
4. 不要改已冻结的产品方案文档（00–06），除非用户明确要求。
5. 主构建：`./Scripts/build.sh`；Core 冒烟：`./Scripts/build_core.sh`。
6. 本机若无完整 Xcode，以 clang bundle 为准；`project.yml` 供有 XcodeGen/Xcode 时使用。

---

## 任务卡

### M0 — 工程骨架

- **输入文档**：05、本 Plan
- **交付**：目录树、C/ObjC 桩、`Scripts/build*.sh`、`project.yml`
- **验收**：
  ```bash
  ./Scripts/build_core.sh
  ./Scripts/build.sh
  nm build/MeoLaunch.app/Contents/MacOS/MeoLaunch | grep ml_app_index_scan
  ```
- **禁止**：实现真实扫盘 / 触发角逻辑

### M1a — Core 扫描

- **输入**：03 §1、04 App 发现 API
- **改**：`Sources/Core/ml_app_index.c`、`ml_util.c`（按需）
- **做**：扫 `/Applications`、`/System/Applications`、`~/Applications`；填充 `path` / `display_name` / `name_fold`；去重
- **验收**：临时在 AppDelegate 或小 CLI 打印 `count > 0`；`build_core.sh` + `build.sh` 通过
- **禁止**：加载图标、改 UI 布局

### M1b — 网格 + 图标 + 启动

- **输入**：03 §2、04 图标/启动
- **改**：`MLGridView`、`MLOverlayController`、`MLIconCache`、AppDelegate 接线
- **做**：按 `MLConfigStore.gridConfig`（默认 7×5）画当前页；异步图标；单击 `NSWorkspace` 启动后 hide
- **验收**：Show Overlay 可见应用图标；点击能启动
- **禁止**：搜索过滤、翻页动画打磨（可固定 page=0）

### M2a — 过滤 + 搜索框

- **输入**：03 §1.3
- **改**：`ml_filter.c`、`MLSearchField`、Overlay 绑定
- **做**：实时过滤；Esc 清空或关闭
- **验收**：输入关键字后可见项减少；空查询恢复全量
- **禁止**：拼音

### M2b — 滚轮翻页

- **输入**：03 §3
- **改**：`MLGridView`/`MLOverlayController`、`MLPageIndicator`
- **做**：累积 delta 翻页；底部分页点；过滤后重算页数
- **验收**：滚轮可换页；边界不越界
- **禁止**：改扫描逻辑

### M3a — 触发角

- **输入**：03 §4、04 HotCorner
- **改**：`MLHotCornerMonitor`、AppDelegate 启动 monitor
- **做**：默认左上角；`AXIsProcessTrustedWithOptions` 引导；进入热区 show
- **验收**：辅助功能开启后移入左上角出现 Overlay
- **禁止**：实现完整 Prefs UI（可用硬编码 config）

### M3b — 全局热键

- **输入**：06 hotkey 默认
- **改**：`MLHotKeyManager`（Carbon `RegisterEventHotKey`）
- **做**：默认 ⌥Space toggle Overlay
- **验收**：热键 toggle；与菜单 Show 一致
- **禁止**：第三方 Shortcut 库

### M4 — 配置持久化

- **输入**：06 schema
- **改**：`MLConfigStore`、`MLPrefsWindow`
- **做**：读写 `~/Library/Application Support/meoLaunch/config.json`；Prefs 改 cols/rows/触发角
- **验收**：改行列 → 重启进程仍生效
- **禁止**：iCloud 同步

### M5 — 打磨

- **输入**：00 成功指标
- **改**：Overlay 多屏、fade、IconCache purge、内存
- **验收**：Instruments 粗测接近 Idle ≤25MB / Active ≤60MB；插拔屏热区正确
- **禁止**：大重构目录

### T0 — 任务栏 PinStore

- **输入**：[10-taskbar.md](./10-taskbar.md) §5.2
- **改**：`Sources/System/MLTaskbarPinStore.h/.m`；`Scripts/build.sh` 纳入编译
- **做**：读写 `~/Library/Application Support/meoLaunch/taskbar_pins.json`；`pin`/`unpin`/`isPinned`；`scheduleSave` 300ms debounce；变更发 `MLTaskbarPinsDidChangeNotification`
- **验收**：`./Scripts/build.sh` 通过；临时调用 pin 后重启（或再 load）pins 仍在；文件仅含 path 数组
- **禁止**：存图标、接 UI、跑窗口枚举

### T1 — RunningAppsMonitor（无窗口态）

- **输入**：10 §5.1（先忽略 `pathsWithVisibleWindows`）
- **改**：`Sources/System/MLRunningAppsMonitor.h/.m`
- **做**：订阅 `NSWorkspace` launch/terminate；维护 Regular 策略 app 的 path 列表；发 `MLRunningAppsDidChangeNotification`；snapshot 不可变；过滤自身 MeoLaunch
- **验收**：启动/退出任意 app 后 snapshot 变化；不长期持有 `NSRunningApplication` 数组
- **禁止**：`CGWindowList`、任务栏 UI、图标加载

### T3 — TaskbarIconCache

- **输入**：10 §5.3、§7
- **改**：`Sources/System/MLTaskbarIconCache.h/.m`
- **做**：异步加载；默认 32pt、`maxEntries=48` LRU；与 `MLIconCache` 完全分离
- **验收**：加载若干 path 后 `cachedCount ≤ 48`；Overlay hide 的 `MLIconCache.purge` 不影响本 cache
- **禁止**：128px 大图、接到 GridView

### T4 — TaskbarView + Controller（图标 + 标题）

- **输入**：10 §4、§5.4、§5.5、§6
- **改**：`MLTaskbarView`、`MLTaskbarController`、`AppDelegate` 接线；依赖 T0/T1/T3
- **做**：底栏 borderless 窗；`rebuildItems` = pins ⊕ running（T2 前可先一 app 一格）；单 view `drawRect` 绘制 **图标 + 截断标题**（先用显示名）；`itemMaxWidth`/`MinWidth`；左键 activate 或 launch；`PinnedOnly` 低透明
- **验收**：底栏可见图标与标题文字；标题过长尾部省略；点击可切换/启动；`./Scripts/build.sh` 通过；Idle 增量粗测 ≤4MB
- **禁止**：每条目 NSView/NSTextField、窗口缩略图、真实 kCGWindowName（留给 T2）

### T2 — 窗口列表 / 标题 + 状态色

- **输入**：10 §4.1、§4.5、§5.1
- **改**：`MLRunningAppsMonitor`、`MLTaskbarView`/`Controller`
- **做**：默认 1.0s `CGWindowListCopyWindowInfo`；产出瘦 `windows`（`windowID` + 截断 title ≤40 + path/pid）；上限 24；同 app 多窗口多格；空名回退显示名；区分 `RunningNoWindow` / `RunningWindow`；用完释放原始 list
- **验收**：多窗口 app 出现多格且标题不同（或权限不足时均为显示名）；有窗口 / 仅进程视觉不同；无原始 window list 常驻
- **禁止**：未截断标题缓存、bounds 常驻、Accessibility 聚焦单窗、缩略图

### T5 — 右键钉住 + Overlay 协同

- **输入**：10 §2 原则5、§5.5 窗口约定
- **改**：`MLTaskbarView` 菜单、`MLTaskbarController`、`MLOverlayController` show/hide 钩子
- **做**：右键钉住/取消钉住并 `scheduleSave`；Overlay show → taskbar `orderOut`，hide → 恢复
- **验收**：钉住重启仍在；Overlay 打开时任务栏不挡网格；关闭 Overlay 后任务栏回来
- **禁止**：Prefs UI、多屏每屏一条、拖拽重排 pins（可二期）

---

## 常用命令

```bash
./Scripts/build_core.sh
./Scripts/build.sh
./Scripts/run.sh
# 可选：brew install xcodegen && xcodegen generate && xcodebuild -scheme MeoLaunch
```
