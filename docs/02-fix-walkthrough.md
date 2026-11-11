---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: e72c8dc5665511fde1d076a99e405c04_8c5cc90addb611f19280525400393706
    ReservedCode1: WavM0YtuctgAKB4wLEm53vpaQJG0yExGcn+hq5E1L3jlv6xT2X127IcwOFvtthYKUGRi3K1U11TGZ29MDAkEKhv8hxphZyEFGIYvoXt6hvOpoQAZDQEC0p2ZFCMn/3soJPINbrhM2ahmijgrJoRmfne3A8TeErtCDmmNob5MF77btcpc06CsjjLSczA=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: e72c8dc5665511fde1d076a99e405c04_8c5cc90addb611f19280525400393706
    ReservedCode2: WavM0YtuctgAKB4wLEm53vpaQJG0yExGcn+hq5E1L3jlv6xT2X127IcwOFvtthYKUGRi3K1U11TGZ29MDAkEKhv8hxphZyEFGIYvoXt6hvOpoQAZDQEC0p2ZFCMn/3soJPINbrhM2ahmijgrJoRmfne3A8TeErtCDmmNob5MF77btcpc06CsjjLSczA=
---

# 02 · 修复与出包全流程

目标：`GUEST_ORIGIN = 0x400000000`，产出可侧载的 `SMM2Recomp.ipa`。

## 0. 前置条件

| 项 | 要求 |
|---|---|
| Xcode | 含 iOS SDK 与命令行工具（本文 26.6 / iPhoneOS26.5） |
| iOS 依赖 | `build/deps-ios/lib/libSDL3.a`（SDL3 release-3.4.18，IOS_MIN 17.0），已交叉编译 |
| 游戏数据 | `private/smm2/` 下 `extracted/exefs`、`extracted/romfs`、`fonts`、`sysdata` 齐全 |
| 签名资产 | 显式 App ID 的 `.mobileprovision` + 对应 `.p12`（**通配符 profile 不带 kernel entitlement，必失败**） |
| 磁盘 | ≥ 20 GB 空闲（`generated/` + `build/` + `.ipa`） |

## 1. 重新生成游戏代码

```bash
cd recomp
make GAME=smm2 GUEST_ORIGIN=0x400000000 gen
```

输出（本机实测）：

```
[gen] sdk  175 chunks -> generated/smm2-0x400000000/sdk      (12 s)
[gen] main 804 chunks -> generated/smm2-0x400000000/main     (138 s)
```

说明：

- `gen` 只跑一次，产物按基址后缀隔离；换基址要重跑，别复用旧目录。
- 生成阶段 CPU 占用不高，主要耗时在 NSO 反编译与常量重定位。

## 2. 编译 iOS arm64

```bash
export RECOMP_IOS_IDENTITY="iPhone Distribution: <Common Name> (<TEAMID>)"
export RECOMP_IOS_PROFILE="/abs/path/profile.mobileprovision"
export RECOMP_IOS_BUNDLE_ID="app.example.smm2"
export RECOMP_IOS_DATA="private/smm2"     # 把 data/ 打进 app bundle
export RECOMP_IOS_NO_SHADERS=1            # 跳过 Metal shader 预编译（见踩坑 04）

make -j8 TARGET=ios-arm64 GAME=smm2 DEPS=build/deps-ios \
     GUEST_ORIGIN=0x400000000 app
```

关键编译参数（由 Makefile 生成）：

```
xcrun --sdk iphoneos clang++ -target arm64-apple-ios17.0 -O2 -g -std=c++17 \
  -DGUEST_ORIGIN=0x400000000ull -I build/deps-ios/include -I recomp/runtime ...
ld: -arch arm64 -platform_version ios 17.0 26.5 -lSDL3 ...
```

耗时（8 核 / 8 GB，`-j8`）：

| 阶段 | 时间 |
|---|---|
| gen | 约 2.5 分钟 |
| 全量编译（979 个 .c + runtime） | 约 1.5–2 小时（峰值内存吃紧，swap 会被用到） |
| 链接 + 打包 + 签名 | 3–6 分钟 |

产物：

```
build/smm2-ios-arm64-0x400000000/SMM2Recomp.app/
├── SMM2Recomp              (≈136 MB，arm64 Mach-O)
├── data/extracted/exefs/main (≈20 MB)
├── data/extracted/romfs/    (空目录占位，数据放设备容器)
├── data/fonts, data/sysdata
├── Info.plist
├── embedded.mobileprovision
└── _CodeSignature/
```

## 3. 校验二进制里的常量

```bash
BIN=build/smm2-ios-arm64-0x400000000/SMM2Recomp.app/SMM2Recomp

# 旧基址必须彻底消失
xxd -p "$BIN" | tr -d '\n' | grep -o '0000000000000070' | wc -l   # 期望 0
# movz #0x70, lsl #32 编码：0xD2A0000? 系列 → 用反汇编抽查
xcrun llvm-objdump -d --no-show-raw-insn "$BIN" | grep -c 'movz.*#0x70.*lsl #32'  # 期望 0

# 新基址应当存在
strings -a "$BIN" | grep -c '0x400000000'  # 仅供参考；常量池里为小端 4 字节
```

本机实测：旧常量命中 0 处，`0x400000000` 出现 12 处。

## 4. 打包 IPA

```bash
mkdir -p Payload
cp -R build/smm2-ios-arm64-0x400000000/SMM2Recomp.app Payload/
zip -qry "../SMM2Recomp-ios-guestbase.ipa" Payload
```

签名（若第 2 步未签，或用新证书重签见 `scripts/sign-ipa.sh`）：

```bash
codesign -f -s "$RECOMP_IOS_IDENTITY" \
  --entitlements ent.plist --generate-entitlement-der --timestamp=none \
  Payload/SMM2Recomp.app
codesign --verify --deep --strict --verbose=2 Payload/SMM2Recomp.app   # 应输出 valid on disk / satisfies its Designated Requirement
```

> `--generate-entitlement-der` 很关键：不带它，二进制里可能只有 XML blob 而没有 DER 段，
> 部分 iOS 版本读不到 kernel entitlement（见 04 踩坑）。

## 5. 部署到设备

```bash
UDID=<设备 UDID>

# 5.1 安装
xcrun devicectl device install app --device "$UDID" Payload/SMM2Recomp.app

# 5.2 推送游戏数据到容器
#     注意：copy to 的 --source 目录内容会被“铺平”进 destination
xcrun devicectl device copy to --device "$UDID" \
  --domain-type appDataContainer \
  --domain-identifier <BUNDLE_ID> \
  --source "private/smm2/extracted" --destination Documents/extracted
xcrun devicectl device copy to --device "$UDID" \
  --domain-type appDataContainer --domain-identifier <BUNDLE_ID> \
  --source "private/smm2/fonts"    --destination Documents/fonts
xcrun devicectl device copy to --device "$UDID" \
  --domain-type appDataContainer --domain-identifier <BUNDLE_ID> \
  --source "private/smm2/sysdata"  --destination Documents/sysdata
```

设备上的最终结构：

```
Documents/
├── extracted/exefs/main
├── extracted/romfs.bin  或  extracted/romfs/
├── fonts/
├── sysdata/
└── smm2recomp.log
```

## 6. 启动与抓日志

```bash
xcrun devicectl device process launch --device "$UDID" --console <BUNDLE_ID>
# 或启动后回抓
xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier <BUNDLE_ID> \
  --source Documents/smm2recomp.log --destination ./smm2recomp.log
```

成功判据见 [03-verification.md](03-verification.md)。
*（内容由AI生成，仅供参考）*
