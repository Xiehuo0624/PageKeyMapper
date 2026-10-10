#!/bin/bash
#
# 可选：给 PageKeyMapper 创建一个稳定的本地签名身份。
#
# 为什么需要它：
#   build.sh 默认用 ad-hoc 签名。ad-hoc 签名没有稳定身份，"指纹"就等于文件哈希，
#   所以每次重新编译，系统都会认为这是一个**新程序**，之前给的辅助功能权限作废，
#   你得到「系统设置 → 隐私与安全性 → 辅助功能」里重新勾选一次。
#
#   用这个脚本创建一个固定的本地证书后，签名身份就固定了，
#   以后无论重新编译多少次，辅助功能授权都不会掉。
#
# 用法：
#   ./setup-signing.sh         创建身份并给 App 签名
#   ./setup-signing.sh --check 只检查当前状态
#
set -euo pipefail
cd "$(dirname "$0")"

CERT_CN="PageKeyMapper Local Signing"
KEYCHAIN="$(pwd)/build/pkmsign.keychain-db"
KEYCHAIN_PASS="pagekeymapper"
APP="PageKeyMapper.app"

if [ "${1:-}" = "--check" ]; then
  echo "当前 App 签名："
  codesign -dvvv "$APP" 2>&1 | grep -E "Authority|Signature|CDHash=" | sed 's|^|  |'
  echo
  echo "可用的代码签名身份："
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
    security find-identity -v -p codesigning | grep "$CERT_CN" | sed 's|^|  |'
    echo "  → 已配置稳定身份，重新编译不会掉权限 ✅"
  else
    echo "  （无）→ 当前是 ad-hoc 签名，重新编译后需要重新授权"
    echo "     想解决就运行: ./setup-signing.sh"
  fi
  exit 0
fi

echo "== 1/4 生成自签名证书 =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = PageKeyMapper Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/openssl.cnf" 2>/dev/null
# macOS 的 security 工具不认 OpenSSL 3 默认的 AES 加密，必须用 legacy 格式
openssl pkcs12 -export -legacy -out "$TMP/identity.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:tmp 2>/dev/null
echo "   完成"

echo "== 2/4 导入到项目内的独立钥匙串 =="
# 注意：security 命令不吃相对路径，必须用绝对路径
KEYCHAIN="$(pwd)/build/pkmsign.keychain-db"
rm -f "$KEYCHAIN"
mkdir -p build
security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P tmp \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1
echo "   完成：$KEYCHAIN"

echo "== 3/4 把证书标记为受信任 =="
echo "   ⚠️ 接下来会弹出系统对话框要求输入你的登录密码（钥匙串授权），"
echo "      在弹窗里选择「始终信任」并输入密码。"
echo
if security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null; then
  echo "   已设为受信任"
else
  echo "   ✗ 未能设置信任（可能取消了弹窗，或需要管理员权限）。"
  echo "     你可以手动完成：打开「钥匙串访问」→ 选中 $KEYCHAIN →"
  echo "     双击 \"$CERT_CN\" → 展开「信任」→ 代码签名选「始终信任」。"
  echo "     然后重新运行本脚本。"
  exit 1
fi

echo "== 4/4 用新身份给 App 签名 =="
if ! security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$CERT_CN"; then
  echo "   ✗ 身份仍不可用于代码签名，请检查上一步的信任设置。"
  exit 1
fi
codesign --force --deep --keychain "$KEYCHAIN" \
  --sign "$CERT_CN" --timestamp=none "$APP"
echo "   完成"

echo
echo "✅ 搞定。以后 ./build.sh 会自动复用这个身份，重新编译不再掉辅助功能权限。"
echo
echo "验证：./setup-signing.sh --check"
