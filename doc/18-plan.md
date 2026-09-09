# 18-Plan — Overlay 应用图标右键菜单（自动化任务卡）

> **已全部 done。** 当前自动化队列真源改为 [19-plan.md](./19-plan.md)（任务栏声音指示）。  
> 若需回顾本里程碑：用户说「按 18-plan」「Overlay 右键」等 → 以本文件 Status 为准（应无 pending）。  
> 设计：[18-overlay-icon-context-menu.md](./18-overlay-icon-context-menu.md)

## Status

| ID | 状态 | 备注 |
|----|------|------|
| O0 | done | 菜单骨架 + 打开 + 访达 + 钉住；pinStore 注入 |
| O1 | done | move path API +「移动到」二级菜单 |
| O2 | done | 确认 + trash 主包 + unpin + rescan |
| O3 | done | 卸载器探测 + 残留勾选列表（默认不勾） |

## 执行协议

1. **一次一卡**；验收后可立即下一张。  
2. 每卡结束：`./Scripts/build.sh` 必须通过。  
3. 禁止第三方库；不改 `doc/00`–`doc/06` 正文（overview 索引除外）。  
4. C 头变更同步 `doc/04-implementation.md` 相关节。  
5. Commit 仅在用户明确要求时；message 用简体中文。  
6. 改完把 Status 标 `done` 并写备注。  
7. 遵守 peek 不变量：`.cursor/rules/taskbar-peek-invariants.mdc`（本功能原则上不改 Taskbar 逻辑）。  
8. 镜像任务栏菜单模式：View 组菜单 + enum，Controller 执行。

---

## 任务卡

### O0 — 菜单骨架 + 打开 / 访达 / 钉住（P0）

- **改**：
  - `Sources/UI/MLGridView.h/.m`
  - `Sources/UI/MLOverlayController.h/.m`
  - `Sources/App/AppDelegate.m`
  - `Sources/System/MLStrings.m`（及 `.h` 若需）
- **做**：
  1. 定义 `MLOverlayIconMenuAction`、`MLOverlayIconMenuFlags`；扩展 `MLGridViewDelegate`
  2. `rightMouseDown:`：`visibleSlotAtPoint:`；仅应用格；`_dragActive` 时忽略
  3. 弹出菜单：「打开」「在访达中显示」、分隔、「固定到任务栏」/「从任务栏取消固定」
  4. Open → 复用现有 `didActivateAppAtPath:` / `MLAppLauncher` 管线
  5. Reveal → `activateFileViewerSelectingURLs:` 选中 `.app`
  6. Overlay 注入 `MLTaskbarPinStore`；Pin toggle → `pinPath:` / `unpinPath:`；弹出时读 `isPinned:`
  7. 文件夹格不弹菜单；搜索模式应用格可用
- **验收**：
  - `./Scripts/build.sh`
  - 手测：右键打开、访达高亮、钉住后 Pin 区出现、再取消固定
- **禁止**：实现卸载 / 移动到；改 peek；引入第三方库

---

### O1 —「移动到」二级菜单 + layout API（P0）

- **改**：
  - `Sources/Core/ml_layout.h/.c`
  - `Sources/System/MLLayoutStore.h/.m`
  - `Sources/UI/MLGridView.m`（子菜单）
  - `Sources/UI/MLOverlayController.m`
  - `doc/04-implementation.md`（C API 节）
- **做**：
  1. Core：`ml_layout_move_app_path_to_folder`（从 root 或其他 folder 摘出 path，append 到目标 folder；维护 path 全局唯一；触发原组 dissolve）
  2. Store：`rootFolderInfos`、`moveAppAtPath:intoFolderId:` + `scheduleSave` / 通知
  3. 菜单「移动到 ▸」列出根级文件夹名（空名用默认「文件夹」）；无文件夹则禁用
  4. 排除应用当前所在 folderId；点组名后 reload 网格
  5. 主网格 / 文件夹内 / 搜索三种模式均按 **path** 工作
- **验收**：
  - `./Scripts/build.sh`；若有 core 单测/冒烟则跑 `./Scripts/build_core.sh`
  - 手测：移入组后网格与 `layout.json` 正确；原组只剩 0/1 个时 dissolve
- **禁止**：子菜单「新建分组」；嵌套文件夹

---

### O2 — 卸载主路径：确认 + 废纸篓 + 同步（P0）

- **改**：
  - `Sources/System/MLAppUninstaller.h/.m`（新建）
  - `Sources/UI/MLOverlayController.m`（确认 Alert）
  - `Sources/App/AppDelegate.m`（rescan 钩子，按需）
  - `Scripts/build.sh` / `project.yml`（登记新源文件）
  - `Sources/System/MLStrings.m`
- **做**：
  1. 门禁：`/System`、自身 bundle 等 → 菜单项禁用
  2. 「卸载…」→ 确认 Alert（应用名 +「将移入废纸篓，可还原」）
  3. `trashItemAtURL:` / `recycleURLs:` 移主包；失败 Alert
  4. 成功：unpin（若钉住）→ 触发索引 rescan → `layoutStore syncWithAppIndex:` → overlay reload
  5. 运行中应用：确认文案提示可能失败；失败不改 layout
- **验收**：
  - `./Scripts/build.sh`
  - 手测：用户目录/可写 Applications 下测试拷贝可卸；系统 App 禁用；卸后网格消失且 pin 清除
- **禁止**：默认硬删；扫残留（留给 O3）；sudo

---

### O3 — 卸载器探测 + 残留提示（P1）

- **改**：`MLAppUninstaller`、`MLOverlayController`、`MLStrings`
- **做**：
  1. 探测旁路/包内专用卸载器；若存在，优先 Alert：「打开卸载程序」/「仍移入废纸篓…」/「取消」
  2. 按 bundle id + 显示名浅扫用户域常见残留路径（见设计 §3.5.3）
  3. 展示残留列表；**默认不勾选**；用户勾选的项与主包一并 `trash`
  4. 扫描放后台；超时则跳过残留 UI，仍允许只卸主包
  5. 高置信匹配；禁止全盘 / 模糊删
- **验收**：
  - `./Scripts/build.sh`
  - 手测：有卸载器的应用（或造测试夹具）出现提示；残留列表可勾选；取消不删
- **禁止**：自动删未勾选残留；默认清理 `/Library` 系统域

---

## 建议手测清单（全部 done 后）

1. 应用右键五类能力均可用；文件夹无菜单。  
2. 钉住 ↔ 任务栏 Pin 区一致。  
3. 移入组 + 持久化 + dissolve。  
4. 卸载门禁 / 废纸篓 / 卸载器与残留提示。  
5. 拖拽排序与合并仍正常；中英文文案。  
6. `./Scripts/build.sh` 通过。
