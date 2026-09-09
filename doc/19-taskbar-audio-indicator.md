# 19 — 任务栏声音指示 + 一键静音

> 目标：任务条芯片在对应应用**正在使用音频输出**时显示喇叭标识；点击标识可对该应用静音 / 取消静音。  
> 任务卡真源：[19-plan.md](./19-plan.md)

---

## 1. 目标与非目标

### 目标（MVP）

| 能力 | 行为 |
|------|------|
| 发声指示 | 进程有活跃 **输出流**（`kAudioProcessPropertyIsRunningOutput`）时，该 app 在任务条上的芯片显示小喇叭 |
| 一键静音 | 点击喇叭独立热区 → 该进程音频 mute ↔ unmute |
| 多芯片同步 | 同一 `pid`（或同 bundle 归属）的多个窗口芯片共享 `audioState` |
| 系统门槛 | **完整能力仅 macOS 14.2+**；13.x / 14.0–14.1 运行时关闭本功能（不崩溃、无死代码路径误调） |

### 非目标

- 窗口级静音（音频按进程，无法可靠绑到单个 `CGWindowID`）
- 音量滑条 / 混音器 UI
- Now Playing 曲名 / 封面
- 13.x 私有 API 或虚拟声卡方案
- 改 peek / soft-min 左键主路径语义
- 第三方库

---

## 2. 系统 API 与权限

### 2.1 检测（14.2+）

- `kAudioHardwarePropertyProcessObjectList`
- 每进程：`kAudioProcessPropertyPID` / `BundleID` / `IsRunningOutput`
- 优先 **属性监听** + 短防抖（200–500ms）；避免高频盲轮询
- 语义：「输出 IO 活跃」，不是响度 > 0

### 2.2 静音（14.2+）

- Core Audio **Process Tap**：`CATapDescription` + `AudioHardwareCreateProcessTap`
- `muteBehavior = mutedWhenTapped`（或等价：tap 后 IOProc 增益=0）
- 仅对**用户点过静音**的进程建 tap；unmute / 进程退出立即销毁
- 默认输出设备变更时重建仍处于 muted 的 tap

### 2.3 权限 / 打包

- `Info.plist`：`NSAudioCaptureUsageDescription`（简体中文说明用途）
- 首次静音可能触发系统音频录制授权；拒绝 → 提示，不 silent fail 死循环
- 保持非沙盒（Process Tap 要求）
- 链接 `CoreAudio`（及实现所需的 Audio HAL 头）

### 2.4 降级

| 环境 | 行为 |
|------|------|
| `< 14.2` | Monitor / MuteController 为 no-op；不画角标 |
| 无授权 | 可仍显示「在播」指示（若检测不需捕获）；静音点击 → 引导授权或 Prefs 提示 |
| Tap 失败 | 销毁半成品对象；芯片保持 `playing`；可选一次错误提示 |

---

## 3. 模块划分

```
MLAudioActivityMonitor     Sources/System  — 谁在 IsRunningOutput
MLAppAudioMuteController   Sources/System  — 按需 Process Tap mute/unmute
MLTaskbarItem / View       Sources/UI      — audioState + 角标绘制 + 角标 hit
MLTaskbarController        Sources/UI      — 合并 pid→芯片；角标点击分发
```

- 不进 Core C。
- 与 Overlay / `MLIconCache` 解耦；角标自绘或 SF Symbol，**不进** `MLTaskbarIconCache`。

### 3.1 状态机（每音频身份：pid 或规范化 bundle key）

```
idle ──(IsRunningOutput)──► playing
playing ──(click mute ok)──► muted
muted ──(click unmute / destroy tap)──► idle 或 playing（视当前 IsRunningOutput）
muted ──(进程退出)──► idle（清 tap）
任意 ──(<14.2)──► 永不离开 idle（功能关闭）
```

芯片字段建议：`MLTaskbarAudioState { None, Playing, Muted }`（命名以实现为准）。

---

## 4. UI / 交互

| 规则 | 说明 |
|------|------|
| 角标位置 | 芯片图标右下角，约 12–14pt |
| 点击 | **仅角标 hit 区**触发 mute；整芯片左键仍为 activate / soft-min / launch |
| 已静音 | 划线喇叭；可在输出流结束后仍保留至 unmute 或进程退出 |
| 右键菜单（A3） | 可选「静音此应用 / 取消静音」 |
| Prefs（A4） | 「任务栏显示声音指示」开关；默认开；`<14.2` 隐藏整项 |

**禁止**：改变 peek 不变量；角标点击触发 soft-min。

---

## 5. 多进程归属（浏览器 / Electron）

- 主路径：任务条芯片 `pid` 直接命中 process object。
- 若发声在 helper：用 `BundleID` / 同 app 包路径启发式，把 helper 的输出态归到主 app 芯片。
- 宁可漏标，不可把无关 app 标成在播。

---

## 6. 内存与生命周期

1. 无 muted 进程时：**零** Process Tap / 无聚合设备。
2. Monitor 只持有瘦映射（pid → flags），不持音频 buffer。
3. App 终止 / 芯片消失：清 mute 状态与 tap。
4. 不与 Overlay show/hide、icon purge 耦合。

---

## 7. 与任务栏文档关系

- 产品条目可链到 [10-taskbar.md](./10-taskbar.md)（实现期在 overview 加索引即可；不改 00–06 正文大段）。
- Peek：遵守 `.cursor/rules/taskbar-peek-invariants.mdc`。
- 构建：新 `.m` 登记 `Scripts/build.sh` / `project.yml`（若有）。

---

## 9. Spike 备注（A0，2026-09-09）

| 项 | 结果 |
|----|------|
| 主机 | macOS 26.6.2；`MLAudioProcessSupport isAvailable` = YES |
| 检测 | `kAudioHardwarePropertyProcessObjectList` 可用；`IsRunningOutput` 在 `afplay` 播放时正确翻转为 1 |
| 静音 | 仅 `CreateProcessTap`+`CATapMuted` **不足以**让 WebKit/浏览器无声；需 **私有 Aggregate + discarding IOProc**，`muteBehavior = CATapMutedWhenTapped`（读 tap 期间静音） |
| 符号 | Create/Destroy 经 `dlsym`，部署目标 13.0 安全；`<14.2` 整段 no-op |
| TCC | 本机对 `afplay` mute **未**弹系统音频录制框（可能因短测 / 已授权环境）；正式 App 仍加 `NSAudioCaptureUsageDescription`，按失败 OSStatus 降级 |
| 工具 | `./Scripts/audio_spike.sh`（可选 `--mute <pid>`） |
| 代码 | `MLAudioProcessSupport`、`MLAppAudioMuteController`（A1/A2 复用） |
| 设备切换 | A0 未测；留给 A3 重建 tap |
| WebKit 归属（A3 修） | 发声常在 `com.apple.WebKit.GPU`（ppid=1）；用 localizedName「Host Graphics and Media」映射到宿主 Regular app（如 MeoBrowser） |

**结论**：通路可行，可进入 A1（只读角标）。

---

## 8. 手测清单（里程碑结束）

1. Music / Safari 视频：角标出现；停止后消失（防抖后）。  
2. 点角标静音 → 无声；再点恢复；芯片左键行为不变。  
3. 同 app 两窗口：两芯片状态一致。  
4. 拒绝系统音频权限后静音有提示。  
5. `<14.2` 机（若有）或模拟：无角标、不崩。  
6. 输出设备切换后仍 muted 的 app 保持静音或可恢复。  
7. `./Scripts/build.sh`；`./Scripts/taskbar_peek_smoke.sh`。
