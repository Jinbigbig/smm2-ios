#!/usr/bin/env bash
# 一键构建 smm2recomp iOS 版（自定义 guest 基址）
# 用法:
#   ./build-ios-guestbase.sh [GUEST_ORIGIN] [--no-gen] [--no-rebuild]
# 环境变量:
#   RECOMP_ROOT        源码根目录（含 recomp/），默认 ~/SMM2Recomp
#   RECOMP_IOS_IDENTITY 签名主体，如 "iPhone Distribution: Name (TEAMID)"
#   RECOMP_IOS_PROFILE  .mobileprovision 绝对路径
#   RECOMP_IOS_BUNDLE_ID 显式 App ID
#   RECOMP_IOS_DATA     打进 app 的数据目录（相对 recomp/），默认 private/smm2
#   JOBS                并行度，默认自动
set -euo pipefail

ORIGIN="${1:-0x400000000}"
shift || true
DO_GEN=1
REBUILD=1
for a in "$@"; do
  case "$a" in
    --no-gen) DO_GEN=0 ;;
    --no-rebuild) REBUILD=0 ;;
  esac
done

RECOMP_ROOT="${RECOMP_ROOT:-$HOME/SMM2Recomp}"
SRC="$RECOMP_ROOT/recomp"
[[ -f "$SRC/Makefile" || -f "$SRC/makefile" ]] || { echo "找不到 $SRC/Makefile，请设置 RECOMP_ROOT"; exit 1; }

TAG="${ORIGIN}"
if command -v sysctl >/dev/null; then
  MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
  CPU=$(sysctl -n hw.ncpu)
else
  MEM_GB=8; CPU=4
fi
JOBS="${JOBS:-$(( CPU < MEM_GB - 6 ? CPU : MEM_GB - 6 ))}"
[[ "$JOBS" -lt 1 ]] && JOBS=1
echo "== 基址 $ORIGIN | 机器 ${CPU}核/${MEM_GB}GB | -j$JOBS =="

cd "$SRC"

if [[ "$DO_GEN" == "1" ]]; then
  echo "== [1/3] 生成游戏代码 =="
  time make GAME=smm2 GUEST_ORIGIN="$ORIGIN" gen
fi

if [[ "$REBUILD" == "0" && -d "ios-build" ]]; then
  echo "== [2/3] 复用 ios-build =="
  cd ios-build
  time make -j"$JOBS"
  cd "$SRC"
else
  echo "== [2/3] 编译 iOS arm64 =="
  export RECOMP_IOS_IDENTITY="${RECOMP_IOS_IDENTITY:?需要 RECOMP_IOS_IDENTITY}"
  export RECOMP_IOS_PROFILE="${RECOMP_IOS_PROFILE:?需要 RECOMP_IOS_PROFILE}"
  export RECOMP_IOS_BUNDLE_ID="${RECOMP_IOS_BUNDLE_ID:?需要 RECOMP_IOS_BUNDLE_ID}"
  export RECOMP_IOS_DATA="${RECOMP_IOS_DATA:-private/smm2}"
  export RECOMP_IOS_NO_SHADERS="${RECOMP_IOS_NO_SHADERS:-1}"
  time make -j"$JOBS" TARGET=ios-arm64 GAME=smm2 DEPS=build/deps-ios \
                GUEST_ORIGIN="$ORIGIN" app
fi

APP="build/smm2-ios-arm64-${TAG}/SMM2Recomp.app"
[[ -d "$APP" ]] || { echo "产物不存在: $APP"; exit 1; }

echo "== [3/3] 校验与打包 =="
BIN="$APP/SMM2Recomp"
echo "-- 旧基址残留 (应为 0):"
xxd -p "$BIN" | tr -d '\n' | grep -o '0000000000000070' | wc -l || true
echo "-- 二进制信息:"
file "$BIN"
codesign -dv "$BIN" 2>&1 | sed -n '1,6p' || true

OUT="$RECOMP_ROOT/SMM2Recomp-ios-${TAG}.ipa"
WORK=$(mktemp -d)
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
find "$WORK/Payload" -name ".DS_Store" -delete
( cd "$WORK" && zip -qry -X "$OUT" Payload )
rm -rf "$WORK"
echo "-- IPA: $OUT ($(du -h "$OUT" | cut -f1))"
