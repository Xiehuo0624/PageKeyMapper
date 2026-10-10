#!/bin/bash
#
# 把 Sources/main.swift 编译成一个可双击运行的 macOS 应用包 PageKeyMapper.app
#
#   ./build.sh          编译
#   ./build.sh run      编译并打开
#   ./build.sh clean    删除构建产物
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PageKeyMapper"
DISPLAY_NAME="Page Up/Down 方向键映射"
BUNDLE_ID="local.tools.pagekeymapper"
APP="${APP_NAME}.app"
BIN="build/${APP_NAME}"

case "${1:-build}" in
  clean)
    rm -rf build "$APP"
    echo "已清理。"
    exit 0
    ;;
  build|run|"") ;;
  *)
    echo "用法: $0 [build|run|clean]" >&2
    exit 2
    ;;
esac

if ! command -v swiftc >/dev/null 2>&1; then
  echo "错误：找不到 swiftc。请先安装 Xcode 或命令行工具：xcode-select --install" >&2
  exit 1
fi

echo "==> 编译 ${APP_NAME}"
mkdir -p build
# 把 clang 的模块缓存放进项目目录：某些受限环境不允许写系统临时目录，
# 同时也方便清理。
export CLANG_MODULE_CACHE_PATH="$(pwd)/build/modulecache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -O -swift-version 5 \
  -framework Cocoa \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -o "$BIN" \
  Sources/Core.swift Sources/main.swift

echo "==> 组装 ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>        <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>本地小工具</string>
</dict>
</plist>
PLIST

# 签名。辅助功能权限是按代码签名指纹记录的：
#   · ad-hoc 签名（-）没有稳定身份，指纹 = 文件哈希，重新编译就掉权限
#   · 用 setup-signing.sh 建好本地证书后，身份固定，重新编译不再掉权限
SIGN_ID="PageKeyMapper Local Signing"
SIGN_KEYCHAIN="$(pwd)/build/pkmsign.keychain-db"
if command -v codesign >/dev/null 2>&1; then
  if [ -f "$SIGN_KEYCHAIN" ] && \
     security find-identity -v -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> 签名（稳定身份：$SIGN_ID）"
    security unlock-keychain -p pagekeymapper "$SIGN_KEYCHAIN" 2>/dev/null || true
    codesign --force --deep --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_ID" --timestamp=none "$APP" \
      || echo "    (签名失败，回退到 ad-hoc)"
  else
    echo "==> 临时签名（ad-hoc）"
    codesign --force --deep --sign - "$APP" 2>/dev/null || \
      echo "    (签名跳过，不影响使用)"
  fi
fi

echo
echo "完成：$(pwd)/${APP}"
echo
echo "首次运行步骤："
echo "  1) open ${APP}"
echo "  2) 系统会提示需要「辅助功能」权限 → 打开系统设置 → 隐私与安全性 → 辅助功能"
echo "  3) 勾选 ${APP_NAME}（若列表里没有，点 + 号选中 ${APP}）"
echo "  4) 回到程序，菜单栏出现 ↔ 图标即生效（无需重启程序）"
echo
echo "更省事的做法：把 ${APP} 拖进「系统设置 → 通用 → 登录项」实现开机自启。"
echo
if ! { [ -f "$SIGN_KEYCHAIN" ] && security find-identity -v -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_ID"; }; then
  echo "提示：当前是 ad-hoc 签名，重新编译后系统会把它当成新程序，需要重新授权一次。"
  echo "      想一劳永逸就运行 ./setup-signing.sh（只需做一次）。"
  echo
fi

if [ "${1:-build}" = "run" ]; then
  echo "==> 启动"
  open "$APP"
fi
