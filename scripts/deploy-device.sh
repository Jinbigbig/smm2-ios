#!/usr/bin/env bash
# 安装到真机 + 推送游戏数据 + 回抓日志
# 用法: ./deploy-device.sh <UDID> <App.app 路径> [数据目录]
set -euo pipefail

UDID="${1:?用法: deploy-device.sh <UDID> <App.app> [data_dir]}"
APP="${2:?缺少 .app 路径}"
DATA="${3:-$HOME/SMM2Recomp/private/smm2}"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
echo "== bundle: $BUNDLE_ID =="

echo "== 安装 =="
xcrun devicectl device install app --device "$UDID" "$APP"

if [[ -d "$DATA" ]]; then
  echo "== 推送数据（copy to 会铺平目录，注意 destination 少一层）=="
  for d in extracted fonts sysdata; do
    if [[ -d "$DATA/$d" ]]; then
      echo "-- $d"
      xcrun devicectl device copy to --device "$UDID" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --source "$DATA/$d" --destination "Documents/$d"
    fi
  done
else
  echo "-- 数据目录不存在，跳过: $DATA"
fi

echo "== 启动（console 跟随）=="
xcrun devicectl device process launch --device "$UDID" --console "$BUNDLE_ID" || true

echo "== 回抓日志 =="
xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source Documents/smm2recomp.log --destination ./smm2recomp.log && \
  echo "-- 已保存 ./smm2recomp.log" && tail -n 40 ./smm2recomp.log
