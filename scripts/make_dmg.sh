#!/usr/bin/env bash
# 制作拖拽式 DMG 安装镜像（zSnap.app + 指向 /Applications 的快捷方式）。
# 用法：./scripts/make_dmg.sh [--no-build]
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--no-build" ]]; then
  ./scripts/bundle.sh
fi

APP_SRC="build/zSnap.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "错误：未找到 $APP_SRC，请先运行 ./scripts/bundle.sh" >&2
  exit 1
fi

VERSION=$(defaults read "$(pwd)/$APP_SRC/Contents/Info" CFBundleShortVersionString)
STAGING="build/dmg-staging"
DMG="build/zSnap-${VERSION}.dmg"

rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP_SRC" "$STAGING/zSnap.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "zSnap ${VERSION}" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -ov "$DMG" | tail -1

rm -rf "$STAGING"

echo "==> DMG 已生成：$DMG"
echo "==> 使用：双击打开，将 zSnap 拖入 Applications 文件夹"
