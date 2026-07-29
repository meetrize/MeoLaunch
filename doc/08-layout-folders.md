# 08 — 拖动排序与目录分组（设计方案 + 开发计划）

> 在现有 MeoLaunch 上增加 Launchpad 风格的**拖拽重排**与**单层文件夹分组**，优先控制内存与实现复杂度。

## 1. 目标与非目标

### 目标（本期）

| 能力 | 行为（对齐 Launchpad） |
|------|------------------------|
| 拖动排序 | 按住图标拖动，松手后插入目标位置，**立即持久化顺序** |
| 合并分组 | 拖到另一图标上停留/松开 → 两者进入同一文件夹 |
| 文件夹 | 主网格显示文件夹图标（叠放预览）；点击进入文件夹视图 |
| 命名 | 进入文件夹后，在名称位置可编辑标题（默认「文件夹」） |
| 移出 | 拖出文件夹回到主网格（本期可做；若排期紧可放到下一阶段） |
| 搜索 | 搜索结果仍是扁平应用列表；**不展示文件夹节点**（与 Launchpad 接近） |

### 非目标（明确不做）

- 文件夹嵌套（文件夹里再建文件夹）
- iCloud / 多机同步布局
- 拖到页边缘自动翻页的复杂手势（可二期）
- 拖到 Dock / 其他 App
- 为拖拽单独缓存全量高清图标

---

## 2. 设计原则（控内存）

1. **布局与扫描索引分离**  
   - `MLAppIndex` 仍只存「真实 .app」扫描结果（path / name）。  
   - 新增极轻量的 **Layout Store**（顺序 + 文件夹），不复制 `MLAppEntry` 字符串。

2. **引用用 path，不拷贝元数据**  
   - 布局项只存 `app_path` 或 `folder_id`。  
   - 显示时用 path 在 `MLAppIndex` 里 O(1)/O(log n) 查找（见下）。

3. **拖拽只多一个临时层**  
   - 沿用现有启动动画思路：一个 `CALayer` / `NSImageView` 跟随鼠标。  
   - 松手即销毁；不引入 UICollectionView / 重型拖放框架。

4. **持久化小文件、防抖写盘**  
   - `layout.json` 预计数 KB～数十 KB。  
   - 松手后 `scheduleSave`（与 config 同款 300ms 防抖），避免拖动中狂写磁盘。

5. **打开 Overlay 才物化「可见槽位」**  
   - 常驻时只保留 Layout + AppIndex；不预建每页 NSView 图标树（继续现有 `drawRect`）。

---

## 3. 数据模型

### 3.1 文件位置

```
~/Library/Application Support/meoLaunch/layout.json
```

与 `config.json` 并列，避免配置与布局互相污染。

### 3.2 Schema（建议 version: 1）

```json
{
  "version": 1,
  "root": [
    { "type": "app", "path": "/Applications/Safari.app" },
    {
      "type": "folder",
      "id": "f_01J…",
      "name": "效率",
      "items": [
        { "type": "app", "path": "/Applications/Notes.app" },
        { "type": "app", "path": "/Applications/Calendar.app" }
      ]
    }
  ]
}
```

约束：

- `root[]`：主网格从左到右、从上到下、跨页连续顺序。  
- `folder.items[]`：仅允许 `type: "app"`（禁止嵌套）。  
- `folder.id`：稳定 UUID（合并时生成一次，重命名不改 id）。  
- 同一 `path` 全局唯一（不可同时出现在 root 与某 folder）。

### 3.3 内存中的 C / ObjC 结构（示意）

```c
typedef enum { ML_LAYOUT_APP = 1, ML_LAYOUT_FOLDER = 2 } MLLayoutKind;

typedef struct MLLayoutAppRef {
    char *path;           /* 与 AppIndex 共享语义；可 intern 或仅持有指针策略见实现 */
} MLLayoutAppRef;

typedef struct MLLayoutFolder {
    char *id;
    char *name;           /* UTF-8，可空 → UI 显示默认名 */
    MLLayoutAppRef *items;
    size_t count;
    size_t capacity;
} MLLayoutFolder;

typedef struct MLLayoutNode {
    MLLayoutKind kind;
    union {
        MLLayoutAppRef app;
        MLLayoutFolder *folder; /* 堆上，文件夹数量通常很少 */
    } u;
} MLLayoutNode;

typedef struct MLLayout {
    MLLayoutNode *root;
    size_t count;
    size_t capacity;
} MLLayout;
```

**查找加速（推荐，内存仍低）：**

- 扫描完成后建 `path → appIndex` 的哈希表（或排序数组 + 二分）。  
- 布局只存 path；绘制时查表取 `display_name` / 图标缓存 key。  
- 哈希表条目：指针级，约 `O(n)`，n≈应用数（百级），可忽略。

### 3.4 与扫描结果的同步规则

| 事件 | 行为 |
|------|------|
| 新发现的 app | **追加到 `root` 末尾** |
| 布局中的 path 已不存在 | **静默剔除**（写回时清理） |
| 用户未改过布局 | 首次可按扫描顺序生成 `root` |
| 搜索模式 | 忽略 layout 顺序，仍用 filter 后的扁平 app 列表 |

---

## 4. UI / 交互设计

### 4.1 主网格（编辑态与浏览态同一套）

- 继续 `MLGridView` 自绘；每个**可见槽位**对应 `root` 中一个 node（app 或 folder）。  
- **文件夹图标**：2×2 小图标拼贴（最多 4 个）+ 文件夹名称；不新开纹理集，复用 `MLIconCache`。  
- **点击 app**：现有启动动画 + 打开。  
- **点击 folder**：进入文件夹视图（见 4.3）。  
- **键盘导航**：选中 folder 时回车 = 打开文件夹；选中 app = 启动。

### 4.2 拖拽手势（低成本实现）

```
mouseDown 命中图标
  → 记录 hit index，启动短延迟或位移阈值（~4pt）判定「开始拖」
  → 未达阈值且 mouseUp = 点击
开始拖
  → 源槽位显示半透明占位（或空心）
  → 跟随层：CALayer 显示拖中图标（仅 1 份）
mouseDragged
  → 更新跟随层位置
  → 命中测试：目标槽位
      · 落在「间隙/其他槽」→ 插入预览（可选：目标处让位高亮）
      · 落在「另一 app 图标中心热区」→ 合并高亮（缩放/圆环）
      · 落在 folder → 加入该 folder（高亮 folder）
mouseUp
  → 提交布局变更 → scheduleSave(layout)
  → 销毁跟随层 → reload 当前页
```

**合并热区**：目标图标中心约 50% 边长的正方形；热区外仍为「插入排序」，避免误合并。

**页边缘自动翻页**：一期可不做；二期加「靠近左右边缘 40pt 停留 0.4s 翻页」。

### 4.3 文件夹视图

- Overlay 内覆盖一层（或切换 `MLGridView` 数据源）：  
  - 顶部/图标下：**可编辑名称**（`NSTextField`，点击或首次合并后自动 focus）。  
  - 网格：仅该 folder 的 apps（行列可沿用全局 grid，或文件夹内固定较小网格）。  
  - 背景点击 / Esc：退出文件夹（若正在编辑名称则先结束编辑）。  
- 首次由两 app 合并生成时：默认名「文件夹」，**自动进入命名编辑**。

### 4.4 搜索与分组的关系

| 模式 | 数据源 | 拖拽 |
|------|--------|------|
| 无搜索词 | `layout.root` | 允许 |
| 有搜索词 | filter(`MLAppIndex`) 扁平结果 | **禁止拖拽**（避免顺序语义混乱） |

退出搜索后恢复 layout 视图。

---

## 5. 模块划分（落在现有结构）

```
Sources/Core/
  ml_layout.h/.c          # 布局 CRUD：insert / move / merge / remove / sync_with_index
  ml_layout_json.h/.c     # 可选：纯 C 序列化；或 ObjC 侧用 NSJSONSerialization

Sources/System/
  MLLayoutStore.h/.m      # 读盘/写盘/防抖、与 MLAppIndex 同步
  （path→index 映射可放这里或 Core）

Sources/UI/
  MLGridView              # 扩展：folder 绘制、hit-test 区分 app/folder、拖拽状态机
  MLFolderView（新，薄）   # 文件夹内网格 + 标题编辑；可先做 overlay 内模式切换少一个类
  MLOverlayController     # 编排：搜索时禁用 layout；打开/关闭 folder
```

不引入 SwiftUI / CollectionView。

---

## 6. 内存预算（粗估）

| 项目 | 增量 |
|------|------|
| layout.json 常驻（解析后） | ~数 KB～30KB（数百 app + 少量 folder） |
| path→index 表 | ~数 KB |
| 拖拽跟随层 | 瞬时 1 张图标位图（与现启动动画同级，用完释放） |
| 文件夹 2×2 预览 | 绘制时临时取 cache，不另建大图集 |

常驻增量目标：**≤ 2–5 MB**（通常远低于此）。Overlay 峰值仍主要由图标缓存决定（现有 `MLIconCache` purge 策略保持）。

---

## 7. 风险与对策

| 风险 | 对策 |
|------|------|
| 拖拽与点击冲突 | 位移阈值 + 时间阈值 |
| 合并误触 | 中心热区 + 插入默认 |
| 扫描顺序与用户顺序冲突 | 明确「layout 优先，新 app 仅追加」 |
| path 变更（App 搬家） | 剔除失效 path；无法自动跟随改名 |
| 绘制变复杂 | folder 绘制限制 4 小图标；其余不画 |
| 键盘 + 拖拽状态 | 拖拽中忽略方向键；结束后恢复 |

---

## 8. 开发计划（里程碑）

### M6 — Layout 持久化与主网格按序展示（无拖拽）

**产出**

- `layout.json` 读写 + `MLLayoutStore`
- 扫描后 `sync`：补新、删失
- 主网格按 `root` 渲染（仅 app 节点；folder 可先不生成）
- 搜索仍走 filter，不受 layout 影响

**验收**

- 重启后顺序与磁盘一致  
- 新装 app 出现在末尾  
- 删除 app 后布局无幽灵项  
- 内存无明显跳变（Instruments 对比 M5）

**估时**：2–3 天

---

### M7 — 拖拽排序

**产出**

- `MLGridView` 拖拽状态机 + 跟随层  
- 插入重排 `root` + 防抖保存  
- 搜索中禁用拖拽  

**验收**

- 拖 A 到 B 旁，松手后顺序正确且刷新后仍在  
- 短点击仍启动 app / 不误触拖拽  
- 拖拽中仅 1 个跟随层，松手后释放  

**估时**：2–3 天

---

### M8 — 合并为文件夹 + 命名

**产出**

- 拖到 app 热区 → 创建 folder（两 app）并替换原位置  
- 拖到已有 folder → 追加  
- 文件夹 2×2 预览绘制  
- 点击进入文件夹视图；标题可编辑并写回 `name`  
- Esc / 背景退出文件夹  

**验收**

- 合并后主网格少 1 格、出现 1 个 folder  
- 改名重启仍在  
- 文件夹内点击可启动；主网格键盘可进文件夹  

**估时**：3–4 天

---

### M9 — 从文件夹拖出 + 打磨（可选同迭代）

**产出**

- 文件夹内拖到外部（或拖到「退出热区」）移回 `root`  
- folder 仅剩 1 个 app 时自动解散为单 app（对齐 Launchpad）  
- 空 folder 不允许存在  
- 小动画：合并时轻微缩放；不做重特效  

**验收**

- 拖出后两边布局正确  
- 单元素 folder 自动解散  
- 全流程无明显泄漏（重复拖 50 次 cache 稳定）  

**估时**：2 天

---

### 建议排期总览

```
M6 Layout 存储与按序显示     ████░░░░░░
M7 拖拽排序                  ░░░░████░░
M8 分组 + 命名 + 文件夹视图  ░░░░░░░████
M9 拖出 / 解散 / 打磨        ░░░░░░░░░██
```

合计约 **9–12 人天**。若要更快上线：先做 M6+M7（仅排序），M8/M9 作下一版本。

---

## 9. 实现顺序建议（具体任务卡）

1. 定稿 `layout.json` schema；加 `doc/06` 交叉链接或本文件为权威。  
2. Core：`ml_layout_*` API（move / merge / add_app / prune）。  
3. `MLLayoutStore` + AppDelegate 扫描后 sync。  
4. `MLGridView` 数据源改为「layout 可见列表」（app+folder），搜索分支保持 filter。  
5. 拖拽排序（无合并）。  
6. 合并热区 + folder 模型。  
7. 文件夹 UI + 重命名。  
8. 拖出与自动解散。  
9. 回归：键盘、启动动画、偏好设置、多页、内存。  

---

## 10. 验收清单（产品向）

- [ ] 拖动改序，重启仍在  
- [ ] 拖到另一图标可成组  
- [ ] 组名可改，重启仍在  
- [ ] 搜索时不拖拽、结果仍全  
- [ ] 新 app 出现在末尾，不打乱已有顺序  
- [ ] 常驻内存增幅可接受（目标 &lt; 5MB）  
- [ ] 无文件夹嵌套、无同步云端（符合非目标）  

---

## 11. 与现有文档的关系

| 文档 | 变更 |
|------|------|
| [00-overview.md](./00-overview.md) | 「非目标」中文件夹一项改为本期目标；更新文档索引 |
| [03-features.md](./03-features.md) | 追加排序/分组规格 |
| [06-config-schema.md](./06-config-schema.md) | 注明 layout 独立文件，或链接本文 |
| [07-agent-playbook.md](./07-agent-playbook.md) | 增加 M6–M9 任务卡 |

本文为 **布局与分组功能的权威设计**；实现以本文为准。
