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

---

## 常用命令

```bash
./Scripts/build_core.sh
./Scripts/build.sh
./Scripts/run.sh
# 可选：brew install xcodegen && xcodegen generate && xcodebuild -scheme MeoLaunch
```
