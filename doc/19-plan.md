# 19-Plan — 任务栏声音指示 + 一键静音（自动化任务卡）

> **已全部 done。** 自动化队列可回到用户指定的下一项；本文件为任务栏声音指示里程碑归档。  
> 用户说「继续」「全自动开发」「按 19-plan」「任务栏声音」「音频指示」等 → 读下方 **Status**（应无 pending）。  
> 设计：[19-taskbar-audio-indicator.md](./19-taskbar-audio-indicator.md)

## Status

| ID | 状态 | 备注 |
|----|------|------|
| A0 | done | 薄封装 + `Scripts/audio_spike.sh`；枚举 OK；afplay Process Tap `CATapMuted` mute/unmute OK |
| A1 | done | Monitor + 角标绘制；peek smoke 18 OK |
| A2 | done | 角标 hit + Process Tap mute；Info.plist 音频用途说明 |
| A3 | done | Bundle 归属 + 右键静音 + 默认输出设备变更重建 tap |
| A4 | done | Prefs `audio_indicator`；`<14.2` 隐藏；关则卸 tap |

## 执行协议

1. **一次一卡**；验收后可立即下一张。  
2. 每卡结束：`./Scripts/build.sh` 必须通过。  
3. 禁止第三方库；不改 `doc/00`–`doc/06` 正文（overview 索引除外）。  
4. Commit 仅在用户明确要求时；message 用简体中文。  
5. 改完把 Status 标 `done` 并写备注。  
6. 遵守 peek 不变量：`.cursor/rules/taskbar-peek-invariants.mdc`。  
7. 完整能力门控 **macOS 14.2+**；更低版本 no-op。  
8. 角标点击**不得**走整芯片左键（activate / soft-min）。  
9. 无用户静音时不建 Process Tap；失败必须销毁半成品并恢复直通。

---

## 任务卡

### A0 — Spike：检测 + 静音通路（P0）

- **改**（可临时脚本或最小 `Sources/System` 原型，最终代码应可复用/删尖刺）：
  - 优先落在可保留的薄封装，避免一次性扔弃的大段复制
  - `Scripts/build.sh` / `project.yml`（若已链正式源文件）
- **做**：
  1. 在 14.2+ 枚举 `kAudioHardwarePropertyProcessObjectList`，读 PID / BundleID / `IsRunningOutput`
  2. 对至少一个常见播放源（Music 或 Safari 视频）创建 Process Tap，`mutedWhenTapped`（或等价）验证无声与恢复
  3. 记录：TCC 弹窗、失败 `OSStatus`、设备切换注意点 → 写回设计文档「Spike 备注」小节或本卡 Status 备注
  4. Runtime：`@available` / 版本检查；`<14.2` 不调用新 API
- **验收**：
  - `./Scripts/build.sh`
  - Spike 结论足以支撑 A1/A2（检测稳定、静音可恢复）；若不可行 → **停自动化并报告用户**，勿盲目标 done
- **禁止**：改任务条绘制；引入第三方库；13.x 私有 mute 方案

---

### A1 — 只读指示器：Monitor + 角标绘制（P0）

- **改**：
  - `Sources/System/MLAudioActivityMonitor.h/.m`（新建）
  - `Sources/UI/MLTaskbarView.h/.m`（item 字段 + draw）
  - `Sources/UI/MLTaskbarController+Items.m`（及必要时 Controller 头）
  - `Sources/App/AppDelegate.m`（注入/启动 monitor）
  - `Scripts/build.sh` / `project.yml`
- **做**：
  1. Monitor：监听 process list / `IsRunningOutput`；防抖 200–500ms；排除自身 pid
  2. 按 pid（初版即可）合并到芯片 → `audioState = Playing | None`（本卡不做 Muted）
  3. `drawRect`：图标右下角小喇叭；不进 `MLTaskbarIconCache`
  4. `<14.2`：Monitor no-op，不绘制
- **验收**：
  - `./Scripts/build.sh`
  - 手测：播放出现角标、停止后消失；同 pid 多芯片一致
  - `./Scripts/taskbar_peek_smoke.sh`（若环境可跑）
- **禁止**：实现 mute；改芯片左键语义；高频盲轮询拖内存

---

### A2 — 点击静音：MuteController + 角标 hit（P0）

- **改**：
  - `Sources/System/MLAppAudioMuteController.h/.m`（新建）
  - `MLTaskbarView`（角标 hit-test + delegate）
  - `MLTaskbarController(+WindowActions)`（分发 mute，不 activate）
  - `Info.plist`：`NSAudioCaptureUsageDescription`
  - `MLStrings`（权限/失败提示）
  - build 登记
- **做**：
  1. 按需为目标进程建/毁 Process Tap；状态 `Muted`
  2. 仅角标热区点击 ↔ mute；整芯片左键不变
  3. 进程退出 / 芯片消失：清 tap 与状态
  4. 授权拒绝或 tap 失败：提示；不留半残音频图
- **验收**：
  - `./Scripts/build.sh`
  - 手测：角标静音/恢复；左键前置与软最小化仍正常；peek 不闪
- **禁止**：给所有发声 app 预建 tap；角标点击触发 soft-min

---

### A3 — 打磨：Helper 归属 + 菜单 + 设备切换（P1）

- **改**：`MLAudioActivityMonitor`、`MLAppAudioMuteController`、任务栏右键菜单相关、`MLStrings`
- **做**：
  1. 浏览器 / Electron helper：BundleID / 包路径启发式归属到主 app 芯片（宁可漏标）
  2. 右键：「静音此应用」/「取消静音」（与角标状态一致）
  3. 默认输出设备变更：重建仍 muted 的 tap
  4. 防抖与焦点切换下角标不疯狂闪烁
- **验收**：
  - `./Scripts/build.sh`
  - 手测：Chrome/Safari 至少一条路径角标合理；切蓝牙/耳机后 muted 不永久卡死
- **禁止**：全盘扫进程树；改 peek 逻辑

---

### A4 — Prefs + 文档收尾（P2）

- **改**：`MLPrefsWindow` / 配置键（若已有 prefs 模式）、`MLStrings`、`doc/10-taskbar.md` 短链或一小节、本设计 Spike 备注整理
- **做**：
  1. Prefs：「任务栏显示声音指示」；默认开；`<14.2` 隐藏
  2. 关则不监听或忽略 UI（实现选成本低者；关时销毁一切 tap）
  3. overview 已有 19 链接则核验；`10-taskbar` 补一句能力说明（可链 19 设计）
- **验收**：`./Scripts/build.sh`；开关生效；中英文（若项目双语文案）齐全
- **禁止**：大改 `doc/00`–`06` 正文

---

## 建议手测清单（全部 done 后）

1. Music / 浏览器视频：角标 ↔ 播放状态。  
2. 角标静音 / 恢复；芯片左键与右键其它项不受影响。  
3. 同 app 多窗口状态一致。  
4. 权限拒绝有提示；`<14.2` 无角标不崩。  
5. 输出设备切换后 muted 可恢复或保持可控。  
6. `./Scripts/build.sh` + `./Scripts/taskbar_peek_smoke.sh`。
