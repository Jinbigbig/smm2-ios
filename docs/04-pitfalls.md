---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: e72c8dc5665511fde1d076a99e405c04_fee6ce81ddc511f19232525400248c00
    ReservedCode1: BAFlr3XoyhAnCf1i1WFjio5pTJAvcHSK4k+6m0B5/4FuvA7yj1jCPPKxv6uAbF5SaRYVwdBQuV5Y3j7mZLBahfJTIBMw2xnxRce6s3+mAKynpmKAeJi22GofYNBCO84KnH/TgCYHuxxvPH2YDiLU9za7pFVzGBSls2jy/Q78Wi90VGB6X0C3trh0xgs=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: e72c8dc5665511fde1d076a99e405c04_fee6ce81ddc511f19232525400248c00
    ReservedCode2: BAFlr3XoyhAnCf1i1WFjio5pTJAvcHSK4k+6m0B5/4FuvA7yj1jCPPKxv6uAbF5SaRYVwdBQuV5Y3j7mZLBahfJTIBMw2xnxRce6s3+mAKynpmKAeJi22GofYNBCO84KnH/TgCYHuxxvPH2YDiLU9za7pFVzGBSls2jy/Q78Wi90VGB6X0C3trh0xgs=
---



# 04 · 踩坑清单

按"症状 → 原因 → 处理"记录，均为本次实操中真实遇到的。

## A. 编译与生成

### A1 `make` 自动 `rm -rf ios-build/`
**症状**：第二次执行 `make ... app` 时，前一次耗时 1 小时的 `ios-build/` 被删除重新开始。
**原因**：`ios-build` 目标把目录生成视为一次性动作，目录存在也判为需要重建。
**处理**：编译阶段直接 `cd ios-build && make -j8`，或用 `scripts/build-ios-guestbase.sh --no-rebuild` 复用目录。改基址时必须重建（产物带基址后缀，实际不会冲突）。

### A2 并行度别照抄 `-j8`
**症状**：`-j8` 时系统极度卡顿，`clang++` 被 OOM kill。
**原因**：Makefile 默认 `jobs = min(ncpu, hw.memsize>>30 - 6)`；8 GB 机器上默认只有 2，是合理值。
**处理**：内存 8 GB → `-j4` 尚可、`-j8` 需接受频繁 swap；16 GB 以上再上 `-j8`。

### A3 生成的代码不能跨基址复用
**症状**：只改 `rt.h` 里 `GUEST_ORIGIN` 就编译，运行崩在第一条 guest 访问。
**原因**：guest 地址在 `gen` 阶段就烧进生成代码。
**处理**：必须 `make GUEST_ORIGIN=<新基址> gen`；目录带后缀便于辨认。

### A4 依赖库必须预先交叉编译
**症状**：`ld: library not found for -lSDL3`。
**原因**：`build/deps-ios` 为空或仍是 macOS 版。
**处理**：先按 README 的 SDL3 交叉编译流程生成 `build/deps-ios/lib/libSDL3.a`（`IOS_MIN=17.0`）。

### A5 `MAP_FIXED_NOREPLACE` 不存在
**症状**：探针编译不过。
**原因**：iOS 无该宏。
**处理**：用 `MAP_FIXED | MAP_NORESERVE`，先确认目标区间空闲。

### A6 clang 需要显式声明 `_dyld_get_image_header` / `getsectiondata`
**症状**：隐式声明警告 + 链接失败。
**处理**：`#include <mach-o/dyld.h>`，并显式给出原型。

## B. 签名与权限

### B1 通配符 profile 必定失败
**症状**：`can't reserve the game's memory window`，即使已勾选能力。
**原因**：`*` App ID 的 profile 不包含 `com.apple.developer.kernel.*`。
**处理**：使用显式 App ID（如 `app.example.smm2`）创建 App ID 并勾选 Extended Virtual Addressing + Increased Memory Limit。

### B2 `codesign` 默认不写 DER entitlements
**症状**：profile 正确、二进制 `codesign -d --entitlements -` 也看得到，设备仍读不到。
**处理**：`codesign ... --generate-entitlement-der`，再用 `csops` 读回校验。

### B3 `--deep` 已废弃
**症状**：`codesign --deep` 警告且不处理嵌套内容。
**处理**：手动逐层签（`Frameworks/*.framework` → `PlugIns` → app），最后再签外层。

### B4 侧载后首次启动"未受信任的开发者"
**处理**：设置 → 通用 → VPN 与设备管理 → 信任该证书；企业证书过期需重签。

## C. 数据部署

### C1 `devicectl copy to` 会"铺平"目录
**症状**：传完后设备上是 `Documents/extracted/extracted/exefs`，App 报 `cannot load extracted/exefs/main`。
**原因**：`--source <dir>` 的内容被复制进 destination，而不是把 `<dir>` 本身放进去。
**处理**：`--source private/smm2/extracted --destination Documents/extracted`（少一层）。

### C2 romfs 必须是 `romfs.bin` 或完整 `romfs/`
**症状**：`FATAL: cannot open extracted/romfs.bin or extracted/romfs`。
**原因**：只传了空目录占位。
**处理**：把 App 内 `data/extracted/romfs/` 完整推到设备（约 2.8 GB），首次传输 15–30 min，注意设备剩余空间。

### C3 容器路径找错
**处理**：
```bash
xcrun devicectl device info files --device <UDID> \
  --domain-type appDataContainer --domain-identifier <BUNDLE_ID>
```

## D. 打包与 IPA

### D1 脱壳版残留签名导致安装失败
**症状**：`The application could not be installed: invalid code signature`。
**处理**：`codesign --remove-signature` 二进制后，`find . -name "_CodeSignature" -exec rm -rf {} +`，删 `embedded.mobileprovision`，最后 `xattr -cr .`。校验：`codesign -dv` 应返回 `code object is not signed at all`。

### D2 IPA 体积过大（2.8 GB）
**原因**：内置 romfs（2.8 GB）。
**处理**：`RECOMP_IOS_DATA=` 留空 → 只打 exefs，数据另传；或用未压缩 zip（`zip -0`）省 CPU，但体积更大。

### D3 `zip` 内含 `__MACOSX` / `.DS_Store`
**处理**：`zip -qry -X ...`，并在打包前 `find Payload -name ".DS_Store" -delete`。

## E. 运行期

### E1 首启黑屏
shader cache 首次编译，10–20 s，非死锁。`RECOMP_IOS_NO_SHADERS=1` 可跳过预编译换更快首启，代价是前几帧可能掉帧。

### E2 日志看不到
App 被杀后日志可能未 flush。用 `--console` 启动，或缩短日志 buffer；崩溃后可用 `devicectl device copy from` 取 `Documents/smm2recomp.log`。

### E3 报错文案具有误导性
`... it must be signed with the Extended Virtual Addressing ...` 是兜底文案，任何 `mach_vm_allocate` 失败都会打这一句。**永远先看日志里的 `kern 12` / `errno=12`，再去查地址。**

## F. 签名、脚本与配置分发（OCW 联机阶段新增）

### F1 `errSecInternalComponent` 且 `0 valid identities found`
**症状**：`codesign --force --sign <SHA-1>` 对 IPA 与最小可执行体都返回 `errSecInternalComponent`，退出码时 0 时 1；`security find-identity -p codesigning` 显示 `0 valid identities found`，但 `security dump-keychain` 里**看得到**该证书。

**原因**（两层，常叠加）：

1. **缺中间证书**。证书本身在钥匙串里，但 Apple WWDR 中间证书缺失，证书链建立失败。`security verify-cert -c cert.pem -p codesigning` 会返回 `CSSMERR_TP_NOT_TRUSTED`，甚至 `policy creation failed for codesigning`。
2. **search list 指向了已删除的钥匙串**。`security list-keychains` 中残留临时钥匙串路径（如 `/private/tmp/xxx.keychain-db`），而该文件已被删。此时 `security unlock-keychain -p ""` 报 "could not be found"，identity 从列表里整体消失。

**处理**：

```bash
# 1) 清掉 search list 中不存在的钥匙串
security list-keychains -d user
security list-keychains -d user -s ~/Library/Keychains/login.keychain-db /Library/Keychains/System.keychain

# 2) 确认证书在 login 钥匙串（不是某个副本文件里）
security find-certificate -a -c "iPhone Distribution" -Z ~/Library/Keychains/login.keychain-db | head

# 3) 装中间证书后验证
security verify-cert -c "$(mktemp).pem" -p codesigning   # 应无 CSSMERR
security find-identity -p codesigning                    # 应列出 1 valid identity
```

**兜底**：签名链路修不好时不阻塞发布——走**脱壳无签名**路线，产出未签名 IPA 交给侧载工具签名（见 `scripts/strip-sign-ipa.sh`）。本次实操即因此改为脱壳路线。

### F2 `make app` 报 `Permission denied`
**症状**：`tools/make_ios_app.sh: Permission denied`，或 `precompile_shaders.sh` 无输出直接失败。
**原因**：脚本从仓库拉下来丢执行位。
**处理**：`chmod +x tools/*.sh`。这类问题会伪装成"编译失败"，先看有没有 `Permission denied` 字样。

### F3 `.app/data/` 里放了配置，游戏仍然不读
**症状**：`ocw-config.json` 与 `smm2mods.ini` 确实在包内 `data/` 下，但日志仍有 `no ocw-config.json ... stays off`。
**原因**：`ios_link_bundle_data()` 的白名单只有 `extracted` / `fonts` / `sysdata` / `metallib` / `smm1`，配置文件不在其中，不会被搬进沙箱。
**处理**：改 `runtime/paths.c` 加首启复制（见 [07-settings-in-bundle.md](07-settings-in-bundle.md)），或装完用 `scripts/push-ocw.sh` 手动推。

### F4 首启复制只发生一次
**症状**：第二次启动后日志里不再出现 `[paths] ocw-config.json copied from the app`，误以为没生效。
**原因**：`ios_seed_bundle_config()` 以"沙箱里是否已存在"为准，已存在就跳过——这是刻意的，避免覆盖用户改过的配置。
**处理**：这不是故障。要强制重新落默认值，删掉沙箱 `Documents/` 下对应文件，或卸载重装。

### F5 配置推完不生效
**症状**：文件已就位，回读校验也一致，游戏里还是连不上。
**原因**：后端配置**只在启动时读一次**。
**处理**：冷启动。`xcrun devicectl device process launch --terminate-existing <bundle id>`，不要只从后台切前台。
