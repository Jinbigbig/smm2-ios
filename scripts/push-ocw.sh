#!/bin/bash
# push-ocw.sh - 把 OpenCourse World 配置推进 iPhone 上 SMMaker 2 的沙箱 Documents。
#
# 什么时候用：重装 / 换机 / 手动清了 App 数据之后。游戏的 OCW 配置只在启动时读一次，所以推完必须冷启动
# （从后台划掉再打开），否则还是按旧配置跑。
# 若 App 已经自带配置（见 docs/07-settings-in-bundle.md），多数情况下不需要本脚本。
#
# 用法：
#   ./push-ocw.sh                      # 默认设备 mm、bundle id app.grape2286.yam856
#   ./push-ocw.sh -d "我的 iPhone"      # 指定设备（名称或 UDID，见 xcrun devicectl list devices）
#   ./push-ocw.sh -c ./ocw-config.json  # 指定 OCW 配置源文件（含 domain 与 22 字符 token）
#   ./push-ocw.sh -b app.example.bundle # 指定设备上的 bundle id
#   ./push-ocw.sh -n                    # 只打印将要推送的内容，不写设备
#
# 注意：
#   - ocw-config.json 里的 token 是账号凭据，别把这个文件发给别人；重复从 OCW 站点下载会让旧 token 作废。
#   - smm2mods.ini 会保留设备上已有的行（courses / ruleset / hundred 等），只补上或改写 backend=ocw。
set -uo pipefail

DEVICE="mm"
BUNDLE_ID="app.grape2286.yam856"
CONFIG_SRC="${OCW_CONFIG:-$HOME/Documents/ocw-config.json}"
DRY_RUN=0

while getopts ":d:c:b:nh" opt; do
    case "$opt" in
        d) DEVICE="$OPTARG" ;;
        c) CONFIG_SRC="$OPTARG" ;;
        b) BUNDLE_ID="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        h) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数：-$OPTARG（-h 看用法）" >&2; exit 2 ;;
    esac
done

die() { echo "失败：$*" >&2; exit 1; }
command -v xcrun >/dev/null || die "找不到 xcrun（需要装 Xcode）"
[ -f "$CONFIG_SRC" ] || die "找不到 OCW 配置：$CONFIG_SRC（用 -c 指定）"

# 配置自检：domain 不超过 29 字符，token 恰好 22 字符（游戏的槽位就这两个长度）
python3 - "$CONFIG_SRC" <<'PY' || exit 1
import json, sys
p = sys.argv[1]
try:
    cfg = json.load(open(p, encoding="utf-8"))
except Exception as e:
    sys.exit(f"失败：{p} 不是合法 JSON（{e}）")
d, t = cfg.get("domain", ""), cfg.get("token", "")
errs = []
if not d: errs.append('缺 "domain"')
elif len(d) > 29: errs.append(f'"domain" 有 {len(d)} 字符，游戏槽位只有 29')
if not t: errs.append('缺 "token"')
elif len(t) != 22: errs.append(f'"token" 有 {len(t)} 字符，应为 22')
if errs: sys.exit("失败：配置不合格 - " + "；".join(errs))
print(f"配置自检通过：domain={d} token={t[:4]}…（{len(t)} 字符）")
PY

WORK="$(mktemp -d "${TMPDIR:-/tmp}/push-ocw.XXXXXX")" || die "建不了临时目录"
trap 'rm -rf "$WORK"' EXIT

copy_to()  { xcrun devicectl device copy to   --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "$1" --destination "$2" >/dev/null 2>&1; }
copy_from(){ xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source "$1" --destination "$2" >/dev/null 2>&1; }

# 先确认设备在线（顺便验证 bundle 已安装）
xcrun devicectl list devices 2>/dev/null | grep -qi "$DEVICE.*available" \
    || die "设备 \"$DEVICE\" 不在线或未配对，先看 xcrun devicectl list devices"
copy_from "Documents/smm2mods.ini" "$WORK/old.ini" || die "取不到 Documents/smm2mods.ini（$BUNDLE_ID 装了吗？）"

# 保留原有行，只补/改 backend=ocw
if grep -qiE '^[[:space:]]*backend[[:space:]]*=' "$WORK/old.ini"; then
    sed -E 's/^[[:space:]]*backend[[:space:]]*=.*/backend=ocw/I' "$WORK/old.ini" > "$WORK/smm2mods.ini"
else
    { cat "$WORK/old.ini"; printf 'backend=ocw\n'; } > "$WORK/smm2mods.ini"
fi
cp "$CONFIG_SRC" "$WORK/ocw-config.json"

echo "目标设备：$DEVICE（$BUNDLE_ID）"
echo "--- 将写入 Documents/smm2mods.ini ---"; cat "$WORK/smm2mods.ini"
echo "--- 将写入 Documents/ocw-config.json ---"; cat "$WORK/ocw-config.json"

if [ "$DRY_RUN" = 1 ]; then
    echo "（-n：只看不写）"; exit 0
fi

copy_to "$WORK/ocw-config.json" "Documents/ocw-config.json" || die "推送 ocw-config.json 失败"
copy_to "$WORK/smm2mods.ini"    "Documents/smm2mods.ini"    || die "推送 smm2mods.ini 失败"

# 回读校验
copy_from "Documents/ocw-config.json" "$WORK/back.json"     || die "回读 ocw-config.json 失败"
copy_from "Documents/smm2mods.ini"    "$WORK/back.ini"      || die "回读 smm2mods.ini 失败"
cmp -s "$WORK/ocw-config.json" "$WORK/back.json" || die "回读内容与源文件不一致"
grep -qiE '^[[:space:]]*backend[[:space:]]*=[[:space:]]*ocw' "$WORK/back.ini" || die "回读的 ini 没有 backend=ocw"

echo
echo "已就位，回读一致。现在冷启动游戏生效："
echo "  xcrun devicectl device process launch --device $DEVICE --terminate-existing $BUNDLE_ID"
echo "日志里应出现：[net] backend ocw … / [ocw] host … / [ssl] connection to server.opencourse.world"
