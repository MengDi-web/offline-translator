#!/bin/bash
# build-macos-app.sh — 构建「miaomiao翻译器.app」一键应用（自包含，无需安装任何东西）
# 用法: bash tools/build-macos-app.sh
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="dist/miaomiao翻译器.app"
NODE_VER="v22.14.0"
NODE_DIR="/tmp/node-portable/node-$NODE_VER-darwin-arm64"

echo "== 1/4 准备便携 Node =="
if [ ! -x "$NODE_DIR/bin/node" ]; then
  mkdir -p /tmp/node-portable
  cd /tmp/node-portable
  [ -f node.tar.gz ] || curl -sL -o node.tar.gz "https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-darwin-arm64.tar.gz"
  tar xzf node.tar.gz
  cd "$ROOT"
fi

echo "== 2/4 准备神经引擎 =="
if [ ! -x "dist/nmt-standalone" ]; then
  HOME=/tmp/pyhome /tmp/offline-nmt-venv/bin/pyinstaller --onefile --name nmt-standalone \
    --collect-all torch --collect-all transformers --collect-all sentencepiece \
    --collect-all sacrebleu --collect-all numpy neural/nmt_server.py
fi

echo "== 3/4 准备划词助手 =="
if [ ! -x "划词助手" ]; then
  swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
    -module-cache-path /tmp/swift-module-cache 划词助手.swift -o 划词助手
fi

echo "== 4/4 组装 .app =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp tools/dist/Info.plist "$APP/Contents/Info.plist"
cp tools/dist/launcher "$APP/Contents/MacOS/launcher"
chmod +x "$APP/Contents/MacOS/launcher"
cp "$NODE_DIR/bin/node" "$APP/Contents/MacOS/node"
cp dist/nmt-standalone "$APP/Contents/MacOS/nmt-standalone"
cp 划词助手 "$APP/Contents/MacOS/划词助手"

# Resources: 项目源码 + 词典 + 模型 + 神经脚本
rsync -a --exclude '.git' --exclude 'dist' --exclude 'build' --exclude '划词助手.app' \
  --exclude '*.command' --exclude '发布指南.md' --exclude 'windows' --exclude '翻译数据库' \
  server.js translate.js package.json lib public data neural tools \
  "$APP/Contents/Resources/"

codesign --force --sign - "$APP" 2>/dev/null
echo ""
echo "✅ 完成: $(du -sh "$APP" | cut -f1)  $APP"
echo "   双击即可运行（自动启动服务+划词助手+打开网页），可发给任何人，无需装任何东西"
