---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: e72c8dc5665511fde1d076a99e405c04_8aaae858ddb611f19232525400248c00
    ReservedCode1: 7xY+/+bTw6sU263sWchVmVLbP5sEAZUDBmvTiaJssO+QVqZhhEUi9S8XZGnaniB6Qyzl9YEmutKF52PGCNFxRDZ2Qj+yOyoOpUajaDwl5uBgDyZCVECVKJhN6O8Iu+FLY/MXAJKpEkl8XkQnEQ6jpf8nYdXQ5G6Pccs/mfM1jcEu12mZ32yIqBT8jK4=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: e72c8dc5665511fde1d076a99e405c04_8aaae858ddb611f19232525400248c00
    ReservedCode2: 7xY+/+bTw6sU263sWchVmVLbP5sEAZUDBmvTiaJssO+QVqZhhEUi9S8XZGnaniB6Qyzl9YEmutKF52PGCNFxRDZ2Qj+yOyoOpUajaDwl5uBgDyZCVECVKJhN6O8Iu+FLY/MXAJKpEkl8XkQnEQ6jpf8nYdXQ5G6Pccs/mfM1jcEu12mZ32yIqBT8jK4=
---

# smm2recomp iOS：guest 内存窗口基址修复

让 [smm2recomp](https://github.com/) 重编译出的《超级马力欧制造 2》(Super Mario Maker 2, 3.0.3) iOS 版能在真实 iPhone 上启动运行。

> 已验证：iPhone Air (iPhone18,4 / iOS 26.3.1 / A19 Pro) 上 **60 fps 运行**，Metal + NVN 后端，2240×1260 渲染。

---

## 1. 问题现象

装上自签的 IPA 后，App 一启动就停在：

```
This copy of SMMaker 2 can't reserve the game's memory window
(0x7000000000-0x7320000000): it must be signed with the Extended
Virtual Addressing and Increased Memory Limit entitlements.
```

按字面意思去补签名/entitlement **无效**——即使 profile 与二进制里三个 kernel entitlement 全部齐备，仍然报同一句话。

## 2. 根因

崩溃文案是移植层 `main.c` 里的兜底提示，把所有 `mach_vm_allocate` 失败一律归因到 entitlement，属于**误报**。

真正原因是**地址空间上限**：

| 项 | 值 |
|---|---|
| 源码硬编码 guest 窗口起点 | `GUEST_ORIGIN = 0x7000000000`（448 GiB） |
| 窗口大小 | `0x320000000`（12.8 GiB），终点 `0x7320000000` |
| iOS 进程 VA 上限（带 `extended-virtual-addressing`） | 实测落在 **32～64 GiB** 之间 |

起点比上限还高一个数量级，因此 `mach_vm_allocate(VM_FLAGS_FIXED)` 必然失败，游戏代码永远无法映射。

实测探针（`mmap(MAP_FIXED|MAP_NORESERVE)` 定点映射）：

| 请求地址 | 结果 |
|---|---|
| `0x300000000` (12 GiB) | OK |
| `0x400000000` (16 GiB) | OK |
| `0x800000000` (32 GiB) | OK |
| `0x1000000000` (64 GiB) | FAIL `errno=12` |
| `0x2000000000` | FAIL |
| `0x4000000000` | FAIL |
| `0x7000000000` | FAIL |

结论：**基址是编译期常量，只能改源码重编 iOS 版，无法靠重签、entitlement 或运行时 patch 绕过。**

## 3. 修复

把 guest 窗口整体下移到 `0x400000000`（16 GiB），窗口 `0x400000000 .. 0x720000000`，稳落在 32 GiB 上限以内。

```bash
cd recomp

# 1) 为新基址重新生成全部游戏代码（sdk 175 块 + main 804 块）
make GAME=smm2 GUEST_ORIGIN=0x400000000 gen

# 2) 编译 iOS 版（runtime + 游戏代码 + 打包签名）
export RECOMP_IOS_IDENTITY="iPhone Distribution: <你的名字> (<TEAMID>)"
export RECOMP_IOS_PROFILE="$HOME/keys/profile.mobileprovision"
export RECOMP_IOS_BUNDLE_ID="com.example.smm2"
export RECOMP_IOS_DATA="private/smm2"      # 把游戏数据一起打进 app 的 data/
make -j8 TARGET=ios-arm64 GAME=smm2 DEPS=build/deps-ios \
     GUEST_ORIGIN=0x400000000 app
```

原理：`recomp/Makefile` 会把 `GUEST_ORIGIN` 透传给 `gen.py`（生成代码中的 guest 地址常量整体平移）并定义 `-DGUEST_ORIGIN=...ull`，同时把产物目录加后缀（`generated/smm2-0x400000000`、`build/smm2-ios-arm64-0x400000000`），不会污染默认基址的构建产物。

修改后的二进制校验：

```
0x7000000000 出现次数：0
movz #0x70, lsl #32：0
0x400000000  出现次数：12
```

设备端运行日志：

```
[gamelib] linked in (105374 + 34472 functions)
loaded main  at 400000000 size 2e74000 syms 947
loaded sdk   at 404000000 size cd4000 syms 25091
[metal] Apple A19 Pro GPU, heap buffer 3328 MB
[nvn] device initialized
[metalfx] 1920x1080 -> 2240x1260 (ok)
[metal] t=7.5 frame 146 59.9 fps mem 1385 MB (5270 left) ...
```

## 4. 文档

| 文件 | 内容 |
|---|---|
| [docs/01-root-cause.md](docs/01-root-cause.md) | 排查全过程：为何不是签名问题、VA 探针方法与数据 |
| [docs/02-fix-walkthrough.md](docs/02-fix-walkthrough.md) | 从改基址到产出 IPA 的完整步骤与耗时 |
| [docs/03-verification.md](docs/03-verification.md) | 设备验证：日志判读、性能、内存上限 |
| [docs/04-pitfalls.md](docs/04-pitfalls.md) | 踩坑清单（编译、部署、签名、打包） |
| [docs/05-faq.md](docs/05-faq.md) | 常见问题与可选基址 |

## 5. 脚本

| 脚本 | 用途 |
|---|---|
| `scripts/build-ios-guestbase.sh` | 一键：gen + 编译 + 打包（基址、签名参数化） |
| `scripts/deploy-device.sh` | 安装到设备 + 推送游戏数据 + 回抓运行日志 |
| `scripts/strip-sign-ipa.sh` | 脱壳：剥离 `_CodeSignature` / `embedded.mobileprovision` / 二进制签名 |
| `scripts/sign-ipa.sh` | 用指定证书 + profile 重签 IPA |

```bash
# 典型流程
./scripts/build-ios-guestbase.sh 0x400000000
./scripts/deploy-device.sh <DEVICE_UDID> build/smm2-ios-arm64-0x400000000/SMM2Recomp.app
./scripts/strip-sign-ipa.sh SMM2Recomp.app SMM2Recomp-unsigned.ipa
```

## 6. 环境

| 组件 | 版本 |
|---|---|
| macOS | 26.3.1（Apple silicon） |
| Xcode | 26.6 (17F113)，SDK iPhoneOS26.5 |
| 设备 | iPhone Air (iPhone18,4)，iOS 26.3.1，A19 Pro |
| 重编译目标 | Super Mario Maker 2 3.0.3 (01009B90006DC000 / 更新 01009B90006DC800) |
| 构建机 | 8 核 / 8 GB，全量编译约 1.5–2 小时 |

## 7. 法律声明

本仓库只包含**工具链使用经验与构建脚本**，不含任何游戏数据、密钥、Nintendo 版权资源。运行前请自备合法游戏本体（nsp/xci/nsz）与 `prod.keys`，仅在自有设备上使用。

## 8. 致谢

- smm2recomp 作者与 runtime 维护者
- 探针思路来自 recomp 社区对 iOS VA 上限的讨论
*（内容由AI生成，仅供参考）*
