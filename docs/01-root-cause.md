---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: e72c8dc5665511fde1d076a99e405c04_fd0aee62ddc511f19232525400248c00
    ReservedCode1: V5YBohOIuWPqtULLYHHVp22fNiZMgcqxNP0qduTA+vWNOM/iZEfBms45CIwjiTCwQxM8hQ5DIr3QLuA3cA2lmFGVIvVbiAcOWPfJTu9+LY0w0d/UkIAlyXtqVd5uFl//qmjGaaZWpPbrMm6fYGfKc+amvb3lmH/ueRluqn6puhbfFeZpF4ZKNGATHws=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: e72c8dc5665511fde1d076a99e405c04_fd0aee62ddc511f19232525400248c00
    ReservedCode2: V5YBohOIuWPqtULLYHHVp22fNiZMgcqxNP0qduTA+vWNOM/iZEfBms45CIwjiTCwQxM8hQ5DIr3QLuA3cA2lmFGVIvVbiAcOWPfJTu9+LY0w0d/UkIAlyXtqVd5uFl//qmjGaaZWpPbrMm6fYGfKc+amvb3lmH/ueRluqn6puhbfFeZpF4ZKNGATHws=
---



# 01 · 根因排查

## 1. 症状

iOS 版 App 启动即弹：

```
This copy of SMMaker 2 can't reserve the game's memory window
(0x7000000000-0x7320000000): it must be signed with the Extended
Virtual Addressing and Increased Memory Limit entitlements.
```

设备上有短暂黑屏后退出，`Documents/smm2recomp.log` 里能看到：

```
[gamelib] linked in (105374 + 34472 functions)
[platform] guest memory 0x7000000000..0x7320000000 not reserved (kern 12)
```

`kern 12` = `KERN_INVALID_ARGUMENT` / `errno=12`（`Cannot allocate memory`）。

## 2. 第一轮误判：以为是签名

报错点名了 entitlement，于是先查签名侧：

**2.1 检查 profile 的 Entitlements**

```bash
security cms -D -i profile.mobileprovision > /tmp/prof.plist
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" /tmp/prof.plist
```

结果（节选）：

```xml
<key>com.apple.developer.kernel.extended-virtual-addressing</key><true/>
<key>com.apple.developer.kernel.increased-debugging-memory-limit</key><true/>
<key>com.apple.developer.kernel.increased-memory-limit</key><true/>
<key>application-identifier</key><string>TEAMID0000.app.example.smm2</string>
```

显式 App ID（非通配符），三项 kernel entitlement 齐备。

**2.2 检查二进制内是否携带**

早期发现 `SMM2Recomp.app` 二进制里**没有 DER entitlements 段**（本机 `codesign` 默认不生成），于是补上：

```bash
codesign -f -s "iPhone Distribution: xxx (TEAMID)" \
  --entitlements ent.plist --generate-entitlement-der --timestamp=none SMM2Recomp.app
```

设备端用 `csops` 读回 entitlements blob，确认内核侧可见：

```
MAGIC=0xfade7171 BLEN=562
application-identifier = TEAMID0000.app.example.smm2
com.apple.developer.kernel.extended-virtual-addressing = true
com.apple.developer.kernel.increased-memory-limit = true
com.apple.developer.kernel.increased-debugging-memory-limit = true
```

**结论：签名与 entitlement 侧完全正常，问题不在这里。**（内部结论：报错文案是兜底文案，会误导排查方向。）

## 3. 第二轮：定位到地址空间上限

写一个最小探针 App（同一 bundle ID、同一 profile/证书签名），在 `main()` 里对候选地址做定点映射：

```c
// 编译：xcrun --sdk iphoneos clang -arch arm64 -O0 probe.c -o probe
#include <sys/mman.h>
#include <stdio.h>
#include <errno.h>

static void probe(unsigned long long base, unsigned long long size) {
    void *p = mmap((void *)base, size, PROT_NONE,
                   MAP_PRIVATE | MAP_ANON | MAP_FIXED | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED)
        printf("0x%llx FAIL errno=%d\n", base, errno);
    else
        printf("0x%llx OK -> %p\n", base, p);
}
```

（iOS 无 `MAP_FIXED_NOREPLACE`，用 `MAP_FIXED|MAP_NORESERVE` 足够，因为目标是空闲区。）

实测输出：

| 请求基址 | 换算 | 结果 |
|---|---|---|
| `0x300000000` | 12 GiB | OK |
| `0x400000000` | 16 GiB | OK |
| `0x800000000` | 32 GiB | OK |
| `0x1000000000` | 64 GiB | **FAIL errno=12** |
| `0x2000000000` | 128 GiB | FAIL |
| `0x4000000000` | 256 GiB | FAIL |
| `0x7000000000` | 448 GiB | FAIL |

同一进程内以 NULL 为基址申请 12.8 GiB（`MAP_NORESERVE`）→ OK，返回 `0x300000000`。
说明**内核允许大窗口，只是不允许放在 448 GiB 位置**。

结论：

```
iOS 26 / iPhone Air 的单进程 VA 上限 ≈ 32–64 GiB（实测边界在 0x800000000 与 0x1000000000 之间）
smm2recomp 的 guest 窗口硬编码 0x7000000000（448 GiB）→ 必然失败
```

## 4. 为什么只能改源码重编

guest 地址是**编译期常量**：

- `recomp/runtime/rt.h`：`#define GUEST_ORIGIN 0x7000000000ull`，并由此派生
  `GUEST_LO`、`GUEST_HI`、`MAIN_BASE`、`SDK_BASE`、`HLE_BASE`、`TLS_BASE`、
  `HLE_HEAP`、`ALIAS_BASE`、`HEAP_BASE`。
- `gen.py` 把游戏 NSO 反编译成 C 时，所有 guest 地址都以该常量参与运算，
  常量直接烧进生成代码（`movz #0x70, lsl #32` + 常量池）。

因此：

- 改 `rt.h` 而不重新 `gen` → 生成代码仍是旧基址，运行必崩；
- 二进制里 patch 立即数 → 命中点分散在 12 处常量 + 数千处运算，且指令编码长度不同，不可行；
- 重签 / 加 entitlement / 换 profile → 完全无关。

**必须 `make GUEST_ORIGIN=<新基址> gen` 重新生成游戏代码，再重编 runtime。**

## 5. 基址选择依据

| 候选 | 评价 |
|---|---|
| `0x300000000` (12 GiB) | 最小可行，窗口到 `0x620000000`，避开系统保留区余量最大 |
| **`0x400000000` (16 GiB)** | **本次采用**：与默认基址低位对齐（`0x__00000000`），窗口 `0x400000000..0x720000000`，实测全部加载/运行正常 |
| `0x800000000` (32 GiB) | 窗口到 `0xA20000000`，探针 OK 但贴近上限，不同机型风险高 |

窗口大小固定 `0x320000000`（12.8 GiB），选择基址时必须保证 `base + 0x320000000` 仍在实测上限内。
