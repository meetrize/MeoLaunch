# Zed AI 活动指示（任务栏芯片）

实测日期：2026-11-03（Zed 本机版本，macOS 26/27 SDK）。

## 目标

Zed 正在生成回复或执行 Agent 工具时，在任务栏对应窗口芯片的图标上叠加一个半透明转圈指示；结束后自动消失。

## 信号探测结论

| 信号 | 是否可用 | 说明 |
|------|----------|------|
| Accessibility（AX） | 否 | Zed 使用 GPUI 自绘，AX 窗口树只暴露红绿灯按钮，没有 Agent 面板内容/停止按钮 |
| `Zed.log` | 部分 | 有 `Received prompt request` / `Cancelling on session`，但正常完成没有 INFO 日志 |
| `telemetry.log` | 部分 | 有 `Agent Message Sent` / `Agent Thread Completion`，但无法区分“回合结束”和“中间工具调用” |
| 网络/CPU | 不可靠 | 长工具执行（构建、测试）期间可能长时间无网络、低 CPU |
| **`threads.db`** | **是** | 每次用户发提示、每个模型回复完成、工具结果回填时持久化，状态语义明确 |

## threads.db 位置与结构

```text
~/Library/Application Support/Zed/threads/threads.db
```

`data` 列是 **zstd** 压缩的 JSON（`data_type = "zstd"`）。解压后：

```json
{
  "title": "...",
  "messages": [
    { "User": { "content": [...] } },
    { "Agent": { "content": [ { "Thinking": ... }, { "ToolUse": ... } ],
                 "tool_results": { "<tool_use_id>": {...} } } }
  ],
  "updated_at": "...",
  "draft_prompt": null
}
```

`folder_paths` 列为换行分隔的项目路径；`updated_at` 为 RFC3339 UTC。

## Busy 判定

只看最后一条消息：

1. `User` → 已发送提示，等待/正在生成 → **Busy**
2. `Agent` 的 `content` 里存在任意 `ToolUse` → 工具执行中，或工具结果已回填、下一次回复仍在流式输出 → **Busy**
3. `Agent` 且没有 `ToolUse`（仅有 `Text` / `Thinking`）→ 回合已结束 → **Idle**

关键点：

- Zed **在提示发送时**就会保存只有 `User` 消息的线程（失败请求也能看到 745 字节的 User-only 行）。
- **工具结果回填后**，最后的 `Agent` 消息仍保留 `ToolUse`，直到下一次模型回复完成才会写入新的 `Agent` 消息。因此“工具执行完 → 下一次回复流式输出”这段时间依然判定为 Busy。
- 最终回复通常包含 `Text` 且没有 `ToolUse`；被取消的回合可能只有 `Thinking`，同样没有 `ToolUse`，按 Idle 处理。

### 防误报

- `User` 消息超过 45 分钟无后续保存 → 视为放弃（Idle）。
- 带 `ToolUse` 的 `Agent` 消息超过 2 小时无后续保存 → 视为放弃（Idle）。
- 解析 `~/Library/Logs/Zed/Zed.log` 中新增的：
  - `Cancelling on session: <id>` → 立即清除该线程的 Busy。
  - `Turn execution failed:` / `Error in model response stream:` → 清除最近一次 `Received prompt request` 的会话（30 分钟内）。
- 子 Agent 线程（`parent_id` 非空）也参与判定；同一项目目录下任一最近线程 Busy，则芯片显示 Busy。

## 映射到芯片

- 只处理 bundle id `dev.zed.Zed` 的 `RunningWindow` 芯片。
- 用线程的 `folder_paths` 最后一级目录名（小写）匹配窗口标题：精确、前缀（`MeoLaunch — file`）或词边界包含。
- 匹配失败且当前栏只有一个 Zed 芯片时，直接标记该芯片；多个 Zed 芯片时退化为标记最前面的活动芯片。

## 实现文件

- `Sources/System/MLZedActivityMonitor.{h,m}`：1 Hz 扫描；DB mtime/size 变化才解压，否则复用线程快照并按时间/取消标记重算。
- `Sources/System/MLZstd.{h,m}` + `Sources/ThirdParty/zstd/zstddeclib.c`：内置的 zstd 只解压单文件库（BSD-3-Clause，见同目录 `LICENSE`）。macOS 系统没有 libzstd，`libarchive` 也会尝试调用外部 `zstd`，因此内置解码器是唯一无外部依赖方案。
- `Sources/UI/MLTaskbarView.m`：`drawBusyOverlayForItem:` 绘制半透明圆底 + 旋转蓝色弧线；仅在存在 busy 芯片时启动 0.07s 动画定时器。
- 配置：`taskbar.ai_activity_indicator`（默认 `true`），设置窗口「任务栏芯片显示 AI 对话/处理指示（Zed）」。

## 隐私

只解析消息的 **variant 名称**（`User` / `Agent` / `ToolUse` / `Text` / `Thinking`）与时间戳，不读取、不记录、不渲染任何消息正文；解压后的 JSON 在扫描后立即释放。

## 限制

- 默认只读取标准目录 `~/Library/Application Support/Zed`。若以 `--user-data-dir` 启动 Zed，可用 `ML_ZED_THREADS_DB` / `ML_ZED_LOG` 指向自定义位置。
- Cursor 的检测独立实现，见 [24-cursor-ai-activity.md](./24-cursor-ai-activity.md)。
- Zed 升级若改变 `threads.db` 的消息结构，监控会安全地退回 Idle（不会误报 Busy）。

## 测试

环境变量可覆盖路径（仅供测试）：

```sh
ML_ZED_THREADS_DB=/tmp/zed-test.db ML_ZED_LOG=/tmp/zed-test.log ./test-monitor
```

验证过的状态转换：`User → Busy`、`Agent+ToolUse → Busy`、`Agent+Text → Idle`、取消日志 → Idle、标题后缀匹配 → Busy、无关标题 → Idle。
