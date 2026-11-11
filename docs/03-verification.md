---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: e72c8dc5665511fde1d076a99e405c04_fe4c2d91ddc511f19280525400393706
    ReservedCode1: RP4/eIETjhugzUFvMLeDX9jeYPb8YNIjUwD0XTZo1I85DvMuqyrI4ZhwR9m4bOJ4VrI2HKVDQqwflm+Czwuxbd2GZ+jGtlXs+y07X7ZRmaE/3XKDqAnVRVKeirnHP0jgqpsfyDSxYmRehSHQ6IRjLYUGHWk3B0SpOTozbTt77iqtbf8d4YP1T6O/fZQ=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: e72c8dc5665511fde1d076a99e405c04_fe4c2d91ddc511f19280525400393706
    ReservedCode2: RP4/eIETjhugzUFvMLeDX9jeYPb8YNIjUwD0XTZo1I85DvMuqyrI4ZhwR9m4bOJ4VrI2HKVDQqwflm+Czwuxbd2GZ+jGtlXs+y07X7ZRmaE/3XKDqAnVRVKeirnHP0jgqpsfyDSxYmRehSHQ6IRjLYUGHWk3B0SpOTozbTt77iqtbf8d4YP1T6O/fZQ=
---



# 03 · 设备验证与实测数据

设备：iPhone Air（iPhone18,4），iOS 26.3.1，A19 Pro GPU。

## 1. 启动日志（成功）

```
[gamelib] linked in (105374 + 34472 functions)
[platform] guest memory 0x400000000..0x720000000 reserved ok
loaded main  at 400000000 size 2e74000 syms 947
loaded sdk   at 404000000 size cd4000 syms 25091
[metal] Apple A19 Pro GPU, heap buffer 3328 MB
[nvn] device initialized
[metalfx] 1920x1080 -> 2240x1260 (ok)
[metal] t=7.5  frame 146  59.9 fps  mem 1385 MB (5270 left)
[metal] t=15.0 frame 897  60.0 fps  mem 1385 MB (5268 left)
```

判读要点：

| 行 | 含义 | 判据 |
|---|---|---|
| `guest memory ... reserved ok` | 12.8 GiB 窗口落位成功 | 修复生效的最直接证据 |
| `loaded main at 400000000` | main NSO 按新基址映射 | 生成代码基址正确 |
| `loaded sdk at 404000000` | sdk 紧接其后（偏移 `0x4000000`） | 派生常量同步平移 |
| `loaded main size 2e74000` | 46.4 MB，与 Mac 端一致 | 数据完整，无截断 |
| `[nvn] device initialized` | Switch 图形 API → Metal 桥接成功 | 渲染链路通 |
| `[metalfx] ... -> 2240x1260` | 超分生效 | 实际输出分辨率 |
| `59.9/60.0 fps` | 满帧 | 性能达标 |

## 2. 内存占用

```
mem 1385 MB (5270 left)   → 进程上限 ≈ 1385 + 5270 ≈ 6655 MB
mem 2431 MB (4224 left)   → 场景切换后（大关卡/多人素材）
```

- 单进程上限约 **6.7 GB**，此为 `increased-memory-limit` 生效后的额度（A19 Pro / 12 GB 机型）。
- 无 entitlement 时上限约 3 GB，2.4 GB 峰值已接近临界，因此**该 entitlement 是硬性要求**。
- 报错文案里的 "will be limited to 1.3 GB" 实际未出现，说明 entitlement 已被内核采纳。

## 3. 对照实验（证明因果）

| 变量 | 结果 |
|---|---|
| 旧基址 `0x7000000000` + 全套 entitlement | 启动失败，报 memory window |
| 新基址 `0x400000000` + 同签名同 profile | 正常启动，60 fps |
| 新基址 `0x400000000` + 无 `increased-memory-limit` | 启动后加载大关卡被 jetsam 杀 |
| 数据目录缺失 | `FATAL: cannot load extracted/exefs/main`（与新 bug 无关，另一类错误） |

由此确认：**窗口落位**与**内存额度**是两个独立条件，缺一不可；本次 bug 只解决前者。

## 4. 功能验证清单

- [x] 标题画面、存档读取
- [x] 关卡编辑（触摸 = 指针映射，摇杆/按钮虚拟按键可用）
- [x] 关卡游玩，60 fps 稳定
- [x] 音效与 BGM 输出正常
- [x] 前后台切换后恢复渲染
- [x] 长时游玩（> 30 min）无 jetsam、无金属命令缓冲泄漏

## 5. 已知限制

- 首次启动需要写入 shader cache，约 10–20 s 黑屏，属正常。
- 部分机型（内存 8 GB 以下 iPad / iPhone）在大型关卡可能触碰 jetsam，建议用 `0x300000000` 基址（窗口更靠低端，系统预留更多）观察。
- 未实现手柄热插拔重连，需重启 App。
