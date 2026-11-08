#!/usr/bin/env bash
# 构建 zSnap.app：SPM release 产物 + 手工组装 Bundle。
# 用法：./scripts/bundle.sh
# 可选：ZSNAP_SIGN_IDENTITY="Apple Development: ..." ./scripts/bundle.sh
#       （稳定签名可让屏幕录制授权在重建后保留；默认 ad-hoc 签名，每次重建需重新授权，见 Phase 0 报告）
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="release"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/zSnap"
if [[ ! -f "$BIN" ]]; then
  echo "错误：未找到可执行文件 $BIN" >&2
  exit 1
fi

APP_DIR="build/zSnap.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>zSnap</string>
    <key>CFBundleExecutable</key>
    <string>zSnap</string>
    <key>CFBundleIdentifier</key>
    <string>com.cd826.zSnap</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>zSnap</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
cp "$BIN" "$APP_DIR/Contents/MacOS/zSnap"

# 签名：优先级 ZSNAP_SIGN_IDENTITY 环境变量 > 自签名证书 zSnap Dev > ad-hoc。
# 稳定签名身份可让屏幕录制授权在重建后保留（ad-hoc 每次重建哈希变化会导致授权失效）。
SIGN_IDENTITY="${ZSNAP_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-certificate -c "zSnap Dev" login.keychain >/dev/null 2>&1; then
    SIGN_IDENTITY="zSnap Dev"
  else
    SIGN_IDENTITY="-"
    echo "提示：未找到 zSnap Dev 证书，使用 ad-hoc 签名（每次重建需重新授权屏幕录制）"
  fi
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"
echo "==> 签名身份：$SIGN_IDENTITY"

echo "==> 构建完成：$APP_DIR"
echo "==> 运行：open $APP_DIR"
