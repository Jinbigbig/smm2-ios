# 07 · 让配置跟着 App 走：首启自复制

> 场景：把 OCW 配置（`ocw-config.json` + `smm2mods.ini`）打进 `.app`，装到 iPhone 上第一次启动就能联网，不需要电脑推文件。
>
> 本篇是 [06-ocw-online.md](06-ocw-online.md) 的配套实现，只改两处：`runtime/paths.c` 与 `tools/make_ios_app.sh`。

---

## 1. 为什么不能"放进去就完事"

iOS 版的数据根是沙箱 `Documents/`，而 `.app` 包内数据目录是**只读的**、且路径在 `Payload/xxx.app/data/`。启动时 runtime 会把包内的数据目录"接"进沙箱：

```c
if (!g_dev) ios_link_bundle_data();
```

`ios_link_bundle_data()` 的复制白名单是硬编码的几个大目录：

```c
names[] = {"extracted", "fonts", "sysdata", "metallib", "smm1"}
```

游戏读配置走的是 `Documents/ocw-config.json` 与 `Documents/smm2mods.ini`。这两个文件**不在白名单里**，所以哪怕 `.app/data/` 里确实躺着它们，游戏也看不到——日志里就是那句 `no ocw-config.json ... stays off`。

## 2. 两条路，选了第二条

| 方案 | 做法 | 问题 |
|---|---|---|
| A. 把文件名加进白名单 | 改 `names[]` | 白名单是"整目录搬运"语义，单文件塞进去要改循环结构；且这对 Windows/macOS 包也生效，语义就不纯了 |
| B. 首启单独复制 | 新增 `ios_seed_bundle_config()` | 只在 `!g_dev`（iOS 真机）路径执行，不影响其它平台；幂等，改过的配置不被覆盖 |

选 B：**改动局部、语义清晰、幂等**。

## 3. runtime 侧：`ios_seed_bundle_config()`

`runtime/paths.c`，紧挨着 `ios_link_bundle_data()` 定义：

```c
static void ios_seed_bundle_config(void) {
    static const char *const names[] = {"ocw-config.json", "smm2mods.ini"};
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        if (exists(names[i])) continue;                       // 沙箱已有：不覆盖
        char src[1100];
        snprintf(src, sizeof src, "%s/data/%s", g_exe_dir, names[i]);
        FILE *in = fopen(src, "rb");
        if (!in) continue;                                    // 包内没有：静默跳过
        FILE *out = fopen(names[i], "wb");
        if (!out) { fclose(in); fprintf(stderr, "[paths] can't copy %s (%s)\n", names[i], strerror(errno)); continue; }
        char buf[4096];
        size_t n;
        while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
        fclose(in); fclose(out);
        fprintf(stderr, "[paths] %s copied from the app\n", names[i]);
    }
}
```

要点：

- **判断依据是"沙箱里有没有"，不是包内有没有**。用户改过配置后重启，不会被包内默认值覆盖回去。
- **包内没有该文件就静默 continue**，所以没打配置的包照样能跑（这就是为什么后面还要做"从 `.app/data` 读"的兜底 grep）。
- 文件从 `g_exe_dir/data/` 读，`g_exe_dir` 此时已是可执行体所在目录（即 `.app/` 内）。
- 逐块 `fread/fwrite`，两个文件都只有几十~几百字节，够用且不需要 `copy_file_range` 之类平台特性。

调用点在 `rt_paths_init()` 里，**必须在 `ios_link_bundle_data()` 之后**（先保证数据目录结构就位，再补配置文件）：

```c
if (!g_dev) ios_link_bundle_data();
if (!g_dev) ios_seed_bundle_config();
```

`g_dev` 为真是"源码树里直接跑"的开发模式（当前目录有 `extracted/`），那种场景配置本来就在手边，不需要复制。

## 4. 打包侧：`tools/make_ios_app.sh`

在 `cp -Rc "$stage" "$APP/data"` **之前**，把配置塞进 stage：

```sh
# The settings the app carries into Documents on its first launch (runtime/paths.c ios_seed_bundle_config):
# the OCW config (domain + personal token) and the mods ini.
# RECOMP_IOS_SETTINGS overrides the folder they are read from (default: the data folder itself).
settings=${RECOMP_IOS_SETTINGS:-$RECOMP_IOS_DATA}
for f in ocw-config.json smm2mods.ini; do
    [ -f "$settings/$f" ] && cp "$settings/$f" "$stage/$f"
done
cp -Rc "$stage" "$APP/data" 2>/dev/null || cp -R "$stage" "$APP/data"
```

设计意图：

- **单独一个变量**。`RECOMP_IOS_DATA` 指向 2.8 GB 的游戏数据（`extracted/` 等），而配置通常另存一处（例如本机的 `temp/ios-settings/`）。`RECOMP_IOS_SETTINGS` 允许把两者分开；不设则退回读数据目录本身，兼容老用法。
- **`[ -f ... ] && cp`**：缺文件不报错，只是不带配置。
- 顺序关键：必须在 `cp -Rc` 之前进 stage，否则不会被带进 `.app/data/`。

对应环境变量：

```bash
RECOMP_IOS_DATA=$SRC/private/smm2 \
RECOMP_IOS_SETTINGS=temp/ios-settings \
```

## 5. 验证四步

```bash
# 1) 包内确有配置
ls -l SMM2Recomp.app/data/ocw-config.json SMM2Recomp.app/data/smm2mods.ini
#    -rw-r--r-- ... 78 ocw-config.json
#    -rw-r--r-- ... 54 smm2mods.ini

# 2) 首启日志应出现复制记录（仅首次）
#    [paths] ocw-config.json copied from the app
#    [paths] smm2mods.ini copied from the app

# 3) 沙箱里确有这两个文件
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier app.grape2286.yam856 \
  --source Documents --destination ./sandbox-docs
ls -l ./sandbox-docs

# 4) 内容一致
md5 ./sandbox-docs/ocw-config.json   # 与源文件 md5 相同
```

第 2 步的日志**只在新装/清数据后的第一次出现**。第二次启动看不到是正常的——`exists()` 判断到文件已在，跳过了复制。

## 6. 三个注意点

| 点 | 说明 |
|---|---|
| 重装恢复默认 | 卸载重装后 `Documents/` 清空，包内默认值会重新落一次。这正是期望行为：恢复到"出厂可联机"状态 |
| 想换 token | 手动推 `scripts/push-ocw.sh` 覆盖（沙箱里已有文件 → 首启不再复制），或删掉沙箱文件让它重新复制 |
| 脚本执行位 | 拉下来的 `tools/*.sh` 可能缺执行位，`make app` 会报 `Permission denied`。`chmod +x tools/*.sh` 一次解决 |
