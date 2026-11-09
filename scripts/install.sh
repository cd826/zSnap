#!/usr/bin/env bash
# 一键安装 zSnap 到 /Applications 并启动。
# 用法：./scripts/install.sh [--no-build]（--no-build 跳过重新编译，直接安装现有 build 产物）
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--no-build" ]]; then
  ./scripts/bundle.sh
fi

APP_SRC="build/zSnap.app"
APP_DST="/Applications/zSnap.app"

if [[ ! -d "$APP_SRC" ]]; then
  echo "错误：未找到 $APP_SRC，请先运行 ./scripts/bundle.sh" >&2
  exit 1
fi

# 1. 退出正在运行的实例（旧构建或已安装版本）。
osascript -e 'quit app "zSnap"' 2>/dev/null || true
sleep 1

# 2. 移除旧安装并拷贝新版本。
#    ditto 保留扩展属性与代码签名，比 cp -R 更可靠。
rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"

# 3. 校验签名完好。
codesign --verify --strict "$APP_DST"

echo "==> 已安装：$APP_DST"

# 4. 启动。
open "$APP_DST"
echo "==> zSnap 已启动（菜单栏取景框图标）"
echo "提示："
echo "  - 屏幕录制授权与代码签名绑定（zSnap Dev），移动安装后无需重新授权"
echo "  - 如需开机启动，请在 设置 → 登录时启动 重新开关一次（安装路径变更后建议刷新）"
