#!/usr/bin/env bash
# 脱壳：剥离签名，产出未签名 IPA（供后续用其它证书重签）
# 用法: ./strip-sign-ipa.sh <App.app> [out.ipa]
set -euo pipefail

APP="${1:?用法: strip-sign-ipa.sh <App.app> [out.ipa]}"
OUT="${2:-$(dirname "$APP")/unsigned.ipa}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
TARGET="$WORK/Payload/$(basename "$APP")"

echo "== 剥离二进制签名 =="
find "$TARGET" -type f -perm -u+x | while read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    echo "-- $f"
    codesign --remove-signature "$f" 2>/dev/null || true
  fi
done

echo "== 清理签名残留 =="
find "$TARGET" -name "_CodeSignature" -type d -prune -exec rm -rf {} +
rm -f "$TARGET/embedded.mobileprovision"
find "$TARGET" -name ".DS_Store" -delete
xattr -cr "$TARGET" 2>/dev/null || true

echo "== 校验（应为 'code object is not signed at all'）=="
codesign -dv "$TARGET/$(basename "$TARGET" .app)" 2>&1 | head -n 2 || true

echo "== 打包 =="
( cd "$WORK" && zip -qry -X "$OUT" Payload )
echo "-- 输出: $OUT ($(du -h "$OUT" | cut -f1))"
