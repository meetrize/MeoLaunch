# Cursor AI 活动指示（任务栏芯片）

实测日期：2026-11-05（本机 Cursor unified Agent UI；修复久置后首次对话漏检）。

## 目标

Cursor 正在生成回复或执行 Agent 工具时，在任务栏对应窗口芯片的图标上叠加半透明转圈指示；结束后自动消失。

## Cursor 窗口与项目映射

- 窗口标题（AX）格式：`<项目名> - <文件名>`，例如 `MeoLaunch - filter_smoke.sh`。
- 每个打开的 workspace 常驻 `extension-host` 进程，环境变量：
  - `CURSOR_WORKSPACE_LABEL` → 精确项目名
  - `CURSOR_EXTENSION_HOST_ROLE` → `user` / `retrieval` / `agent-exec` / …
  - 新版 `CURSOR_LAYOUT=unifiedAgent` 下 **`agent-exec` 常驻**，不能单独当作 Busy。
- 通过 libproc `KERN_PROCARGS2` 读取（不 spawn `ps`，不读取/记录密钥类环境变量）。
- 项目目录：`~/.cursor/projects/<slug>/`，slug 为路径把 `/` 换成 `-`。用 `slug` 后缀 `-<label>` 匹配打开的项目名，避免项目名含 `-` 时被截断。

## Busy 主信号：composerData（unified Agent）

新版 Agent / Composer 对话**常常不再实时写入** `agent-transcripts/*.jsonl`（本机 MeoLaunch 在长时间对话期间 transcript 可数日不更新）。主信号改为：

```text
~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
  cursorDiskKV
    composerData:<composerId>   ← 结构字段
    bubbleId:<composerId>:…     ← 工具 bubble（可选确认）
```

只 `json_extract` 结构字段（`status` / `unfinishedRunAt` / `chatGenerationUUID` /
`generatingBubbleIds` / `isContinuationInProgress` / `lastUpdatedAt` /
`conversationCheckpointLastUpdatedAt` / `workspaceIdentifier.uri.path`），**不读消息正文**。

| 条件 | 判定 |
|------|------|
| `status = completed` | 强制 Idle |
| `generatingBubbleIds` 非空 | Busy |
| `isContinuationInProgress` | Busy |
| `unfinishedRunAt` 存在 **且** checkpoint/lastUpdated ≤ 55 秒 | Busy（即使 `status=aborted`；`unfinishedRunAt` 本身常残留，不能单独维持 Busy） |
| `chatGenerationUUID` + checkpoint 明显新于 lastUpdated，且非 `completed`/`none` | Busy（回合刚开始） |
| `bubbleId` 含 `status:"loading"` **且 createdAt ≤ 90 秒**，父 composer 未 `completed` | Busy（冷启动 / 长工具；忽略数日前残留的 loading） |
| 以上皆无 | 再回退到 legacy transcript / 侧信道 |

`workspaceIdentifier.uri.path` 的最后一级目录名（小写）映射到窗口标题前缀。`state.vscdb` / `-wal` 的 mtime/size 变化才重读；Busy 消失后保留约 3 秒 hangover。多窗口时**禁止**把 Busy 回退标到前台芯片（只允许单芯片回退）。

## Busy 回退：agent transcript（legacy）

```text
~/.cursor/projects/<slug>/agent-transcripts/<uuid>/<uuid>.jsonl
```

每行一条 JSON。只看**最后一条完整 JSON 行**（必须解析顶层 `type` / `role`，禁止字符串子串匹配）：

| 最后完整行 | 判定 |
|------------|------|
| `type = turn_ended` | 回合结束 → Idle |
| `role = user` 且年龄 ≤ 45 分钟 | 等待/正在回复 → Busy |
| `role = assistant` 且年龄 ≤ 25 秒 | 仍在流式输出/刚落一块 → Busy |
| 文件尾部有未闭合行 | 正在写入 → Busy |
| 文件大小/mtime 较上次采样增长 | Busy |
| `turn_ended` 之后又增长/出现半行 | Busy（下一轮已开始） |

补充：

- 完整 `assistant` 行安静超过 25 秒 → soft-quiet，不单独维持 Busy。
- 若该 workspace 有 `agent-exec` extension-host 且最后不是 `turn_ended`：
  - 最后一行 `user`：45 分钟内保持 Busy（模型可能长时间不刷 transcript）。
  - 最后一行 `assistant`：10 分钟内保持 Busy（思考/长工具间隔）。
- 只看每个项目**最新的若干 session**；旧的无 `turn_ended` 会话不会永久拖住 Busy。
- **不能**仅凭常驻 `agent-exec` + 过期 `turn_ended` 判定 Busy（unified Agent 下会永远假忙或永远漏检）。

## 侧信道

| 信号 | 窗口 | 说明 |
|------|------|------|
| `agent-tools/*` mtime | 60 秒 | 工具调用写入 |
| `terminals/*.txt` | 30 秒 | 解析 `---` 头部；`status: running` + `pid` 才算；`succeeded/failed/cancelled` 不算；后台 server 超过 120 秒且不再写输出不算 |
| `AgentStores/.../<session>/.sync/index.sqlite-wal` | 20 秒，增长 ≥ 2 KB | 不用 `sync.lock` mtime（会永久心跳）；父 transcript 已稳定 `turn_ended` 时忽略 |
| `agent-transcripts/<uuid>/` 无父 jsonl | 180 秒 | 新会话文件夹已经创建、transcript 尚未落盘 |

侧信道不能单独让一个已经 `turn_ended` 的项目保持 Busy；只有空项目（还没有 transcript）才允许用侧信道暖机。

## 映射到芯片

- 只处理 bundle id `com.todesktop.230313mzl4w4u92` 的 `RunningWindow` 芯片。
- 从窗口标题取第一个 ` - ` / ` — ` / ` – ` 之前的部分作为项目名，与 Busy label 做精确/边界匹配。
- 匹配失败且当前栏只有一个 Cursor 芯片时，标记该芯片；多个 Cursor 芯片时退化为标记最前面的活动芯片。

## 实现文件

- `Sources/System/MLCursorActivityMonitor.{h,m}`：1 Hz 扫描；`state.vscdb` composer 主信号；extension-host 进程每 3 秒刷新（空结果 0.75 秒重试）；transcript 只在 size/mtime 变化时重新读 64 KB 尾部。
- `Sources/UI/MLTaskbarController+Items.m`：Zed / Cursor 分别匹配，共用 `MLTaskbarItem.busy` 与转圈绘制。
- `Sources/UI/MLTaskbarView.m`：`drawBusyOverlayForItem:`。

## 隐私

只解析 `role` / `type` / `status` / `unfinishedRunAt` 等结构字段与文件时间戳；不读取、不记录、不渲染消息正文。进程扫描跳过含 `crsr_`、`api-key`、`token=`、`secret=` 等字段的字符串。

## 测试

环境变量可覆盖路径：

```sh
ML_CURSOR_PROJECTS_ROOT=/tmp/cursor-test/projects \
ML_CURSOR_AGENT_STORES_ROOT=/tmp/cursor-test/stores \
ML_CURSOR_GLOBAL_STATE_DB=/tmp/cursor-test/state.vscdb \
./test-monitor
```

已验证：

- 真实 unified Agent 对话：`composerData.unfinishedRunAt` + 新鲜 checkpoint → Busy（即使 `agent-transcripts` 数日未更新、`status=aborted`）。
- `User` 尾 → Busy；`turn_ended` → Idle。
- 尾部未闭合（即使以 `}` 结尾但 JSON 不完整）→ Busy。
- 最新 `assistant` + `agent-exec` 软安静 → Busy；补 `turn_ended` → Idle。
- `agent-tools` 新鲜 → Busy；文件变旧 → Idle。
- `terminals` `status: running` → Busy；`status: succeeded` → Idle。
- 标题 `MeoLaunch - filter_smoke.sh` 命中 `meolaunch`；`test - …` / `Other - …` 不误报。
- 真实 Cursor 数据：打开的项目 label 解析正确，当前空闲会话不误报。

## 诊断

运行中会每秒刷新 `/tmp/meolaunch-cursor-signals.txt`：

```text
label	state	reason	kind	age	side	candidates	roles
meolaunch	busy	composer-unfinished	aborted	3s	0	1	agent-exec+user
```

- `state=busy` 但芯片不转 → 窗口标题映射问题。
- `state=idle` 但 Cursor 正在工作 → 检测逻辑/信号路径问题。
- `reason=composer-*` → 走新主信号；`transcript` → legacy JSONL。
- `open` 为空 → extension-host 的 `CURSOR_WORKSPACE_LABEL` 与 composer 路径都没读到。

## 限制

- 多根 workspace / 自定义 workspace 名称与 slug 不一致时，可能无法把 transcript 映射到窗口；composer 路径映射对单文件夹项目正常。
- Cursor 升级若改变 `composerData` / transcript 结构，会安全退回 Idle，不会误报 Busy。
