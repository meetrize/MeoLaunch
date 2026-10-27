# 22-Plan — 任务栏「快速定位芯片」（Q-Plan 自动化任务卡）

> 用户说「继续」「全自动开发」「做 Q 计划」「按 22-plan」「快速定位」「Chip Locator」等 → 读下方 **Status**，执行第一个 `pending` 卡。  
> 设计：[22-taskbar-chip-locator.md](./22-taskbar-chip-locator.md)

## Status

| ID | 状态 | 备注 |
|----|------|------|
| Q0 | done | HotKey 双槽 + config/Prefs；⌃⌘Space；build OK |
| Q1 | done | 会话级 window/path/screen MRU；front+raise touch；snapshot prune |
| Q2 | done | NSPanel+VE+搜索+NSTableView；10 行/展开；fade；热键 toggle |
| Q3 | done | unfitted 候选+HideChip；本屏 section；模糊；图标/副标题 |
| Q4 | done | raiseOnly API；↑↓/Enter/Esc/点击；开面板前置第 1 条 |
| Q5 | done | Overlay 互斥；snapshot 温和刷新；文案；build+peek smoke |

## 执行协议

1. **一次一卡**；验收后同一会话继续下一张 pending。  
2. 每卡结束：`./Scripts/build.sh` 必须通过。  
3. 禁止第三方库；不改 `doc/00`–`doc/06` 正文（overview 索引与 06 schema 热键字段除外）。  
4. Commit 仅在用户明确要求时；message 用简体中文。  
5. 改完把 Status 标 `done` 并写备注。  
6. 遵守 peek 不变量：`.cursor/rules/taskbar-peek-invariants.mdc`。  
7. Locator **永不**对 `RunningWindow` 走 soft-min toggle；只用 raiseOnly。  
8. 决策以 [22-taskbar-chip-locator.md](./22-taskbar-chip-locator.md) §12 为准。

---

## 任务卡

### Q0 — HotKey 双槽 + config / Prefs（P0）

- **改**：
  - `Sources/System/MLHotKeyManager.h/.m`
  - `Sources/System/MLConfigStore.h/.m`
  - `Sources/UI/MLPrefsWindow.m`（+ 录制器复用）
  - `Sources/System/MLStrings.m`（文案）
  - `Sources/App/AppDelegate.m`（第二路 fire → Locator toggle 占位可先 NSLog/空实现）
  - `doc/06-config-schema.md`（`hotkey_chip_locator`）
- **做**：
  1. Carbon 热键 id=1 Overlay、id=2 Locator；独立 enabled/key/modifiers
  2. 默认 Locator：⌃⌘Space（key 49 + control+command）
  3. Prefs 第二行「快速定位任务芯片」录制 + 启用勾选
  4. 注册失败打日志；delegate 回调区分 overlay / locator
- **验收**：`./Scripts/build.sh`
- **禁止**：实现面板 UI；改 Overlay 行为语义

---

### Q1 — `MLWindowActivationMRU`（P0）

- **改**：
  - `Sources/System/MLWindowActivationMRU.h/.m`（新建）
  - `Sources/UI/MLTaskbarController*` / AppDelegate 注入或 monitor 旁路
  - `project.yml` / `Scripts/build.sh` 若需登记源文件
- **做**：
  1. 会话级有序 `windowID`（新在前，容量 ~64）；关闭/退出剔除
  2. path 级次级 MRU（NoWindow / Pin）
  3. 监听 front window 变化；raise 成功可 `touch`
  4. **不**落盘
- **验收**：`./Scripts/build.sh`
- **禁止**：面板 UI；改 peek

---

### Q2 — Locator 面板壳 UI（P0）

- **改**：
  - `Sources/UI/MLChipLocatorPanel.h/.m`（或 Controller+Panel）
  - `Sources/UI/MLChipLocatorController.h/.m`
  - `project.yml` 登记
- **做**：
  1. 可激活 NSPanel + VisualEffect；鼠标屏偏上居中
  2. 搜索框 + 列表区（可用 NSTableView）；section header 样式
  3. 默认最多 10 行数据区 +「显示全部」/「显示较少」
  4. show/hide fade；先用占位行验证布局
- **验收**：`./Scripts/build.sh`；热键可弹出空/占位面板
- **禁止**：真实候选/模糊（Q3）；raiseOnly（Q4）

---

### Q3 — 候选 + 多屏 section + 模糊过滤（P0）

- **改**：
  - `MLChipLocatorController`（组装）
  - 可选 `Sources/Core/ml_fuzzy.c/.h` 或 ObjC 打分辅助
- **做**：
  1. 并集：各屏 RunningWindow + 主屏 NoWindow + 各屏 PinnedOnly；尊重 HideChip
  2. 打开时快照 focusScreenID；本屏 section 在前；他屏按屏级 MRU
  3. 空查询 = MRU 序；有查询 = 前后模糊（前缀/子串/子序列）+ 保留分屏 section
  4. 行文案：窗标题 / 应用名 / 「运行中」「钉住」；图标走 TaskbarIconCache
- **验收**：`./Scripts/build.sh`
- **禁止**：soft-min；改 merge 规则本身（只读）

---

### Q4 — raiseOnly + 键盘接线（P0）

- **改**：
  - `MLTaskbarController+WindowActions`（raiseOnly API）
  - `MLChipLocatorPanel` / Controller 键处理
- **做**：
  1. `raiseOnly`：RunningWindow 只 raise+activate；NoWindow/Pin 走 activate+open；**禁止** soft-min
  2. 打开 → 高亮第 1 条并 raiseOnly
  3. ↑↓ 移动并 raiseOnly；点击行 = Enter
  4. Enter 确认关面板；Esc 有字清空否则关闭；悬停不前置
  5. soft-min / peek frozen 时 restore 路径与芯片点击一致的 unfreeze 需求
- **验收**：`./Scripts/build.sh`
- **禁止**：改任务栏左键默认 soft-min 语义

---

### Q5 — Overlay 互斥与收尾（P0）

- **改**：
  - AppDelegate / Overlay / Locator 互斥
  - Strings、空态「无匹配」
  - `doc/00-overview.md` / `10-taskbar` 若需标完成
  - 可选 peek smoke 无强制新断言
- **做**：
  1. Locator show → hide Overlay；快捷键 toggle
  2. 面板打开期间 snapshot 变化时温和刷新列表
  3. 全卡回归 `./Scripts/build.sh`；`./Scripts/taskbar_peek_smoke.sh` 仍绿
- **验收**：build + peek smoke
- **禁止**：新第三方依赖；扩大非目标范围
