---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: e72c8dc5665511fde1d076a99e405c04_8f206be5ddb611f19280525400393706
    ReservedCode1: plGDAVVZHMFZmphcnv7RQKwBZcW1h4QjYfnYt5L2AQrPeTwMF1tSBfG1/MQEPvQhr8CC5s5K2VkY4Bm8mjNNIMbdoZCPBzKUwIP/Azp8rBvrgIvNian5fzM41OH6Mh3mvXAOz76HNMn4dmpTs7Bifmvnb88CXsaSHBdjkcQidfQTrj5+qB9GH5k+lxw=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: e72c8dc5665511fde1d076a99e405c04_8f206be5ddb611f19280525400393706
    ReservedCode2: plGDAVVZHMFZmphcnv7RQKwBZcW1h4QjYfnYt5L2AQrPeTwMF1tSBfG1/MQEPvQhr8CC5s5K2VkY4Bm8mjNNIMbdoZCPBzKUwIP/Azp8rBvrgIvNian5fzM41OH6Mh3mvXAOz76HNMn4dmpTs7Bifmvnb88CXsaSHBdjkcQidfQTrj5+qB9GH5k+lxw=
---

# patches · 需要关注的源码位置

本目录不提供完整补丁文件（上游源码版本差异较大），改为标明**必须改动/确认的位置**与判断方法。

## 1. `recomp/runtime/rt.h`

默认基址定义处（约 22–33 行）：

```c
#define GUEST_ORIGIN 0x7000000000ull
#define GUEST_SIZE   0x320000000ull
#define GUEST_HI     (GUEST_ORIGIN + GUEST_SIZE)
/* 以下均由 GUEST_ORIGIN 派生 */
#define MAIN_BASE    GUEST_ORIGIN
#define SDK_BASE     (GUEST_ORIGIN + 0x4000000ull)
#define HLE_BASE     ...
#define TLS_BASE     ...
#define ALIAS_BASE   ...
#define HEAP_BASE    ...
```

**关键**：`GUEST_ORIGIN` 是唯一入口，其余派生常量不要手工改。改基址的推荐做法是**通过 Makefile 变量**（`make GUEST_ORIGIN=...`），只有需要固定默认值时才改此处。

## 2. `recomp/Makefile`

需要确认的三点：

1. `GUEST_ORIGIN ?= 0x7000000000`（可被命令行覆盖）
2. `gen` 目标把 `GUEST_ORIGIN` 传给 `gen.py`，且产物目录带基址后缀（如 `generated/smm2-0x400000000`）
3. `TARGET=ios-arm64` 分支定义 `-DGUEST_ORIGIN=$(GUEST_ORIGIN)ull`，并输出到 `build/smm2-ios-arm64-$(GUEST_ORIGIN)/`

如果上游版本**没有**把基址透传给 `gen.py`，生成代码会继续用默认常量，运行必崩——这是最容易漏的一步。校验方法是反汇编查 `movz #0x70, lsl #32` 是否归零。

## 3. `tools/patches.py` / `gamelib-src/patches.py`

游戏侧 patch 里若出现 `0x7000000000` 字面量（例如某些 HLE 桩函数、堆指针运算、`smm1_extras.py`、`mods/patches.py`、`mods/relax.py`），需同步为新的基址表达式，最好统一写成从 `GUEST_ORIGIN` 派生，避免以后再踩。

## 4. 校验清单

```bash
BIN=build/smm2-ios-arm64-<ORIGIN>/SMM2Recomp.app/SMM2Recomp

# a) 旧基址字面量应为 0
xxd -p "$BIN" | tr -d '\n' | grep -o '0000000000000070' | wc -l

# b) 旧基址的 movz 指令应为 0
xcrun llvm-objdump -d --no-show-raw-insn "$BIN" | grep -c 'lsl #32.*#0x70'

# c) 生成目录与运行日志的基址一致
ls generated/ | grep "$(echo 0x400000000)"
grep 'loaded main' ~/Downloads/smm2recomp.log   # 期望 400000000
```

三项一致才说明修复真正生效。

## 5. 最小探针

见 `scripts/va-probe.c`，用于在目标机型上实测本机 VA 上限，决定基址取值。
*（内容由AI生成，仅供参考）*
