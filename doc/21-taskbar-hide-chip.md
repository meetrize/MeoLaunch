# 21 — 任务栏「隐藏任务芯片」（H-Plan）

> 右键可将某应用标记为「隐藏任务芯片」：该应用**全局无窗**时不在任务栏占位；**一旦有窗**仍显示窗口芯片，并可右键「显示任务芯片」恢复无窗占位。  
> 自动化任务卡：[21-plan.md](./21-plan.md)

相关：任务栏基线 [10-taskbar.md](./10-taskbar.md)、右键菜单 [11-taskbar-context-menu.md](./11-taskbar-context-menu.md)、无窗仍运行 [20-taskbar-running-no-window.md](./20-taskbar-running-no-window.md)、peek 不变量 `.cursor/rules/taskbar-peek-invariants.mdc`。

---

## 1. 目标与非目标

### 目标（MVP）

| 能力 | 行为 |
|------|------|
| 隐藏 | 芯片右键「隐藏任务芯片」→ 将该 app `path` 记入隐藏集并持久化 |
| 无窗不显示 | path ∈ 隐藏集 **且** path ∉ `pathsWithVisibleWindows` → **不产出** `RunningNoWindow` / `PinnedOnly`（任何屏） |
| 有窗仍显示 | path ∈ 隐藏集但全局仍有窗（可见 / 最小化 / soft-hidden）→ **照常**产出 `RunningWindow` 芯片 |
| 恢复 | 有窗芯片右键文案改为「显示任务芯片」→ 从隐藏集移除；之后无窗又可出现 NoWindow / Pin 启动器 |
| 多窗一致 | 隐藏按 **app path**（与钉住同粒度）；同 app 任一窗口芯片操作即影响该 path |

### 非目标

- Prefs 里管理「已隐藏列表」（MVP 靠再次开窗后右键恢复；见 §6 恢复路径）
- 按 `windowID` / 单窗口隐藏
- 改左键 activate / soft-min / peek 语义
- 改变 `windowChipCount*`（仍只计 `RunningWindow`）
- 第三方库

---

## 2. 产品语义（一句话）

**隐藏 =「无窗时不要占任务栏格子」；有窗芯片永远优先显示。**

与钉住正交：

| 钉住 | 隐藏 | 全局有窗 | 主屏表现（示意） |
|------|------|----------|------------------|
| 否 | 否 | 否 | `RunningNoWindow`（进程在） |
| 否 | **是** | 否 | **无芯片** |
| 是 | 否 | 否 | `RunningNoWindow`（pinned）或次屏 `PinnedOnly` |
| 是 | **是** | 否 | **无芯片**（含次屏不再出裸 Pin） |
| 任意 | 任意 | **是** | 仅各屏 `RunningWindow`（隐藏不影响有窗芯片） |

「有窗」定义与 N-Plan 一致：`MLRunningAppsSnapshot.pathsWithVisibleWindows`（含最小化与 soft-hidden）。

---

## 3. 数据与持久化

### 3.1 Store

新建 `MLTaskbarHideStore`（镜像 `MLTaskbarPinStore` 瘦实现）：

| 项 | 约定 |
|----|------|
| 文件 | `~/Library/Application Support/meoLaunch/taskbar_hidden_chips.json` |
| 格式 | `{ "hidden": [ "/Applications/Foo.app", ... ] }` |
| API | `isHidden:` / `hidePath:` / `unhidePath:` / `hiddenPaths` / load·save·scheduleSave |
| 匹配 | `stringByStandardizingPath`；与 pin 相同的 path 规范化 |
| 通知 | `MLTaskbarHideDidChangeNotification` → Controller 全屏 `rebuild` |

不进 Core C；不与 `MLConfigStore` 混写。

### 3.2 芯片字段（可选）

`MLTaskbarItem` 可增加 `BOOL taskChipHidden`（rebuild 时从 store 写入），供菜单切换文案；**合并过滤以 store 为准**，不以 chip 字段为权威。

---

## 4. 合并规则（改动点）

在现有 `rebuildItemsForBar:`（见 10 / 20）上增加过滤，顺序建议：

1. 照常收集本屏窗口 → `RunningWindow`（**不**因 hidden 丢弃）。
2. 产出 `PinnedOnly` 前：若 `hideStore isHidden:path` **且** path ∉ `pathsWithVisibleWindows` → **跳过**。
3. 产出 `RunningNoWindow` 前：对候选 path 同样若 hidden → **跳过**（即使钉住优先队列也不入选）。
4. 次屏裸 Pin 与主屏 NoWindow 使用同一 hidden 判定（全局无窗才抑制）。

伪代码：

```text
BOOL suppressIdleChip(path):
  return [hideStore isHidden:path]
      && ![pathsWithVisibleWindows containsPath:path]

if (would emit PinnedOnly || RunningNoWindow) && suppressIdleChip(path):
  skip
```

有窗时各屏窗口芯片照旧；隐藏态**不**增加新 `kind`。

---

## 5. 右键菜单

### 5.1 结构（窗口操作与 MeoLaunch 之间）

```text
关闭
最小化 / 还原
进入全屏 / 退出全屏
────────
钉住 / 取消钉住
隐藏任务芯片 / 显示任务芯片   ← 本功能
────────
（音频静音… 若有）
MeoLaunch ▸
```

### 5.2 文案与可用性

| 条件 | 菜单标题 | enabled |
|------|----------|---------|
| path 未隐藏 | 隐藏任务芯片 | 有有效 `path` 即启用（含 `PinnedOnly` / `RunningNoWindow` / `RunningWindow`） |
| path 已隐藏 | 显示任务芯片 | 同上（有窗芯片上必现；无窗时芯片已消失故看不到） |

新增 `MLTaskbarMenuActionHideChipToggle`；View 组菜单，Controller 调 hideStore 后 rebuild。

### 5.3 文案 key

- `taskbar.hide_chip` / `taskbar.show_chip`（中英 `MLStrings`）

---

## 6. 恢复路径（无 Prefs 时）

1. **主路径**：隐藏后用户仍可通过 Overlay / Spotlight / Dock 打开应用 → 出现窗口芯片 → 右键「显示任务芯片」。  
2. **钉住被抑制**：隐藏 + 无窗时裸 Pin 也不显示；恢复同上，或先开窗再 unhide。  
3. **非目标**：MVP 不做 Prefs 列表；若手测痛点大，另开卡加「已隐藏的任务芯片」管理页。

---

## 7. 交互与副作用边界

| 项 | 约定 |
|----|------|
| 左键 | 不变 |
| Peek | 隐藏只少 idle 芯片；全关窗仍可用户武装 peek；不改 freeze 语义 |
| 拖拽 | 无额外规则；被抑制的 path 本来不可见 |
| 音频 | 有窗芯片上角标逻辑不变；无芯片则无角标 |
| 关闭进程（NoWindow） | 隐藏后无 NoWindow 芯片时，用户不能从任务栏结束该进程（可接受；可用其他方式） |

---

## 8. 模块与改动文件

```
MLTaskbarHideStore          Sources/System  — 隐藏 path 集 + JSON
MLTaskbarController+Items   Sources/UI      — rebuild 过滤 idle 芯片
MLTaskbarView               Sources/UI      — 菜单项 + enum
MLTaskbarController+WindowActions — HideChipToggle 分发
AppDelegate                 注入 hideStore（与 pinStore 并列）
MLStrings                   中英文案
```

| 文件 | 改动 |
|------|------|
| `Sources/System/MLTaskbarHideStore.h/.m` | 新建 |
| `Sources/UI/MLTaskbarController*.{h,m}` | 持有 store；过滤；菜单 action |
| `Sources/UI/MLTaskbarView.h/.m` | enum + 菜单项 |
| `Sources/App/AppDelegate.m` | 创建/注入 store |
| `Sources/System/MLStrings.m` | keys |
| `Scripts/build.sh` / `project.yml` | 登记新 `.m` |
| `doc/10-taskbar.md` / `11-…` / `00-overview` | 交叉引用 |
| 可选 | peek smoke 补一条「hidden 不产出 NoWindow」headless 断言 |

---

## 9. 手测清单（里程碑结束）

1. 未钉住 app：关光所有窗 → 有 `RunningNoWindow` → 右键隐藏 → 芯片消失；进程仍可在活动监视器看到。  
2. 再开窗 → 窗口芯片出现 → 右键为「显示任务芯片」→ 点后关光窗 → NoWindow 再次出现。  
3. 已钉住 app：隐藏后无窗 → 主屏无 NoWindow、次屏无裸 Pin；开窗后各屏窗口芯片正常。  
4. 同 app 两窗口：任一芯片隐藏/显示，两芯片菜单文案一致。  
5. 隐藏不影响：有窗时 soft-min / 激活 / peek 用户武装。  
6. `./Scripts/build.sh` + `./Scripts/taskbar_peek_smoke.sh` 全绿。

---

## 10. 与既有 Plan 关系

- **高于**已全部 done 的 20/19/18/…：本里程碑用 `doc/21-plan.md` 排队。  
- 不回退 N-Plan 行为：仅对 **hidden ∩ 无窗** 抑制 NoWindow/Pin；未隐藏 path 行为与 20 文档一致。
