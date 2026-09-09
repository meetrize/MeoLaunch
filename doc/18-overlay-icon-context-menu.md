# 18 — Overlay 应用图标右键菜单（技术方案）

> 状态：**已实现**（O0–O3，2026-09-08）  
> 关联：[08-layout-folders.md](./08-layout-folders.md)、[10-taskbar.md](./10-taskbar.md)、[11-taskbar-context-menu.md](./11-taskbar-context-menu.md)  
> 任务卡：[18-plan.md](./18-plan.md)  
> 日期：2026-09-08

## 1. 目标与现状

### 现状

| 能力 | Overlay 网格 | 任务栏 |
|------|--------------|--------|
| 左键打开应用 | ✅ `MLAppLauncher` | ✅ |
| 右键菜单 | ❌ 无 `rightMouseDown` | ✅ `MLTaskbarView` + enum |
| 钉到任务栏 | ❌ | ✅ `MLTaskbarPinStore` |
| 分组（文件夹） | ✅ 拖拽合并 / `layout.json` | —（与 pin 无关） |
| 在访达中显示 | ❌ | 文档二期，未实现 |
| 卸载 | ❌ | ❌ |

Overlay 图标仅支持左键/键盘激活与拖拽重排；菜单交互应**镜像任务栏**的 View → enum → Controller 模式，不把业务塞进 `MLGridView`。

### 目标菜单（应用图标）

```text
打开
在访达中显示
────────
固定到任务栏          ← 已钉住则改为「从任务栏取消固定」或禁用「固定」
────────
移动到 ▸
    效率
    工具
    …                 ← 现有 layout 根级文件夹名；无分组则禁用父项
────────
卸载…
```

### 非目标（本期不做）

- 文件夹图标右键（仅应用格；文件夹继续左键进入）
- 右键「新建分组 / 重命名分组」
- 任务栏菜单补「在访达中显示」（可复用 helper，但不改任务栏菜单范围）
- 永久 `rm`、sudo、深度 `/Library` 清扫、Homebrew `brew uninstall --zap`
- 卸载后自动删除全部残留（默认只提示；可选勾选进废纸篓，见 §5）
- 嵌套文件夹、跨机同步

---

## 2. 架构

```text
MLGridView
    │  rightMouseDown → hit-test → build NSMenu + action enum
    ▼
MLOverlayController
    ├── Open              → 现有 didActivate / MLAppLauncher（可跳过动画或短动画）
    ├── Reveal in Finder  → NSWorkspace activateFileViewerSelectingURLs:
    ├── Pin / Unpin       → MLTaskbarPinStore（AppDelegate 注入）
    ├── Move to folder    → MLLayoutStore 新 API（按 path / folderId）
    └── Uninstall…        → MLAppUninstaller（新）+ 确认面板 + 索引/布局同步
```

| 层 | 职责 |
|----|------|
| `MLGridView` | 命中可见槽、组菜单、标题/enabled、弹出；**不**动 pin / layout / 磁盘删除 |
| `MLOverlayController` | 解释 action；打开 / 访达 / pin / 移入组；拉起卸载流程 |
| `MLTaskbarPinStore` | 已有；Overlay 只调 `pinPath:` / `unpinPath:` / `isPinned:` |
| `MLLayoutStore` + `ml_layout_*` | 列出根级文件夹；按 path 移入指定 folderId |
| `MLAppUninstaller`（新，System） | 权限门禁、卸载器探测、残留扫描、移入废纸篓 |
| `AppDelegate` | 向 Overlay 注入 `pinStore`；卸载后触发 rescan / layout sync（可复用现有 scan 管线） |

推荐 **action enum** + 单一 delegate（对齐 `MLTaskbarMenuAction`）：

```objc
typedef NS_ENUM(NSInteger, MLOverlayIconMenuAction) {
    MLOverlayIconMenuActionOpen = 0,
    MLOverlayIconMenuActionRevealInFinder,
    MLOverlayIconMenuActionPinToggle,
    MLOverlayIconMenuActionMoveToFolder, /* representedObject = folderId */
    MLOverlayIconMenuActionUninstall,
};

@protocol MLGridViewDelegate /* 增补 */
- (void)gridView:(MLGridView *)gridView
 didSelectIconMenuAction:(MLOverlayIconMenuAction)action
         atVisibleIndex:(NSInteger)vis
               folderId:(NSString *)folderId; /* MoveTo 时非 nil；其余可 nil */
- (void)gridView:(MLGridView *)gridView
  iconMenuFlags:(MLOverlayIconMenuFlags *)flags
 forVisibleIndex:(NSInteger)vis;
@end
```

`MLOverlayIconMenuFlags`（弹出瞬间现场读）：

| 字段 | 含义 |
|------|------|
| `isApp` | 否 → 不弹菜单（文件夹格） |
| `appPath` | 标准化 path |
| `pinned` | `pinStore isPinned:` |
| `canPin` | path 合法且非空 |
| `canUninstall` | 非系统保护路径、非自身、父目录可写（粗判） |
| `folderIds` / `folderNames` | 可移入的目标组（排除当前所在组） |

二级菜单「移动到」：每个子项 `tag = MoveToFolder`，`representedObject = folderId`。

---

## 3. 各菜单行为

### 3.1 打开

- 与左键激活同源：`[MLAppLauncher openApplicationAtPath:]`。
- 建议复用 `gridView:didActivateAppAtPath:` 管线（含启动动画 + hide overlay），避免两套启动路径。
- 搜索模式下同样可用。

### 3.2 在访达中显示

```objc
NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
```

- 选中的是 **`.app` 包本身**（访达高亮该应用），不是「打开包内容」。
- Overlay 可保持打开或隐藏：建议**保持打开**（用户常会继续操作）；若觉得挡屏，可 `hide`——实现时默认保持打开，文档验收写清。

### 3.3 固定到任务栏（左侧）

- 「左侧」= 任务栏 **Pin 区**（leading contiguous `PinnedOnly`），不是屏幕物理左缘。
- 未钉住：`[pinStore pinPath:path]` → 追加到 `pins[]` 末尾（与任务栏右键钉住一致）；Pin 区本身在栏左侧。
- 已钉住：文案改为「从任务栏取消固定」，调用 `unpinPath:`；或显示已固定并禁用「固定」——**推荐 toggle 文案**（对齐任务栏 `pin`/`unpin`）。
- Overlay **不**改 pin 区内排序；用户可在任务栏拖拽调整。
- 注入：`MLOverlayController` 增加 `weak/strong MLTaskbarPinStore *pinStore`；`AppDelegate` 在创建 taskbar 后赋值（与 `layoutStore` 同级单例式所有权）。

### 3.4 移动到 ▸（组名）

「组」= layout **根级文件夹**（`doc/08`），不是任务栏分组。

**现有缺口**：仅有 `addRootAppFrom:toFolderAt:`（按 root 下标），缺少：

- 枚举全部根级 folder（id + name）
- 任意位置的 app（root 或某 folder 内、或搜索扁平列表）**按 path** 移入指定 `folderId`

**新增 Core / Store API（示意）**：

```c
/* ml_layout.h */
/* 若 path 已在 folderId 内 → no-op 成功；若在其他 folder/root → 先摘出再 append */
int ml_layout_move_app_path_to_folder(MLLayout *layout,
                                      const char *app_path,
                                      const char *folder_id);
```

```objc
/* MLLayoutStore */
- (NSArray<NSDictionary *> *)rootFolderInfos; /* @[ @{ @"id":, @"name": }, ... ] */
- (BOOL)moveAppAtPath:(NSString *)path intoFolderId:(NSString *)folderId;
```

UI 规则：

| 场景 | 行为 |
|------|------|
| 无任何文件夹 | 「移动到」禁用（或子菜单一项灰色「暂无分组」） |
| 应用已在某组内 | 子菜单**排除当前组**；可选保留当前组为勾选项禁用（本期排除即可） |
| 搜索模式 | 仍可按 path 移入；移入后 `scheduleSave` + reload |
| 文件夹内视图 | 同 path API；移入其他组后若原组 ≤1 应用 → 现有 dissolve 逻辑 |
| 目标组名空 | 显示默认名（与网格一致，如「文件夹」） |

不做：子菜单里「新建分组」（可用拖拽合并继续创建）。

### 3.5 卸载…

危险操作，必须分步确认；**默认移入废纸篓**，不直接删除。

#### 3.5.1 门禁（不可卸则禁用 + tooltip/Alert 说明）

| 条件 | 处理 |
|------|------|
| 路径在 `/System`、`/Library/Apple`、SIP 保护区 | 禁用 |
| 路径为 MeoLaunch 自身 bundle | 禁用 |
| 父目录不可写且非用户可授权场景 | 尝试废纸篓；失败则 Alert 权限说明 |
| 应用正在运行 | Alert：先提示退出；可选「仍要移入废纸篓」（系统会处理占用，失败则报错） |

#### 3.5.2 专用卸载程序

在确认前异步扫描（主线程只弹 UI）：

1. 同目录旁是否存在名称含 `Uninstall` / `卸载` 的 `.app`
2. Bundle 内 `Contents` / 常见相对路径是否有卸载器
3. `Info.plist` 自定义键（若有）— 有则记录，无则忽略

若发现卸载器 → **优先提示**：

```text
「XXX」提供了专用卸载程序。
建议先运行卸载程序，以免残留驱动/特权组件。

[ 打开卸载程序 ]  [ 仍移入废纸篓… ]  [ 取消 ]
```

「打开卸载程序」→ `MLAppLauncher` 打开该卸载器 path，**不**自动删主应用。

#### 3.5.3 残留提示

以 **bundle id** + **显示名** 在用户域做浅扫描（控制 IO / 内存）：

```text
~/Library/Application Support/<Name|bundle>
~/Library/Preferences/<bundle-id>.plist
~/Library/Caches/<bundle-id>
~/Library/Containers/<bundle-id>
~/Library/Saved Application State/<bundle-id>.savedState
~/Library/Logs/<Name|bundle>
```

规则：

- 仅匹配高置信路径；禁止模糊扫整个 `~/Library`
- 结果列表展示 path + 粗略大小；默认**不勾选**删除残留
- 文案：「检测到可能残留 N 项。移入废纸篓应用后，可勾选一并清理（可还原）。」
- `/Library` 系统域本期只**只读提示数量/路径**（若无权限则跳过），不自动删

#### 3.5.4 执行顺序

1. 用户确认主包 → `NSFileManager trashItemAtURL:` 或 `NSWorkspace recycleURLs:`
2. 可选：勾选残留同样 `trashItem`
3. 成功后：触发 App 索引 rescan（现有 `MLAppScanWatcher` / 手动 scan）→ `layoutStore syncWithAppIndex:` 剪枝
4. 若已 pin → `unpinPath:`
5. Overlay `reloadData`；失败 → Alert，不改 layout

新建类型建议：`Sources/System/MLAppUninstaller.h/.m`（纯 System，不引用 UI 网格）。

---

## 4. 交互与边界

### 4.1 命中与手势

- `rightMouseDown:` → `visibleSlotAtPoint:`；非应用格 / 空白 → **不弹菜单**（或空白未来可扩展，本期忽略）。
- `_dragActive == YES` → 忽略右键（对齐任务栏）。
- 左键拖拽阈值不受影响；右键不启动 drag。

### 4.2 模式

| 模式 | 菜单 |
|------|------|
| 主网格浏览 | 全套 |
| 文件夹内 | 全套；「移动到」排除当前 folderId |
| 搜索过滤 | 打开 / 访达 / 钉住 / 卸载 / 移动到；无文件夹格 |

### 4.3 内存与性能

- 菜单构建 O(根级 folder 数)，通常 ≪ 百；不预缓存菜单。
- 卸载扫描在后台 queue；结果回主线程；超时（如 2s）则「残留未知，仍可只移主包」。
- 不引入第三方库；不扫全盘。

### 4.4 文案（`MLStrings`）

| Key | 中 / 英（示意） |
|-----|-----------------|
| `overlay.menu.open` | 打开 / Open |
| `overlay.menu.reveal_in_finder` | 在访达中显示 / Show in Finder |
| `overlay.menu.pin` | 固定到任务栏 / Pin to Taskbar |
| `overlay.menu.unpin` | 从任务栏取消固定 / Unpin from Taskbar |
| `overlay.menu.move_to` | 移动到 / Move to |
| `overlay.menu.no_folders` | 暂无分组 / No Groups |
| `overlay.menu.uninstall` | 卸载… / Uninstall… |
| `overlay.uninstall.*` | 确认标题、卸载器提示、残留说明、失败 |

可复用 `taskbar.pin` / `taskbar.unpin` 若语义一致；为免任务栏/Overlay 文案分叉，**推荐独立 `overlay.menu.*`**，中文都写「任务栏」。

### 4.5 Peek / 任务栏不变量

本功能不改任务栏 peek / soft-minimize / 多屏 affinity。仅调用 `pinStore` 写 pins。改完跑 `./Scripts/build.sh`；若动到 Taskbar 文件再跑 peek smoke。

---

## 5. 改动文件（预期）

| 文件 | 改动 |
|------|------|
| `Sources/UI/MLGridView.h/.m` | enum、flags、`rightMouseDown:`、组菜单 |
| `Sources/UI/MLOverlayController.h/.m` | 处理菜单；持有 `pinStore`；卸载 UI 流程 |
| `Sources/App/AppDelegate.m` | 注入 `pinStore`；卸载后 rescan 钩子（若需） |
| `Sources/System/MLLayoutStore.h/.m` | `rootFolderInfos`、`moveAppAtPath:intoFolderId:` |
| `Sources/Core/ml_layout.h/.c` | `ml_layout_move_app_path_to_folder` |
| `Sources/System/MLAppUninstaller.h/.m` | **新建** 门禁 / 卸载器 / 残留 / trash |
| `Sources/System/MLStrings.m`（及 `.h` 若需） | 文案 key |
| `Scripts/build.sh` / `project.yml` | 若需登记新 `.m` |
| `doc/08-layout-folders.md` | 交叉引用「右键移入组」 |
| `doc/04-implementation.md` | C API 变更时同步（playbook 要求） |

---

## 6. 分期与风险

| 阶段 | 内容 | 风险 |
|------|------|------|
| O0 | 菜单骨架 + 打开 + 访达 + pin toggle | 低；对齐任务栏模式 |
| O1 | layout 移入组 API + 二级菜单 | 中；path 唯一性、dissolve、搜索模式 |
| O2 | 卸载确认 + trash 主包 + sync/unpin | 中；权限、运行中 app |
| O3 | 卸载器探测 + 残留列表（可选勾选 trash） | 较高；误匹配残留 → 必须高置信 + 默认不勾选 |

**产品决策（已写入方案，实现勿偏离）**：

1. 钉住 = 追加到 pin 列表末尾（Pin 区在栏左）。
2. 访达 = 选中 `.app` 包。
3. 有专用卸载器 → 先提示，不擅自只删主包而不告知。
4. 残留默认只提示；用户显式勾选才 trash。

---

## 7. 验收总览

1. 应用图标右键出现完整菜单；文件夹格右键无菜单。
2. 打开 = 启动应用（行为与左键一致）。
3. 在访达中显示 = Finder 高亮该 `.app`。
4. 固定后任务栏左侧 Pin 区出现图标；再右键可取消固定。
5. 「移动到」列出组名；点组名后图标进入该组；`layout.json` 持久化；原组可 dissolve。
6. 卸载：系统应用禁用；普通应用确认后进废纸篓并从网格消失；有卸载器/残留时有提示。
7. 中英文切换文案正确；`./Scripts/build.sh` 通过。
8. 不回归拖拽排序/合并；不破坏任务栏 peek 不变量。
