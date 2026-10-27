# 22 — 任务栏「快速定位芯片」（Chip Locator / Q-Plan）

> 全局快捷键唤起类似 Cursor ⌘P 的浮动面板：搜索任务芯片，按「当前屏优先 + 最近激活」排序，方向键预览前置窗口。  
> **决策已确认**（2026-10-27：全部按 §12 推荐）。任务卡：[22-plan.md](./22-plan.md)；自动化规则：`.cursor/rules/taskbar-chip-locator-q-plan.mdc`。

相关：任务栏基线 [10-taskbar.md](./10-taskbar.md)、右键菜单 [11-taskbar-context-menu.md](./11-taskbar-context-menu.md)、无窗仍运行 [20-taskbar-running-no-window.md](./20-taskbar-running-no-window.md)、隐藏芯片 [21-taskbar-hide-chip.md](./21-taskbar-hide-chip.md)、配置 [06-config-schema.md](./06-config-schema.md)、peek 不变量 `.cursor/rules/taskbar-peek-invariants.mdc`。

---

## 0. 需求摘要（你的设想 → 产品一句话）

**Chip Locator =「用键盘在多屏任务栏芯片里快速找到并前置某个窗口」**，不是 Launchpad Overlay，也不是系统 Mission Control。

你提出的 6 点均纳入 MVP；本文补充：激活语义、候选范围、MRU 数据、快捷键体系、边界场景与 UI 规范。**标 ❓ 的条目请你拍板。**

---

## 1. 目标与非目标

### 1.1 目标（MVP）

| # | 能力 | 行为 |
|---|------|------|
| 1 | 全局快捷键 | 弹出浮动定位面板（默认建议见 §8；Prefs 可改） |
| 2 | 搜索框 + 列表 | 上方输入；下方候选芯片列表 |
| 3 | 多屏分组 | **优先列出鼠标所在屏**上的芯片；其后按显示器分组列出其余屏；组内按 **最近激活到前台** 降序 |
| 4 | 模糊搜索 | 对应用名 + 窗口标题做前后模糊匹配（见 §6） |
| 5 | 多窗标题 | 与任务栏芯片一致：每个窗口一条，标题为芯片上已显示文字（CG→AX  enrichment + 去掉 `" — AppName"`） |
| 6 | 默认 10 条 | 初始最多 10 条；底部「显示全部」展开为完整列表（仍可滚动） |
| 7 | 键盘导航 | ↑↓ 移动焦点；**焦点落到哪一行，就把对应窗口前置**（预览式）；Enter 确认关闭；Esc：有字先清空，再关 |

### 1.2 非目标（首期不做）

- 缩略图 / 窗口预览图
- 在面板内关闭 / 最小化 / 钉住 / 隐藏芯片（继续用任务栏右键）
- 替代 Overlay 应用启动器（不搜未运行、未钉住的磁盘应用）
- 拼音首字母 / 全拼（配置里 `search.pinyin` 仍为 stub；本功能不绑死拼音）
- 第三方模糊库（Fuse 等）；自写轻量打分即可
- 改 peek / soft-min / 音频角标 / HideChip 既有语义
- 触摸板手势唤起

---

## 2. 产品语义与交互优化建议

### 2.1 与任务栏左键的关键差异（必须）

任务栏 `RunningWindow` 左键：若已是最前 → **软最小化**。  
Locator **方向键预览 / Enter 确认** 若走同一路径，用户一按 ↓ 就会把当前前台窗 soft-min 掉——不可接受。

| 入口 | 行为 |
|------|------|
| Locator 行焦点变化（↑↓ / 鼠标悬停可选） | **仅 raise + activate**，永不 soft-min |
| Locator Enter | 同上 raise；然后 **关闭面板** |
| Locator Esc / 点空白关闭 | 关闭面板；**不**撤销刚才的前置（与 ⌘Tab 一致） |

实现上新增 `raiseOnly` / `activateWithoutSoftMinToggle` 路径，复用现有 `raiseAndFocusWindowForItem:` + `activateApplicationForItem:`，**禁止**调用完整 `activateOrLaunchItem:`。

### 2.2 推荐的交互细化（相对你的草案）

| 点 | 建议 | 理由 |
|----|------|------|
| 打开时默认焦点 | 搜索框空；列表高亮 **第 1 条**（当前屏 MRU 顶），并立即前置该窗 | 已确认 |
| 鼠标悬停 | **悬停不前置**；点击行 = Enter | 已确认 |
| 输入时重置 | 查询变化 → 列表重算 → 高亮第 1 条并前置 | 与 ⌘P 一致 |
| 「显示全部」 | 展开后仍保持当前高亮；高度上限约 60–70% 屏高，其余滚动 | 避免占满屏 |
| 空查询 | 显示 MRU 列表（分组） | 「最近激活」 |
| 无匹配 | 列表区居中弱文案「无匹配」；不前置任何窗 | — |
| 与 Overlay 同时 | Locator 打开 → **先 hide Overlay** | 避免双层搜索抢键 |
| 与任务栏 peek | 打开/关闭 **不** arm/unfreeze peek；选中 soft-min 窗走与芯片点击相同的 restore/unfreeze | peek 不变量 |

### 2.3 相对 ⌘Tab / Mission Control 的定位

- ⌘Tab：按 **应用**；Locator：按 **窗口芯片**（Cursor 多窗各一条）。
- Mission Control：空间总览；Locator：键盘 + 标题搜索，轻量常驻。

---

## 3. 候选集：列什么、不列什么

数据源建议：**各屏 `MLTaskbarScreenBar` 当前 items 的并集**，并与 snapshot 对齐；不要只读「画得下的」子集时另造一套身份。注意 `fitItems` 可能因宽度丢掉未钉住芯片——Locator 应能找到这些「栏上挤掉但仍存在的窗口」。

**推荐权威源**：`MLRunningAppsSnapshot.windows`（按屏归属 + affinity）+ 主屏 idle 芯片规则产出的 `RunningNoWindow` / 各屏 `PinnedOnly`。

### 3.1 默认包含（建议）

| Kind | 是否进 Locator | 行展示 | 激活 |
|------|----------------|--------|------|
| `RunningWindow` | ✅ 始终 | 图标 + **窗口标题**（与芯片同算法）+ 副文案应用名（可选） | raiseOnly |
| `RunningNoWindow` | ✅ 包含 | 图标 + 应用名 + 弱标签「运行中」 | activate + open（与 N-Plan 左键一致，无 soft-min） |
| `PinnedOnly` | ✅ 包含 | 图标 + 应用名 + 弱标签「钉住」 | 启动 / activate（与 Pin 左键一致） |

### 3.2 默认排除 / 特殊

| 情况 | 建议 |
|------|------|
| HideChip 且全局无窗 | 任务栏已无 idle 芯片 → Locator **也不列**（与「隐藏占位」一致） |
| HideChip 但有窗 | 窗口芯片照列 |
| soft-min / 系统最小化 | **仍列**；标题可加弱状态「已最小化」（可选 MVP+） |
| MeoLaunch 自身窗 | 不列（与 monitor 过滤一致） |
| 音频角标状态 | 不单独成行；可选在行尾画小喇叭（非必须） |

### 3.3 身份键

一行 = 一个芯片身份：

- 有窗：`windowID`（主）+ `path`
- 无窗 / Pin：`path` + kind（`windowID == 0`）

同一 Cursor 多窗 = 多行，标题各不相同——满足你的第 4 点。

---

## 4. 多显示器排序（落实你的第 2 点）

### 4.1 「当前屏」定义

与 Overlay 一致：`+[MLConfigStore screenUnderMouse]`（`NSEvent.mouseLocation` ∈ `NSScreen.frame`）。  
打开面板瞬间快照 `focusScreenID`；面板存活期间 **不**随鼠标挪屏改组（避免列表乱跳）。

### 4.2 列表结构（示意）

```text
┌─────────────────────────────────────────┐
│ 🔍  搜索窗口或应用…            ⌘⇧Space  │
├─────────────────────────────────────────┤
│ 本显示器 · 内置视网膜显示器              │  ← section header
│   ▸ Cursor — main.swift                 │  ← 高亮 + 已前置
│     Cursor — Agent                      │
│     Safari — Apple                      │
│ ─────────────────────────────────────── │
│ 显示器 · DELL U2723QE                   │
│     Finder — 文稿                       │
│     钉住 · Visual Studio Code           │
│ …                                       │
│          显示全部（还有 6 项）           │
└─────────────────────────────────────────┘
```

规则：

1. **Section 1**：`focusScreenID` 上的候选，组内按 MRU 降序。  
2. **后续 Section**：其他屏，屏与屏之间按「该屏上最近一次有窗口被激活」的屏级 MRU；若无则主屏优先，其余按 `NSScreen` 排列。  
3. Section 标题：`NSScreen.localizedName`（与 Prefs 一致）；可附分辨率弱化显示（非必须）。  
4. **全局扁平行列表**仍共享一个键盘焦点索引（跨 section 连续 ↑↓）。

### 4.3 跨屏前置

选中次屏窗口 → raise 到该窗所在 Space/屏（系统行为）；面板本身留在 **打开时的鼠标屏** 居中偏上（见 §7），不跟着窗口跳屏。

---

## 5. 最近激活顺序（MRU）— 现状缺口与方案

### 5.1 现状

仓库已有 `frontmostTrackedWindowID`、`seenOrder`（**任务栏排列序**，非激活序）。**没有**「最后激活到前台」历史栈。

### 5.2 建议新增 `MLWindowActivationMRU`

| 项 | 约定 |
|----|------|
| 触发 | `MLRunningAppsFrontWindowDidChangeNotification` / frontmost 变化；以及 Locator / 任务栏成功 raise 后主动 `touch` |
| 记录 | 有序 `windowID` 列表（新在前）；附带 `path`、`screenID`（touch 时） |
| 容量 | 例如最多 64；进程退出 / 窗关闭时剔除 |
| 持久化 | **不持久化**（会话级；重启后退化为当前屏芯片 + seenOrder） |
| Pin / NoWindow | 用 `path` 作为 key 的次级 MRU，或排在有窗 MRU 之后按显示名 |

组内排序键：`mruIndex` 升序；未进过 MRU 的条目接在后面，稳定次序可用 `seenOrder` 或标题。

---

## 6. 搜索（落实「前后模糊匹配」）

### 6.1 匹配字段（每行）

1. 窗口标题（芯片 title，≤40 字截断版；搜索可用 **截断前** 全标题若 monitor 仍持有）  
2. 应用显示名  
3. 可选：`path` lastComponent / bundleID 短名（高级，可降权）

### 6.2 「前后模糊」推荐算法（无第三方）

避免只做中缀 substring（Overlay 的 `ml_filter_apply`），建议轻量 **子序列 + 加分**：

| 规则 | 分 |
|------|-----|
| 完整等于（忽略大小写） | 最高 |
| 前缀匹配 | 高 |
| 连续子串（中缀） | 中高 |
| 子序列（`abc` 匹配 `a…b…c`） | 中 |
| 仅应用名命中 / 仅标题命中 | 微调 |

查询为空 → 不做过滤，只按 §4 排序。  
大小写：Unicode case-fold；不强制拼音。

### 6.3 有查询时的分组

**已确认 A**：有查询时仍保留「本屏 / 他屏」section，section 内按匹配分 + MRU。

---

## 7. UI 设计（美化规范）

整体气质对齐现有任务栏「浅雾芯片」+ Overlay 材质，避免厚重卡片堆叠与默认「紫渐变 AI 风」。

### 7.1 窗口形态

| 项 | 规范 |
|----|------|
| 类型 | `NSPanel`：**可激活**（便于输入与方向键）；level ≥ `NSFloatingWindowLevel`，高于任务栏 |
| 材质 | `NSVisualEffectView`：`Sidebar` 或 `HUDWindow` / `Menu`；vibrant light 跟随系统 |
| 圆角 | 12–14pt；细边框 `white 0.35` / 暗色模式适配 |
| 阴影 | 单层柔和影，避免多层 glow |
| 尺寸 | 宽 **420–480pt**；默认高度约 **标题+10 行**；展开全部后 maxHeight ≈ 屏可见高 × 0.65 |
| 位置 | 打开时鼠标所在屏：水平居中，垂直约 **屏高 22%–28%** 处（偏上，类似 Spotlight） |
| 动画 | 120–160ms fade+轻微 scale(0.98→1)；关闭对称；尊重「减少动态效果」 |

### 7.2 搜索区

- 单行；左侧放大镜 SF Symbol（或与 Overlay 一致的简洁字形）。  
- 占位：「搜索窗口或应用」。  
- 右侧可弱显当前快捷键（Prefs 变更后刷新）。  
- **避免** Overlay 曾踩过的 `wantsLayer` + VisualEffect 幽灵面板坑；文本框用法参考 `MLSearchField` 经验。

### 7.3 列表行

| 元素 | 规范 |
|------|------|
| 高 | 36–40pt |
| 图标 | 复用 `MLTaskbarIconCache` 32²，左 10pt |
| 主标题 | 13pt Medium；窗口 title 或 app 名 |
| 副标题 | 11pt 次要色：应用名（当主标题是窗标题时）或「运行中 / 钉住」 |
| 高亮行 | 填充接近任务栏 active `#D8E6FA`；圆角 8pt inset |
| Section | 11pt Semibold 次要色 + 上间距；非可选中 |
| 「显示全部」 | 居中文字按钮 / 伪行；展开后改为「显示较少」或消失 |

### 7.4 深色模式

跟随 `NSAppearance`；高亮改用更高对比蓝灰，正文主次色对调。不强制单独主题引擎。

### 7.5 无障碍（MVP 轻量）

- 面板 `accessibilityRole` = dialog；列表为 list。  
- VoiceOver：行列读「标题，应用名，显示器」。  
- 完整 AX 可放后期。

---

## 8. 快捷键与配置

### 8.1 现状

`MLHotKeyManager` 目前 **只注册 1 个** Carbon HotKey（唤起 Overlay）。Locator 需要 **第二路** `EventHotKeyID` + Prefs 第二行录制器。

### 8.2 默认快捷键（已确认）

**默认：⌃⌘Space**（`key_code` = 49 / Space，modifiers = control + command）。

Prefs：

```text
唤起应用网格:  [录制]  ☑ 启用
快速定位任务芯片: [录制]  ☑ 启用
```

`config.json`：

```json
"hotkey_chip_locator": {
  "enabled": true,
  "key_code": 49,
  "modifiers": ["control", "command"]
}
```

注册失败 → 日志 + Prefs 提示「快捷键被占用」。

### 8.3 面板内按键

| 键 | 行为 |
|----|------|
| 字符 | 交给搜索框 |
| ↑↓ | 移动高亮并 raiseOnly |
| Enter / ⌘Enter | 确认并关闭 |
| Esc | 有查询字 → 先清空；已空 → 关闭面板（对齐 Overlay） |
| ⌘A / 常见编辑 | 搜索框标准行为 |
| Tab | 可忽略或在「搜索 ↔ 列表」间切换（非必须） |

方向键在 `NSTextField` 为 firstResponder 时需 **拦截 field editor**，勿把 ↓ 留给插入点——专用 `keyDown` / monitor。

---

## 9. 架构草图

```text
AppDelegate
  ├── MLHotKeyManager          扩展：id=1 Overlay，id=2 Locator
  ├── MLOverlayController      互斥：Locator show → overlay hide
  └── MLTaskbarController
          ├── MLWindowActivationMRU      新增
          ├── MLChipLocatorController    新增：组装候选、排序、过滤
          └── MLChipLocatorPanel         新增：NSPanel + 搜索 + 列表 view
                    └── raiseOnly → +WindowActions（新 API）
```

原则：

- 不引入第三方库。  
- 列表可用单 `NSView` drawRect（对齐任务栏控内存）或轻量 `NSTableView`；候选 ≤ 几十行，**NSTableView 可接受**。  
- 图标走 `MLTaskbarIconCache`，禁止拉 128px Overlay 图标进面板常驻。

---

## 10. 边界与未尽场景（你可能没写到的）

| 场景 | 建议行为 |
|------|----------|
| 只有一屏 | 无「他屏」section；或不显示屏名 header |
| 当前屏无芯片 | Section 空则直接列他屏；或文案「本屏无窗口」 |
| 全屏 / 沉浸式 app | 面板仍浮层；raise 可能受 Spaces 限制——尽力而为 |
| Stage Manager | 不特殊处理；依赖系统 raise |
| 无障碍权限不足 | 标题可能只剩 app 名；raise 可能弱于 AX 路径——与任务栏同降级 |
| 屏幕录制未授权 | CG 标题空 → 已有 AX 回退；Prefs 可提示 |
| 面板打开时窗口关闭 | 该行从列表移除；高亮落到下一行并前置 |
| 面板打开时新窗出现 | 低频刷新即可（监听 snapshot 通知）；避免每帧抖 |
| 快速连按快捷键 | toggle：开→关 |
| 输入法组合中 | 方向键勿打断 marked text（有 marked 时 ↓ 不导航） |
| 多 Space | 只列当前用户会话可见/monitor 已跟踪窗；不跨用户 |
| 「显示全部」后搜索 | 过滤在全量候选上；默认 10 是 **展示** 上限不是数据上限 |
| 与音频角标 | 无关；前置窗不等于点角标 |
| 内存 | 面板 hide 后释放 view 树或置 Cold；勿常驻大图 |

---

## 11. 验收标准（确认后写入 plan）

1. 快捷键在任意前台 app 下可唤起 / 再按关闭。  
2. 双屏：鼠标在屏 B → 屏 B 芯片在上；屏名正确。  
3. Cursor 两窗 → 两行，标题与任务栏芯片文字一致。  
4. 查询 `mai` 可命中 `main.swift`（子串/模糊）；大小写不敏感。  
5. 默认 ≤10 行 +「显示全部」可展开。  
6. ↑↓ 切换时目标窗前置，且 **不会** 把已是前台的窗 soft-min。  
7. Enter 关闭面板；Esc 关闭；Peek / 多屏 affinity 回归：`./Scripts/taskbar_peek_smoke.sh` 通过。  
8. `./Scripts/build.sh` 通过。

---

## 12. 已确认决策

| ID | 议题 | 决定 |
|----|------|------|
| Q1 | 默认快捷键 | ⌃⌘Space |
| Q2 | 打开面板时立即前置第 1 条 | 是 |
| Q3 | Esc 还原打开前的前台窗 | 否 |
| Q4 | 包含 `RunningNoWindow` / `PinnedOnly` | 是 |
| Q5 | 有搜索字时分组 | A（保留分屏 section） |
| Q6 | 鼠标悬停前置 | 否 |
| Q7 | Esc 先清空再关闭 | 是 |
| Q8 | MRU 落盘 | 否（会话级） |
| Q9 | 面板可激活 | 是 |
| Q10 | 代号 | **Q-Plan**；`22-plan.md` |

---

## 13. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-10-27 | 初稿 |
| 2026-10-27 | 全部按推荐确认；产出 22-plan 并开工 |
