# meoLaunch

macOS Launchpad 替代应用——极低内存、原生 AppKit（C 核心 + Objective-C UI）。

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

## 技术栈（摘要）

**C 核心**（扫描 / 过滤 / 网格）+ **Objective-C / AppKit**（窗口 / 事件 / 图标）  
不用 Electron / WebView / SwiftUI。

## 构建（M0）

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

有 Xcode + XcodeGen 时：

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme MeoLaunch -configuration Debug
```

## MVP 功能

1. 展示 Applications 中的应用，关键字过滤  
2. 默认 7×5 网格，可配置  
3. 滚轮翻页  
4. 左上角触发角唤起（需辅助功能权限）

## 自动化开发

对 Agent 说「继续自动化」→ 按 [`doc/07-agent-playbook.md`](./doc/07-agent-playbook.md) 执行下一个 `pending` 任务卡。

当前 **M0–M5 均已完成**（MVP 闭环）。后续可自行打磨体验或加功能。
