# P1 可执行 Plan — Active 内存与二次打开

> 状态：**已完成**（2026-07-31）  
> 源自 [12-memory-perf.md](./12-memory-perf.md) §4 P1

## 已落地

| ID | 项 | 做法 |
|----|----|------|
| P1-1 | 文件夹合成图 LRU | `MLGridView`：key=`id|WxH`，≤16；仅完整合成才缓存；reload/setLayout 清空 |
| P1-2 | Overlay hide 延迟 purge | hide 后 **30s** 再 `purge`；再 show 取消；generation 防竞态 |
| P1-3 | Prefetch 仅当前页 | `prefetchVisibleIcons` 不再预取 ±1 页 |
| P1-4 | 清理缺口 | `MLIconCache.purge` 清 inflight + generation；hide 释放 `filterIndices`；taskbar `stop` 清 `displayNameCache` |

## 验收

- `./Scripts/build.sh` 通过  
- 关 Overlay 后立刻再开：图标应仍暖（30s 内）  
- Idle 30s+ 后再开：会重新加载图标  

## 下一阶段

P2：Monitor 后台 snapshot、AX 合并、AppIndex 后台扫、Prefs 调参
