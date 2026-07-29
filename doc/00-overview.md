# meoLaunch — macOS Launchpad 替代方案总览

> 目标：内存占用极低、响应极快的原生 Launchpad 替代应用。

## 结论（一句话）

采用 **C 核心逻辑 + Objective-C/AppKit 薄 UI 层**，用 AppKit 透明全屏窗口做网格，用全局鼠标监听做触发角，配置落本地 plist/JSON。

## 文档索引

| 文档 | 内容 |
|------|------|
| [01-tech-stack.md](./01-tech-stack.md) | 语言选型对比与最终推荐 |
| [02-architecture.md](./02-architecture.md) | 模块划分、进程模型、数据流 |
| [03-features.md](./03-features.md) | 功能规格（应用列表、布局、翻页、触发角） |
| [04-implementation.md](./04-implementation.md) | 关键实现路径、API、权限、坑点 |
| [05-project-structure.md](./05-project-structure.md) | 目录结构、构建方式、里程碑 |
| [06-config-schema.md](./06-config-schema.md) | 配置文件格式与默认值 |
| [07-agent-playbook.md](./07-agent-playbook.md) | 自动化开发任务卡与 Status |
| [08-layout-folders.md](./08-layout-folders.md) | 拖动排序与目录分组设计 + 开发计划 |

## 产品定位

| 维度 | 选择 |
|------|------|
| 平台 | macOS 13+（优先支持 Apple Silicon，兼容 Intel） |
| 形态 | 常驻菜单栏/后台 Agent + 按需全屏 Overlay |
| 交互 | 触发角 / 快捷键 / Dock 图标（可选）打开 |
| 风格 | 轻量、无 WebView、无 Electron、无 SwiftUI 重依赖 |

## 核心功能（MVP）

1. 扫描应用目录，展示已安装应用图标与名称，支持关键字过滤
2. 默认 **7×5** 网格，行列数可配置
3. 鼠标滚轮翻页（横向页切换）
4. 触发角：默认左上角移入即唤起

## 非目标（首期不做 / 已调整）

- iCloud / App Store 同步布局
- 文件夹嵌套（文件夹内再建文件夹）— 单层分组见 [08-layout-folders.md](./08-layout-folders.md)
- 多显示器复杂策略（首期：当前鼠标所在屏）
- 插件系统、主题商店

## 成功指标

| 指标 | 目标 |
|------|------|
| 常驻内存（未打开 Overlay） | ≤ 15–25 MB |
| Overlay 打开峰值 | ≤ 40–60 MB |
| 触发角 → 首帧可见 | ≤ 80–120 ms |
| 冷启动扫描（~200 个 App） | ≤ 300 ms（图标异步） |
| 关键字过滤 | ≤ 16 ms（纯内存字符串匹配） |
