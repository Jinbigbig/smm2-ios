---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: e72c8dc5665511fde1d076a99e405c04_8e6aebedddb611f19280525400393706
    ReservedCode1: P/IM3ms7q1OWSmPJm39RubA9e8g1Va6X3UKNYh3b5VOmbGcR6eKyBobQiK7XhU+pcenkpguA8un7ln3Jh+NlvOpfSiIlN80TuQHNv6O6xnPRzGRP5F+q5lWPS81/KiqWdpC4+TCYe4R+qmZmoEPtBYllud/+UqBT2TFNSg4YF55eYzSKe03p7LWWD28=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: e72c8dc5665511fde1d076a99e405c04_8e6aebedddb611f19280525400393706
    ReservedCode2: P/IM3ms7q1OWSmPJm39RubA9e8g1Va6X3UKNYh3b5VOmbGcR6eKyBobQiK7XhU+pcenkpguA8un7ln3Jh+NlvOpfSiIlN80TuQHNv6O6xnPRzGRP5F+q5lWPS81/KiqWdpC4+TCYe4R+qmZmoEPtBYllud/+UqBT2TFNSg4YF55eYzSKe03p7LWWD28=
---

# 05 · FAQ 与可选配置

## Q1 换基址后存档/数据要不要重做？
不要。guest 窗口只是宿主侧地址，游戏数据内容不变。但**生成代码必须重新 gen**。

## Q2 能不能不重编，只 patch 二进制？
不可行。基址常量分散在 runtime 与 979 个生成文件里，涉及多条 `movz/movk` 与常量池，长度与重定位都不同；即便全改，`gen` 阶段的地址运算也已按旧基址折算了索引。必须重编。

## Q3 为什么是 12.8 GiB 窗口？
`GUEST_HI - GUEST_ORIGIN = 0x320000000`，由 recomp runtime 的内存布局决定（main + sdk + heap + alias + TLS）。这是编译期固定值，不能简单缩小。

## Q4 其它机型该选哪个基址？

| 设备内存 | 建议基址 | 说明 |
|---|---|---|
| ≥ 12 GB（Pro/Air 新机） | `0x400000000` | 本次验证值 |
| 8 GB（iPad Air 5 / 旧 Pro） | `0x300000000` | 窗口 `0x300000000..0x620000000`，余量最大 |
| 6 GB 及以下 | 不建议 | 内存额度不足，必被 jetsam |

自行验证方法：编一个探针 App 跑 `mmap(MAP_FIXED|MAP_NORESERVE)` 扫边界，找本机真正上限。

## Q5 `0x800000000` 行不行？
探针 OK（32 GiB），但整段窗口到 `0xA20000000`，接近实测上限，系统版本/机型变化风险高。除非确认过 `0x1000000000` 才失败，否则优先 `0x400000000`。

## Q6 需要哪些 entitlement？

```
com.apple.developer.kernel.extended-virtual-addressing      # 抬高 VA 上限（必需）
com.apple.developer.kernel.increased-memory-limit           # 抬高内存额度（必需，约 6.7 GB）
com.apple.developer.kernel.increased-debugging-memory-limit # 调试用（可选）
```

三者均需落在**显式 App ID** 的 provisioning profile 里。

## Q7 一定要付费开发者账号吗？
是。kernel entitlement 只对付费账号的显式 App ID 开放，免费账号无法申请。

## Q8 编译机配置要求？
8 GB 内存可编（约 1.5–2 小时，用 swap），建议 16 GB 以上。磁盘需 ≥ 20 GB：`generated/` 约 4 GB、`build/` 约 8 GB、App + IPA 约 6 GB。

## Q9 能出 arm64 模拟器版调试吗？
`TARGET=ios-arm64` 是设备版；模拟器需另建 `ios-sim` 目标并重编依赖库，且模拟器无 NVN/Metal 低层对接，不建议作为调试路径——直接用真机 + 日志。

## Q10 为什么 Web 上搜不到这套结论？
recomp 类项目的 iOS 移植是小众路径，`GUEST_ORIGIN` 硬编码问题只在真机上暴露，Mac/Linux 端（VA 空间 47 bit/128 TB）永远踩不到。
*（内容由AI生成，仅供参考）*
