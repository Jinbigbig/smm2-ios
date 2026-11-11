---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: e72c8dc5665511fde1d076a99e405c04_fc6851f9ddc511f19232525400248c00
    ReservedCode1: H/ipJ2p6kxrcMALFqMapPVX+RT4RzubpA3Yo0B+AB5RM7tIaYTMWeV7QRXpXlxCrWYZcBzYpayZbavsrbkY6swIxBiy0YUiLCv8oBFdmgejoEw32vudhLAVkuY8ZcKZ/aYXqEU1jIsKm1AQJLcuu+KHt/wzbEs5WZq+wLNEQWgY+/18PxpKGbtjtlEc=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: e72c8dc5665511fde1d076a99e405c04_fc6851f9ddc511f19232525400248c00
    ReservedCode2: H/ipJ2p6kxrcMALFqMapPVX+RT4RzubpA3Yo0B+AB5RM7tIaYTMWeV7QRXpXlxCrWYZcBzYpayZbavsrbkY6swIxBiy0YUiLCv8oBFdmgejoEw32vudhLAVkuY8ZcKZ/aYXqEU1jIsKm1AQJLcuu+KHt/wzbEs5WZq+wLNEQWgY+/18PxpKGbtjtlEc=
---

# 00 · 技术原理（完整版）

本文解释三件事：**为什么这段代码必须把 guest 放在某个固定虚拟地址**、**为什么 iOS 上这个地址不能是 448 GiB**、**为什么修复只能落在编译期**。

---

## 1. 静态重编译的地址模型

Switch 游戏的可执行体是 NSO 格式（`exefs/main`、`exefs/sdk`、`exefs/rtld`），本质是 aarch64 PE 式镜像。smm2recomp 不模拟指令，而是做 **AOT 静态重编译（static recompilation）**：

```
exefs/main + exefs/sdk
        │  capstone 反汇编 + unicorn 辅助求值，构建 CFG
        ▼
gen.py  →  generated/smm2/main/*.c        （每个 guest 函数 → 一个 C 函数）
        │  clang -O2 -arch arm64
        ▼
宿主原生 arm64 机器码（与 runtime 一起链接成可执行文件）
```

关键设计：**guest 与 host 共用同一个地址空间**。生成的 C 代码里，guest 访问 `0x100000` 这样的地址，会被写成：

```c
// 生成代码示意
uint32_t v = *(uint32_t *)(GUEST_ORIGIN + 0x100000ull);
```

于是 `GUEST_ORIGIN` 是一个**编译期整型常量**，被常量折叠进指令（`movz/movk` 序列或 `.quad` 常量池）。这带来两个直接后果：

1. 性能接近原生（没有地址翻译、没有分页表模拟）；
2. **基址一旦变化，所有已生成的机器码全部失效**，必须重新 `gen` 再编译。

对应源码位置：

| 位置 | 内容 |
|---|---|
| `recomp/runtime/rt.h` | `#define GUEST_ORIGIN 0x7000000000ull`，派生出 `GUEST_LO`/`GUEST_HI`/`MAIN_BASE`/`SDK_BASE`… |
| `recomp/Makefile` | `GUEST_ORIGIN ?= 0x7000000000`；`gen` 与 `app` 目标都把它透传；产物目录追加基址后缀 |
| `tools/gen.py` | 以 `GUEST_ORIGIN` 为基准生成常量表达式（main 用原值，sdk 用 `+0x4000000`） |

## 2. guest 内存布局

`rt.h` 里的布局（所有值相对基址）：

| 区域 | 偏移 | 用途 |
|---|---|---|
| `MAIN_BASE` | `+0x000000000` | 游戏主模块 main NSO |
| `SDK_BASE` | `+0x004000000` | sdk NSO（含 NVN/HID/FS 等系统库实现） |
| `HLE_BASE` | `+0x080000000` | HLE 桩、合成数据结构 |
| `TLS_BASE` | `+0x090000000` | guest 线程局部存储 |
| `HLE_HEAP` | `+0x092000000` | HLE 侧堆 |
| `ALIAS_BASE` | `+0x100000000` | 别名映射区（批量拷贝/影子页） |
| `HEAP_BASE` | `+0x240000000` | guest 堆起点，`HEAP_MAX = 0xD0000000`（3.25 GiB） |
| `GUEST_HI` | `+0x320000000` | 窗口终点，总长 **12.8 GiB** |

这些偏移在生成代码中大量以**立即数**出现（例如 `main` 调用 `sdk` 函数就是 `bl (SDK_BASE + off)`），所以**不能只移动其中一块**——整段必须整体平移，且必须连续。

## 3. 为什么必须一次性预留 12.8 GiB 连续空间

`recomp/runtime/main.c` 里有一个 `constructor(101)`（早于 `main`、早于大多数初始化）：

```c
static void reserve_guest_space(void) {
    plat_reserve_guest(GUEST_LO, GUEST_HI);   // 一次性、整段、固定地址
}
```

`plat_reserve_guest` 的实现（`runtime/platform/macos.c`，iOS 复用该文件）：

```c
kern_return_t kr = mach_vm_allocate(mach_task_self(), &addr, hi - lo, VM_FLAGS_FIXED);
```

三个语义要点：

- `VM_FLAGS_FIXED`：**必须**放在 `lo` 处，内核不做重定位。若该区间已被占用、或超出进程 VA 上限 → 返回 `KERN_INVALID_ARGUMENT`（日志里的 `kern 12` / `errno=12`）。
- 整段申请：因为内部所有偏移都是相对基址的常量，任何一段落位失败都会让后续所有指针失效，所以只能"全有或全无"。
- 之后的 `plat_commit` 是空操作、`plat_protect` 才按需 `PROT_READ|PROT_WRITE` —— 也就是**先只占虚拟地址，物理页按访问逐页分配**（类似 `MAP_NORESERVE`）。这就是为什么 12.8 GiB 窗口在只占 2.4 GB 内存的情况下能跑起来。

失败后的兜底策略体现了平台差异：

```c
#if TARGET_OS_IPHONE || __ANDROID__
    g_guest_unreserved = true;      // 移动端不允许自我 re-exec，只能继续并报告
    return;
#else
    // macOS/Linux：设置环境变量后 exec 自身重试，最多 20 次（LARECOMP_REEXEC）
#endif
```

macOS 上 20 次重试几乎总能找到一段空闲区，这也是"Mac 上好好的、iOS 上一启动就炸"的原因之一：**macOS 从来没暴露这个 bug**。

## 4. iOS 的虚拟地址上限

### 4.1 VA 尺寸由内核决定，不由物理内存决定

arm64 用户态 VA 位数由内核 `T0SZ` 决定。iOS 默认给普通 App 的可用高地址区间远小于 macOS 的 47 bit 空间；携带 `com.apple.developer.kernel.extended-virtual-addressing` 时，内核会为该进程放宽 VA 上限（本质是给该进程一张更大的页表/更多页表层级），但**不是无限**。

实测（iPhone Air / iOS 26.3.1 / A19 Pro，带三项 kernel entitlement）：

| 请求 | 换算 | 256 MiB 单点探针 | 12.8 GiB 整窗 |
|---|---|---|---|
| `0x100000000` | 4 GiB | OK | — |
| `0x200000000` | 8 GiB | OK | — |
| `0x300000000` | 12 GiB | OK | **OK** |
| `0x400000000` | 16 GiB | OK | **OK** |
| `0x600000000` | 24 GiB | OK | — |
| `0x800000000` | 32 GiB | OK | 未验证（终点 40.5 GiB） |
| `0x1000000000` | 64 GiB | **FAIL errno=12** | — |
| `0x2000000000` | 128 GiB | FAIL | — |
| `0x4000000000` | 256 GiB | FAIL | — |
| `0x7000000000` | 448 GiB | FAIL | — |

同时，同一进程用 `mmap(NULL, 12.8 GiB, NORESERVE)` 能成功（内核回填到 `0x300000000`）。这排除了"物理内存不足"与"单次申请过大"两种解释，把问题锁死为**基址越界**。

结论：本机进程 VA 上限落在 `0x800000000`（32 GiB）与 `0x1000000000`（64 GiB）之间，量级约 35～36 GiB。

### 4.2 为什么上游选了 448 GiB

上游注释给出的理由是：iOS 保留 `0x2ee000000 .. 0x7000000000` 给 dyld shared cache 与系统库，而 macOS 上 47 bit 空间里 `0x7000000000` 是"第一个足够大的空闲洞"。这个结论对 macOS 成立，对 iOS 不成立——**iOS 根本走不到那里**。这就是 bug 的本质：一个在桌面端永远成立的假设，被无条件带到了移动端。

### 4.3 一个"看起来像签名"的错误

`main.c` 在时机上无法区分"没有 entitlement"与"地址超界"，两种情况都会让 `mach_vm_allocate` 失败，于是失败路径统一打印：

```
... it must be signed with the Extended Virtual Addressing and Increased Memory Limit entitlements.
```

这句话把排查引向签名侧，属于兜底文案的**归因错误**。判定依据必须看日志里的 `kern 12` 与 `plat_guest_report` 打印的地址/上限：

```
[platform] guest memory 0x7000000000..0x7320000000 not reserved (kern 12)
[platform] address space 0x...  footprint 1385 MB, limit 6655 MB
```

## 5. 两个独立的内核资源：VA 与 footprint

| 资源 | 由什么 entitlement 控制 | 实测上限 | 耗尽后果 |
|---|---|---|---|
| 虚拟地址空间 | `extended-virtual-addressing` | ≈35 GiB | `mach_vm_allocate` 返回 `KERN_INVALID_ARGUMENT`，立刻失败 |
| 物理内存 footprint | `increased-memory-limit` | ≈6.7 GB（12 GB 机型） | jetsam 杀进程，运行中崩溃 |

`increased-memory-limit` 抬高的是 jetsam 对 `task_phys_footprint` 的阈值（普通 App 约为物理内存的 45%～60%，带 entitlement 可到 ~6.7 GB）。二者不可互相替代：

- 只有 VA 权限、没有内存权限 → 窗口能预留，加载大关卡时被 jetsam 杀；
- 只有内存权限、没有 VA 权限 → 连窗口都预留不了。

设备实测：`mem 1385 MB (5270 left)` → 1385 + 5270 ≈ 6655 MB，与 entitlement 生效后的额度吻合；峰值 2431 MB 仍在余量内。

## 6. 时间与空间成本

| 项 | 数值 |
|---|---|
| 生成代码规模 | main 804 chunks + sdk 175 chunks = 979 个 C 文件 |
| 函数数 | main 105374 + sdk 34472 = 139846 |
| 生成耗时 | main 138 s + sdk 12 s（8 核） |
| 编译耗时 | `-j8` 约 1.5–2 h（内存 8 GB 会跑 swap） |
| 生成代码 + 目标文件 | `generated/` ≈4 GB，`build/` ≈8 GB |
| guest 窗口 | 12.8 GiB 虚拟，实占 1.4–2.5 GB 物理 |

## 7. 渲染链路（为什么能 60 fps）

guest 侧调用的是 NVN（Switch 图形 API）。runtime 用 HLE 把 NVN 调用翻译到 Metal：

```
guest NVN calls → HLE 桩（HLE_BASE 区） → Metal / MetalFX
```

设备日志：

```
[metal] Apple A19 Pro GPU, heap buffer 3328 MB
[nvn] device initialized
[metalfx] 1920x1080 -> 2240x1260 (ok)
[metal] t=7.5 frame 146 59.9 fps mem 1385 MB (5270 left)
```

- 纹理 swizzle、格式转换走 compute shader；
- 1080p 内部渲染 + MetalFX 超分到 2240×1260，是帧率能满的直接原因；
- GPU 资源池 `heap buffer 3328 MB` 由 `increased-memory-limit` 额度支撑，没有该 entitlement 时这里会先失败。

## 8. 为什么修复只能在编译期（四种"省事方案"为何都不行）

| 方案 | 结论 | 原因 |
|---|---|---|
| 重签 / 换 profile / 加 entitlement | 无效 | VA 上限已放宽，仍放不下 448 GiB；地址是根因 |
| 运行期 `mmap` 后 patch 指针 | 不可行 | 指针常量已折叠进 979 个文件的指令与常量池，运行期无处可改 |
| 二进制 patch 立即数 | 不可行 | ARM64 `movz/movk` 序列长度随立即数变化，`0x70<<32` 与 `0x04<<32` 编码不同且散落在数十处；改完还要重签，等于重编 |
| `dyld` interpose / hook | 不可行 | 只能拦函数调用，改不了内联到指令里的地址常量 |
| **`make GUEST_ORIGIN=<新值> gen` + 重编** | **可行** | 上游 Makefile 已把基址参数化，是设计内的正路 |

## 9. 基址选型判据

窗口长 12.8 GiB，需满足：

```
base + 0x320000000 ≤ 实测 VA 上限
base 落在系统保留区之外
base 便于人类核对（建议 16 GiB 对齐，即 0xX00000000 形式）
```

| 基址 | 窗口终点 | 评价 |
|---|---|---|
| `0x300000000` | `0x620000000`（24.5 GiB） | 余量最大，8 GB 机型首选 |
| **`0x400000000`** | `0x720000000`（28.5 GiB） | **本次采用**，整窗实测通过 |
| `0x800000000` | `0xA20000000`（40.5 GiB） | 单点通过，整窗贴近上限，风险高 |

## 10. 判定流程图

```
启动失败 "can't reserve the game's memory window"
        │
        ├─ 日志有 kern 12 / errno=12 ?
        │     ├─ 否 → 查签名/CDHash/信任状态
        │     └─ 是 → 打印的地址是否高于本机 VA 上限？
        │              ├─ 是 → 改 GUEST_ORIGIN 重编（本文）
        │              └─ 否 → 该区间被占用（检查 ASLR/其他 library），换基址重编
        └─ 无日志 → 应用未启动，先查安装与 profile
```
