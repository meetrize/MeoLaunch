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
| M0 | 工程可编译运行 | 菜单栏有图标 |
| M1 | 扫描 + 网格展示 | `/Applications` 图标可见，可点击启动 |
| M2 | 搜索 + 7×5 + 滚轮翻页 | 三功能联调通过 |
| M3 | 触发角 + 快捷键 | 左上角可唤起；权限引导完整 |
| M4 | 配置持久化 + 设置窗 | 改行列重启后仍在 |
| M5 | 打磨 | 内存采样达标、动画、多屏 |

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
