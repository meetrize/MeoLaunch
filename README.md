# meoLaunch

**恢复 Launchpad，超越 Launchpad——一款 App，两种能力，极致内存。**

> English: *Bring back Launchpad—and go beyond. App grid + Taskbar. Native. Tiny memory.*

新版 macOS 拿掉了 Launchpad，找应用又回到 Dock 翻、Spotlight 搜、文件夹挖。meoLaunch 把熟悉的全屏应用网格**找回来**，并在同进程里加上轻量 **Taskbar**（每屏底栏、窗口切换 / 钉住），用一份极低常驻内存同时覆盖「启动」与「切换」。

真·原生：C 核心 + AppKit，不背 Electron、不背 WebView。

适合：怀念 Launchpad、想要 Windows 式底栏、又极度在意内存的 Mac 用户。

---

## 为什么选 meoLaunch

| | 系统现状 | meoLaunch |
|--|----------|-----------|
| 应用网格 | Launchpad **已移除** | **恢复**全屏网格 + 搜索 / 热角，体验更可控 |
| 窗口切换 | 主要靠 Dock / Mission Control | **同 App 内置 Taskbar**（每屏一条） |
| 技术栈 | — | **原生 AppKit**（非 Electron） |
| 常驻内存 | 多工具叠加易膨胀 | **一份进程扛两种功能**，目标 ≤ 15–25 MB（未打开网格时） |
| 唤起 | — | **热角 + 搜索即开**；底栏随时切换窗口 |
| 体感 | — | 设计目标：热角 → 首帧 ≤ 80–120 ms |

**一句话差异化：** 恢复 Launchpad 不够——还要**更好用**；再加 Taskbar——**一个应用两种功能**，内存仍压到极致。

**三点卖点：**

1. **恢复并超越** — 全屏网格、实时搜索、热角唤起；比当年 Launchpad 更干净、更快。
2. **一 App 双能力** — Launchpad 式启动器 + 轻量 Taskbar（按屏显示窗口、图标+标题、钉住），不必再装第二套常驻软件。
3. **极致内存** — C 核心 + AppKit；网格图标按需加载，任务栏独立小图标 cache，一份常驻吃下两种场景。

---

## 功能一览

### Launchpad 网格（恢复 + 增强）

- 扫描 `/Applications`、系统应用与用户应用，展示图标与名称
- 关键字实时过滤，打开即聚焦搜索
- 默认 7×5 网格，行列可配置
- 滚轮 / 触控板翻页
- 左上角热角唤起（需辅助功能权限）

### Taskbar（同 App 第二能力）

- 每块显示器底部一条轻量任务栏
- 按屏显示该屏窗口（图标 + 标题）
- 左键切换 / 软最小化；支持钉住常用应用
- 与网格共用同一进程，Overlay 打开时底栏自动让位

> 不做全能启动器（不与 Raycast / Alfred 比插件生态）。**主打：找回并超越 Launchpad + 轻量 Taskbar + 极致内存。**

---

## 快速体验

### 从源码构建（开发者）

无需完整 Xcode，Command Line Tools + clang 即可：

```bash
./Scripts/build_core.sh   # 仅 Core C 冒烟
./Scripts/build.sh        # 产出 build/MeoLaunch.app
./Scripts/run.sh          # open 应用（菜单栏显示 ML）
```

### 一键发布并安装到应用程序

```bash
./Scripts/release_install.sh
```

会编译 Release、adhoc 签名、退出旧进程，并安装到 `/Applications/MeoLaunch.app`，然后自动打开。

```bash
./Scripts/release_install.sh --no-open          # 安装但不启动
INSTALL_DIR="$HOME/Applications" ./Scripts/release_install.sh  # 装到用户 Applications
```

### 打包成安装包（DMG / ZIP）

```bash
./Scripts/package.sh                 # 默认本机架构
./Scripts/build.sh --universal && ./Scripts/package.sh --no-build   # Universal
./Scripts/ci_package.sh 0.1.0        # 写版本 + Universal + DMG/ZIP + SHA256
```

产出：

- `dist/MeoLaunch-<version>.dmg` — 含 `MeoLaunch.app` + **「一键安装并授权.command」**
- `dist/MeoLaunch-<version>.zip` — 仅应用包（解压后拖到应用程序文件夹）
- CI 额外：`MeoLaunch-<version>-macos-universal.{dmg,zip}` + `SHA256SUMS.txt`

**无 Developer ID 时推荐用户流程：** 打开 DMG → 双击「一键安装并授权」（若被拦截则右键 → 打开）→ 输入本机管理员密码 → 自动安装到「应用程序」、清除隔离标记，并尝试授权辅助功能。

```bash
./Scripts/package.sh --no-build   # 复用已有 build/MeoLaunch.app
open dist/MeoLaunch-*.dmg         # 预览安装盘
```

若有 Developer ID：

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/package.sh
```

有 Xcode + XcodeGen 时：

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme MeoLaunch -configuration Debug
```

若一键授权未能写入 TCC（较新 macOS 常见）：系统设置 → 隐私与安全性 → **辅助功能**，勾选 MeoLaunch。

### GitHub Actions 自动发布

推送版本 tag 即触发 Universal 打包并创建 [GitHub Release](../../releases)：

```bash
git tag v0.1.0
git push origin v0.1.0
```

也可在 Actions 里手动跑 **Release** workflow。同一 Release 会附带：

| 资产 | 说明 |
|------|------|
| `MeoLaunch-*-macos-universal.dmg` / `.zip` | macOS 13+（arm64 + x86_64） |
| `SHA256SUMS.txt` | 校验和 |
| `meolaunch-website-*.zip` | 官网静态站产物（可解压到 `/meolaunch/`） |

仓库 Secrets（可选，用于 Developer ID 签名 / 公证）：

| Secret | 用途 |
|--------|------|
| `APPLE_CERTIFICATE_BASE64` | Developer ID `.p12` 的 base64 |
| `APPLE_CERTIFICATE_PASSWORD` | 证书密码 |
| `APPLE_API_KEY_BASE64` | App Store Connect API `.p8` 的 base64 |
| `APPLE_API_KEY_ID` / `APPLE_API_ISSUER` | API Key 元数据 |
| 或 `APPLE_ID` + `APPLE_APP_SPECIFIC_PASSWORD` + `APPLE_TEAM_ID` | 账号公证 |

未配置证书时使用 ad-hoc 签名，仍可发 Release 供下载。
---

## 给 Star / 反馈

如果觉得有用，欢迎点右上角 **Star**，让更多人在没有 Launchpad 的 macOS 上，用一份极致内存同时拥有网格启动 + Taskbar。

- Bug / 想法：欢迎开 [Issue](../../issues)
- 增长与路线图：[半年增长与变现计划](./doc/14-growth-6m.md)

---

## 技术栈（摘要）

**C 核心**（扫描 / 过滤 / 网格）+ **Objective-C / AppKit**（窗口 / 事件 / 图标 / Taskbar）  
不用 Electron / WebView / SwiftUI。

平台：macOS 13+（优先 Apple Silicon，兼容 Intel）。

## 方案文档

完整设计见 [`doc/`](./doc/)：

- [总览](./doc/00-overview.md)
- [技术选型](./doc/01-tech-stack.md)
- [架构](./doc/02-architecture.md)
- [功能规格](./doc/03-features.md)
- [实现路径](./doc/04-implementation.md)
- [工程结构](./doc/05-project-structure.md)
- [配置 Schema](./doc/06-config-schema.md)
- [Agent Playbook（自动化）](./doc/07-agent-playbook.md)
- [底部任务栏](./doc/10-taskbar.md)
- [内存与性能](./doc/12-memory-perf.md)
- [半年增长与变现计划](./doc/14-growth-6m.md)

## 自动化开发

对 Agent 说「继续自动化」→ 按 [`doc/07-agent-playbook.md`](./doc/07-agent-playbook.md) 执行下一个 `pending` 任务卡。

当前 **M0–M5 均已完成**（MVP 闭环）。后续可自行打磨体验或加功能。
