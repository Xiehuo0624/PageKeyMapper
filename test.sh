#!/bin/bash
#
# 编译并运行单元测试。
#
# 安全保证（重要）：
#   · 只编译一个独立的测试二进制到 build/，**绝不动 PageKeyMapper.app**，
#     所以已经授权好的正式程序不受任何影响。
#   · 测试程序不创建 CGEventTap、不投递任何按键事件，
#     所以**不会弹出辅助功能授权请求**，也不需要任何系统权限。
#
# 如果你在跑测试时看到授权弹窗，那是 bug，请报告。
#
set -euo pipefail
cd "$(dirname "$0")"

export CLANG_MODULE_CACHE_PATH="$(pwd)/build/modulecache"
mkdir -p build "$CLANG_MODULE_CACHE_PATH"

echo "==> 编译测试程序（独立二进制，不影响 PageKeyMapper.app）"
swiftc -swift-version 5 \
  -framework Cocoa \
  -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -o build/selftest \
  Sources/Core.swift Sources/selftest/main.swift

echo "==> 运行测试"
exec ./build/selftest
