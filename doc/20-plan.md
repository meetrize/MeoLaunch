# 20-Plan — 任务栏「无窗仍运行」芯片（自动化任务卡）

> **已全部 done。** 用户说「继续」「全自动开发」「做 N 计划」「按 20-plan」「无窗运行」「RunningNoWindow」等 → 读下方 **Status**（应无 pending）。  
> 设计：[20-taskbar-running-no-window.md](./20-taskbar-running-no-window.md)

## Status

| ID | 状态 | 备注 |
|----|------|------|
| N0 | done | 设计/rule/10-taskbar/overview 落盘；build+peek smoke 18 OK |
| N1 | done | 主屏合并 RunningNoWindow；Pin 去重；fitItems 芯片宽；build OK |
| N2 | done | 虚线淡化绘制 + activate/open；菜单 hasWindow=NO；音频可用；build OK |
| N3 | done | NoWindow 禁拖；commit 拒 NoWindow；smoke +1（19）；11-taskbar 同步 |

## 执行协议

1. **一次一卡**；验收后可立即下一张。  
2. 每卡结束：`./Scripts/build.sh` 必须通过。  
3. 禁止第三方库；不改 `doc/00`–`doc/06` 正文（overview 索引除外）。  
4. Commit 仅在用户明确要求时；message 用简体中文。  
5. 改完把 Status 标 `done` 并写备注。  
6. 遵守 peek 不变量：`.cursor/rules/taskbar-peek-invariants.mdc`。  
7. NoWindow **仅主屏**；`windowChipCount` 不计 NoWindow。  
8. 左键 NoWindow = activate + open；禁止 soft-min。

---

## 任务卡

### N0 — 设计落盘 + 回归基线（P0）

- **改**：
  - `doc/20-taskbar-running-no-window.md`（新建）
  - `doc/20-plan.md`（本文件）
  - `.cursor/rules/taskbar-running-no-window-n-plan.mdc`
  - `doc/10-taskbar.md`（合并/视觉/非目标与 NoWindow 对齐）
  - `doc/00-overview.md`（索引链接）
- **做**：
  1. 落盘完整设计与任务卡
  2. 更新 10-taskbar：允许主屏产出 `RunningNoWindow`
  3. 跑基线构建与 peek smoke
- **验收**：
  - `./Scripts/build.sh`
  - `./Scripts/taskbar_peek_smoke.sh`
- **禁止**：改合并/绘制实现代码（本卡仅文档与基线）

---

### N1 — 合并层产出 `RunningNoWindow`（P0）

- **改**：
  - `Sources/UI/MLTaskbarController+Items.m`（`rebuildItemsForBar:`、必要时 `fitItems`）
- **做**：
  1. 主屏：`globalNoWindow = runningAppPaths ∖ pathsWithVisibleWindows`（标准化 path）
  2. 主屏钉住且 ∈ globalNoWindow → 跳过 `PinnedOnly`，改由 NoWindow（`pinned=YES`）
  3. 追加 NoWindow：先 pin 序，再 running 序；硬顶 16；钉住优先
  4. 次屏不产出 NoWindow
  5. `fitItems`：NoWindow 用芯片宽（非 `pinnedW`）
- **验收**：
  - `./Scripts/build.sh`
- **禁止**：改绘制样式；引入第三方库

---

### N2 — 绘制 + 点击 + 菜单（P0）

- **改**：
  - `Sources/UI/MLTaskbarView.m`（及必要时 `.h`）
  - `Sources/UI/MLTaskbarController+WindowActions.m`
- **做**：
  1. `drawRect`：NoWindow 淡化 + 虚线描边；ghost 一致
  2. `activateOrLaunchItem:`：NoWindow 同 PinnedOnly（activate + open）
  3. 右键：`hasWindow` 仍 false → 窗口操作禁用；Pin/Quit/音频可用
- **验收**：
  - `./Scripts/build.sh`
- **禁止**：改 peek freeze 语义；角标点击走整芯片 activate

---

### N3 — Peek / 拖拽 / 文档收尾（P0）

- **改**：
  - 必要时 `MLTaskbarController+Drag.m`、`Tools/taskbar_peek_smoke.m`
  - `doc/20-plan.md` Status
- **做**：
  1. 确认 `windowChipCount*` 只计 `RunningWindow`
  2. 拖拽：NoWindow 在窗口区，禁止入 Pin 区
  3. peek smoke 全绿；必要时补 headless 断言
  4. Status 全 `done`
- **验收**：
  - `./Scripts/build.sh`
  - `./Scripts/taskbar_peek_smoke.sh`
- **禁止**：改变「全关窗 ≠ 自动 peek」不变量
