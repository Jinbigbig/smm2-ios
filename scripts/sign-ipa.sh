#!/usr/bin/env bash
# 用指定证书 + provisioning profile 重签 App，并从 profile 自动提取 entitlements
# 用法: ./sign-ipa.sh <App.app> <identity> <profile.mobileprovision> [额外ent.plist]
set -euo pipefail

APP="${1:?用法: sign-ipa.sh <App.app> <identity> <profile> [ent.plist]}"
IDENTITY="${2:?缺少签名主体}"
PROFILE="${3:?缺少 .mobileprovision}"
EXTRA="${4:-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "== 解析 profile =="
security cms -D -i "$PROFILE" > "$TMP/prof.plist"
/usr/libexec/PlistBuddy -c "Print :Entitlements" "$TMP/prof.plist" > "$TMP/ent.plist"

echo "-- App ID: $(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$TMP/ent.plist" 2>/dev/null || echo '?')"
echo "-- kernel 能力:"
grep -o 'com\.apple\.developer\.kernel\.[a-z-]*' "$TMP/ent.plist" | sort -u || echo "   (未发现，通配符 profile？)"

if [[ -n "$EXTRA" ]]; then
  echo "== 合并额外 entitlements =="
  /usr/libexec/PlistBuddy -c "Merge $EXTRA" "$TMP/ent.plist" || true
fi

echo "== 逐层签名（从内到外）=="
if [[ -d "$APP/Frameworks" ]]; then
  find "$APP/Frameworks" -maxdepth 1 -name "*.framework" -o -maxdepth 1 -name "*.dylib" | while read -r f; do
    echo "-- $(basename "$f")"
    codesign -f -s "$IDENTITY" --generate-entitlement-der --timestamp=none "$f"
  done
fi

cp "$PROFILE" "$APP/embedded.mobileprovision"
codesign -f -s "$IDENTITY" --entitlements "$TMP/ent.plist" \
  --generate-entitlement-der --timestamp=none "$APP"

echo "== 校验 =="
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | sed -n '1,8p'
echo "== 读回 entitlements =="
codesign -d --entitlements :- "$APP" 2>/dev/null | head -n 40
