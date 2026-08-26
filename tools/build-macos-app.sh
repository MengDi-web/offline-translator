#!/bin/bash
# build-macos-app.sh — 构建「miaomiao翻译器.app」一键应用（自包含，无需安装任何东西）
# 用法: bash tools/build-macos-app.sh
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="dist/miaomiao翻译器.app"
NODE_VER="v22.14.0"
NODE_DIR="/tmp/node-portable/node-$NODE_VER-darwin-arm64"
PYLIB_SRC="/tmp/offline-nmt-venv/lib/python3.12/site-packages"

echo "== 1/4 准备便携 Node =="
if [ ! -x "$NODE_DIR/bin/node" ]; then
  mkdir -p /tmp/node-portable
  cd /tmp/node-portable
  [ -f node.tar.gz ] || curl -sL -o node.tar.gz "https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-darwin-arm64.tar.gz"
  tar xzf node.tar.gz
  cd "$ROOT"
fi

echo "== 2/4 准备划词助手 =="
if [ ! -x "划词助手" ]; then
  swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
    -module-cache-path /tmp/swift-module-cache 划词助手.swift -o 划词助手
fi

echo "== 3/4 准备可搬移 Python（python-build-standalone）=="
PY_DIR="/tmp/pyportable/python"
if [ ! -x "$PY_DIR/bin/python3.12" ]; then
  mkdir -p /tmp/pyportable
  cd /tmp/pyportable
  PY_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260825/cpython-3.12.14%2B20260825-aarch64-apple-darwin-install_only.tar.gz"
  echo "  下载便携 Python（镜像优先）..."
  curl -sL --max-time 300 -o py.tar.gz "https://ghfast.top/$PY_URL" \
    || curl -sL --max-time 600 -o py.tar.gz "$PY_URL"
  tar xzf py.tar.gz
  cd "$ROOT"
fi

echo "== 4/4 打包 Python 库 + 组装 .app =="
rm -rf /tmp/python-libs
mkdir -p /tmp/python-libs
rsync -a --exclude '__pycache__' --exclude '*.pyc' --exclude 'tests' --exclude 'pyinstaller*' \
  "$PYLIB_SRC/" /tmp/python-libs/
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp tools/dist/Info.plist "$APP/Contents/Info.plist"
cp tools/dist/launcher "$APP/Contents/MacOS/launcher"
chmod +x "$APP/Contents/MacOS/launcher"
cp "$NODE_DIR/bin/node" "$APP/Contents/MacOS/node"
cp 划词助手 "$APP/Contents/MacOS/划词助手"
rsync -a "$PY_DIR/" "$APP/Contents/Resources/python/"          # 可搬移 Python 解释器
rsync -a /tmp/python-libs/ "$APP/Contents/Resources/python-libs/"
rsync -a --exclude '.git' --exclude 'dist' --exclude 'build' --exclude '划词助手.app' \
  --exclude '*.command' --exclude '发布指南.md' --exclude 'windows' --exclude '翻译数据库' \
  server.js translate.js package.json lib public data neural tools \
  "$APP/Contents/Resources/"

codesign --force --sign - "$APP" 2>/dev/null
echo ""
echo "✅ 完成: $(du -sh "$APP" | cut -f1)  $APP"
echo "   完全自包含（内置 Node + Python + 模型），双击即用，无需安装任何东西"
