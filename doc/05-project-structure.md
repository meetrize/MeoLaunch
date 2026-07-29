# 05 — 工程结构与里程碑

## 1. 建议仓库布局

```
meoLauch/
├── doc/                          # 本方案文档
│   ├── 00-overview.md
│   ├── 01-tech-stack.md
│   ├── 02-architecture.md
│   ├── 03-features.md
│   ├── 04-implementation.md
│   ├── 05-project-structure.md
│   └── 06-config-schema.md
├── MeoLaunch.xcodeproj/          # 或 Package + xcodeproj
├── Sources/
│   ├── App/
│   │   ├── main.m
│   │   ├── AppDelegate.h/.m
│   │   └── Info.plist
│   ├── Core/                     # 纯 C
│   │   ├── ml_app_index.c/.h
│   │   ├── ml_grid.c/.h
│   │   ├── ml_filter.c/.h        # 可并入 app_index
│   │   └── ml_util.c/.h
│   ├── UI/
│   │   ├── MLOverlayController.h/.m
│   │   ├── MLGridView.h/.m
│   │   ├── MLSearchField.h/.m
│   │   ├── MLPageIndicator.h/.m
│   │   └── MLPrefsWindow.h/.m
│   ├── System/
│   │   ├── MLHotCornerMonitor.h/.m
│   │   ├── MLHotKeyManager.h/.m
│   │   ├── MLIconCache.h/.m
│   │   └── MLConfigStore.h/.m
│   └── Resources/
│       ├── Assets.xcassets
│       └── Base.lproj/
├── Scripts/
│   ├── build.sh
│   └── notarize.sh
└── README.md
```

## 2. 构建方式

### 方式 A（推荐）：Xcode

- Target：`MeoLaunch` (macOS App)
- Compile Sources：所有 `.c` / `.m`
- Linking：`AppKit`、`ApplicationServices`、`Carbon`（若用热键）
- Deployment Target：macOS 13.0

### 方式 B：命令行快速验证 Core

```bash
clang -std=c11 -O2 -c Sources/Core/*.c
# 单测 filter / grid 的纯 C 测试，不链 AppKit
```

UI 仍建议 Xcode 调试视图与权限弹窗。

## 3. 里程碑

| 里程碑 | 交付物 | 验收 |
|--------|--------|------|
| M0–M5 | 见前文 | 已完成 |
| **M6** | Layout 持久化 + 主网格按序展示 | 已完成 |
| **M7** | 拖拽排序 | 已完成 |
| **M8** | 合并成组 + 命名 + 文件夹视图 | 已完成 |
| **M9** | 拖出 / 单元素解散 / 打磨 | 组内拖出到外部回 root；剩 1 个自动解散 |
| M7 | 拖拽排序 | 见 [08-layout-folders.md](./08-layout-folders.md) |
| M8 | 分组 + 命名 | 同上 |
| M9 | 拖出 / 解散 | 同上 |

## 4. 如何开始动手（建议顺序）

1. 读完 `01`–`03`，冻结 MVP 范围  
2. 建 Xcode 工程与上述目录  
3. 先写 `ml_grid` + 单元测试（纯 C）  
4. 写 `ml_app_index_scan`，命令行打印应用名验证  
5. 做 `MLGridView` 静态假数据  
6. 接上真实扫描与 IconCache  
7. 搜索与翻页  
8. HotCorner + 权限  
9. Config / Prefs  
10. 性能与内存 Instruments 过一遍  

## 5. Instruments 关注点

- **Allocations**：Idle / Active 各采一次
- **Time Profiler**：`scrollWheel`、过滤、首次 show
- **Leaks**：反复打开关闭 Overlay 100 次

## 6. 协作约定

- C 层零 ObjC 类型，便于测试与未来换 UI 壳
- ObjC 文件前缀 `ML`
- C 符号前缀 `ml_`
- 不引入 CocoaPods/SPM 依赖（MVP）
