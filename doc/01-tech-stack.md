# 01 — 技术选型

## 1. 需求对技术的约束

| 约束 | 含义 |
|------|------|
| 内存最省 | 禁止 Electron / Tauri WebView / 多进程 Chromium |
| 响应最快 | 冷路径少、图标懒加载、UI 直接走 AppKit/CoreGraphics |
| 系统能力 | 需要：读 `.app`、取图标、全局鼠标、全屏透明窗、启动 App |
| 可维护 | 纯 C 写完整 Cocoa UI 成本过高，不可取 |

## 2. 候选方案对比

| 方案 | 内存 | 速度 | 开发成本 | 系统集成 | 结论 |
|------|------|------|----------|----------|------|
| **C + ObjC/AppKit** | 最优 | 最优 | 中 | 原生完美 | **采用** |
| 纯 C + CoreGraphics | 最优 | 优 | 极高 | 差（事件/窗口难） | 不采用 |
| Swift + AppKit | 优 | 优 | 低 | 完美 | 备选 |
| Swift + SwiftUI | 中 | 中 | 最低 | 好 | 不采用（内存/启动偏重） |
| Rust + objc crate | 优 | 优 | 高 | 好 | 备选（团队熟悉 Rust 时） |
| Electron / Tauri | 差 | 差 | 低 | 一般 | 明确拒绝 |
| Python / Qt | 差/中 | 中 | 中 | 一般 | 拒绝 |

## 3. 最终推荐：C 核心 + Objective-C 壳

### 分层职责

```
┌─────────────────────────────────────────┐
│  meoLaunch UI (Objective-C / AppKit)    │  窗口、绘制、事件、图标显示
├─────────────────────────────────────────┤
│  meoLaunch Core (纯 C)                  │  扫描、过滤、分页、配置、触发角几何
├─────────────────────────────────────────┤
│  macOS Frameworks                       │  AppKit, Foundation, CoreGraphics,
│                                         │  ApplicationServices, Carbon(可选)
└─────────────────────────────────────────┘
```

### 为什么不是「纯 C」

macOS 上要做 Launchpad 级体验，几乎必须碰：

- `NSWindow` / `NSView`（全屏 overlay、点击穿透控制）
- `NSWorkspace`（启动应用、图标）
- `NSEvent` / `CGEventTap`（全局鼠标、滚轮）
- `NSRunningApplication` / Launch Services

这些 API 的官方入口是 Objective-C / Swift。用纯 C 调 objc runtime 可行，但可读性与调试成本远高于「C 做算法 + ObjC 做 UI」。

### 为什么不是 Swift 为主

Swift 完全可行，且开发更快。但相对 ObjC：

- 运行时与元数据略重
- ARC / 协议见证表带来一点常驻开销
- 与「最省内存」目标略冲突

若后续团队更熟 Swift，可将 UI 层迁到 Swift，**C 核心保持不变**（通过 bridging header / module map 暴露）。

## 4. 关键依赖（尽量零第三方）

| 能力 | 系统 API |
|------|----------|
| 应用枚举 | `NSFileManager` 扫目录 + `NSBundle` / Launch Services |
| 图标 | `NSWorkspace.iconForFile` / `QLThumbnail`（必要时） |
| 启动 | `NSWorkspace.openApplicationAtURL` |
| 全局鼠标 | `CGEventTap` 或 `NSEvent.addGlobalMonitorForEvents` |
| 滚轮 | Overlay 内 `scrollWheel:` 或全局 tap 过滤 |
| 配置 | `~/Library/Application Support/meoLaunch/config.json` |
| 自动启动 | LaunchAgent plist（可选） |

**原则：零第三方库。** 如后期需要 JSON，可用极薄的自研 parser，或仅依赖系统 `NSJSONSerialization`（ObjC 层）。

## 5. 编译与工具链

- Xcode 15+ / `clang`
- Target：`arm64` + `x86_64`（Universal 可选）
- 构建：`xcodebuild` 或 Makefile + `clang` 混编
- 语言标准：C11；ObjC：`-fobjc-arc`

## 6. 权限模型

| 权限 | 用途 | 是否必须 |
|------|------|----------|
| Accessibility（辅助功能） | 全局鼠标监听、可靠触发角 | **MVP 必须** |
| Input Monitoring | 若用 `CGEventTap` 某些路径 | 视实现而定 |
| 通知（可选） | 权限引导 | 可选 |
| Full Disk Access | 一般不需要 | 否 |

首次启动应引导用户打开「系统设置 → 隐私与安全性 → 辅助功能」。

## 7. 命名

应用名建议：**meoLaunch**（与仓库 `meoLauch` 拼写差异可在产品名上统一为 Launch）。

Bundle ID 建议：`com.meetrice.meolaunch`
