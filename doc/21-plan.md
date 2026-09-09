# 21-Plan — 任务栏「隐藏任务芯片」（自动化任务卡）

> **已全部 done。** 用户说「继续」「全自动开发」「做 H 计划」「按 21-plan」「隐藏任务芯片」「HideChip」等 → 读下方 **Status**（应无 pending）。  
> 设计：[21-taskbar-hide-chip.md](./21-taskbar-hide-chip.md)

## Status

| ID | 状态 | 备注 |
|----|------|------|
| H0 | done | 设计/rule/overview/10·11 交叉引用落盘；本卡不改实现 |
| H1 | done | HideStore + init 注入 + hideDidChange→rebuild；build OK |
| H2 | done | rebuild 抑制 hidden∩无窗的 Pin/NoWindow；有窗不受影响；build OK |
| H3 | done | 右键隐藏/显示 + Strings；build OK |
| H4 | done | peek smoke +1（20）；HideStore 链入 smoke；全绿 |

## 执行协议

1. **一次一卡**；验收后可立即下一张。  
2. 每卡结束：`./Scripts/build.sh` 必须通过。  
3. 禁止第三方库；不改 `doc/00`–`doc/06` 正文（overview 索引除外）。  
4. Commit 仅在用户明确要求时；message 用简体中文。  
5. 改完把 Status 标 `done` 并写备注。  
6. 遵守 peek 不变量：`.cursor/rules/taskbar-peek-invariants.mdc`。  
7. **有窗芯片永不因 hidden 被丢弃**；仅抑制无窗时的 `RunningNoWindow` / `PinnedOnly`。  
8. 隐藏按 app `path`（与 pin 同粒度）；不引入新 `kind`。

---

## 任务卡

### H0 — 设计落盘 + 交叉引用（P0）

- **改**：
  - `doc/21-taskbar-hide-chip.md`（新建）
  - `doc/21-plan.md`（本文件）
  - `.cursor/rules/taskbar-hide-chip-h-plan.mdc`
  - `doc/00-overview.md`（索引）
  - `doc/10-taskbar.md` / `doc/11-taskbar-context-menu.md`（扩展说明 + 链接）
- **做**：
  1. 落盘完整设计与任务卡、自动化 rule
  2. 10/11 注明「隐藏任务芯片」语义与菜单项位置
- **验收**：文档齐全；本卡**不改**合并/菜单实现代码
- **禁止**：实现 HideStore；改 peek

---

### H1 — `MLTaskbarHideStore` + 注入（P0）

- **改**：
  - `Sources/System/MLTaskbarHideStore.h/.m`（新建）
  - `Sources/UI/MLTaskbarController.h`（及 init / AppDelegate 注入）
  - `Scripts/build.sh` / `project.yml`（若需登记）
- **做**：
  1. JSON 读写 `taskbar_hidden_chips.json`；path 标准化匹配
  2. `hidePath:` / `unhidePath:` / `isHidden:` / `scheduleSave`
  3. 变更发 `MLTaskbarHideDidChangeNotification`；Controller 监听后 rebuild
  4. AppDelegate 与 pinStore 并列创建并注入
- **验收**：
  - `./Scripts/build.sh`
- **禁止**：改菜单 UI；改 merge 过滤（留给 H2）

---

### H2 — 合并层：无窗时抑制 idle 芯片（P0）

- **改**：
  - `Sources/UI/MLTaskbarController+Items.m`（`rebuildItemsForBar:`）
- **做**：
  1. `suppressIdleChip(path) = isHidden && ∉ pathsWithVisibleWindows`
  2. `PinnedOnly` 与 `RunningNoWindow` 候选均跳过 suppress
  3. `RunningWindow` **不受** hidden 影响
  4. 主屏 / 次屏同一判定
- **验收**：
  - `./Scripts/build.sh`
  - 手测（若可）：隐藏后关光窗 → 无 NoWindow/Pin；再开窗 → 窗口芯片仍在
- **禁止**：改绘制样式；改 peek freeze

---

### H3 — 右键「隐藏 / 显示任务芯片」（P0）

- **改**：
  - `Sources/UI/MLTaskbarView.h/.m`（enum + 菜单项）
  - `Sources/UI/MLTaskbarController+WindowActions.m`（及 Categories 若需）
  - `Sources/System/MLStrings.m`
- **做**：
  1. `MLTaskbarMenuActionHideChipToggle`；插在钉住与 MeoLaunch（/音频）之间
  2. 未隐藏 →「隐藏任务芯片」；已隐藏 →「显示任务芯片」
  3. 有 `path` 的芯片均可用（含 Pin / NoWindow / Window）
  4. toggle store → 通知 → rebuild
- **验收**：
  - `./Scripts/build.sh`
  - 手测：隐藏/显示文案切换；同 app 多窗菜单一致
- **禁止**：Prefs 隐藏列表；改左键语义

---

### H4 — 回归与文档收尾（P0）

- **改**：
  - 必要时 `Tools/taskbar_peek_smoke.m`（headless：hidden path 不进入 NoWindow 集合的断言，若易测）
  - `doc/21-plan.md` Status；设计文档若有实现偏差则回写
- **做**：
  1. peek smoke 全绿；确认隐藏不破坏「全关窗 ≠ 自动 peek」
  2. Status 全 `done`
- **验收**：
  - `./Scripts/build.sh`
  - `./Scripts/taskbar_peek_smoke.sh`
- **禁止**：改变 peek 用户武装语义；引入 Prefs（除非用户另开需求）
