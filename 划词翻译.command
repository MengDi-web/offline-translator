#!/bin/bash
# 划词翻译.command — 启动本地翻译服务 + 剪贴板翻译助手（macOS 双击运行）
cd "$(dirname "$0")"
PORT=6688

# 1. 确保 Node 可用
if ! command -v node >/dev/null 2>&1; then
  if [ -x /usr/local/bin/node ]; then export PATH="/usr/local/bin:$PATH"
  elif [ -x /opt/homebrew/bin/node ]; then export PATH="/opt/homebrew/bin:$PATH"
  else
    echo "未找到 Node.js，请先安装: https://nodejs.org"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
  fi
fi

# 2. 确保词典数据就绪
if [ ! -f "data/common.json" ] || [ ! -f "data/cedict.json" ]; then
  echo "词典数据缺失，请先运行 node tools/fetch-data.js && node tools/build-index.js"
  read -n 1 -s -r -p "按任意键退出..."; exit 1
fi

# 3. 确保翻译服务在后台运行（助手依赖它）
if ! curl -s -m 2 "http://127.0.0.1:$PORT/api/stats" >/dev/null 2>&1; then
  echo "启动本地翻译服务 (http://127.0.0.1:$PORT) ..."
  (node server.js --port "$PORT" > /tmp/translator-server.log 2>&1 &)
  sleep 2
fi

# 4. 确保划词助手已编译并打包成 .app
BIN="./划词助手.app/Contents/MacOS/划词助手"
if [ ! -x "$BIN" ]; then
  echo "编译划词助手 ..."
  swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
    -module-cache-path /tmp/swift-module-cache 划词助手.swift -o 划词助手 || {
      echo "编译失败（需要 Xcode Command Line Tools: xcode-select --install）"
      read -n 1 -s -r -p "按任意键退出..."; exit 1
    }
  mkdir -p 划词助手.app/Contents/MacOS
  cp 划词助手 划词助手.app/Contents/MacOS/划词助手
  codesign --force --sign - 划词助手.app 2>/dev/null
fi

# 5. 清理旧实例（避免残留弹窗/重复进程）
pkill -9 -f "划词助手.app/Contents/MacOS/划词助手" 2>/dev/null
pkill -9 -x "划词助手" 2>/dev/null
sleep 0.5

# 6. 启动（保持本窗口打开；最小化即可）
echo ""
echo "划词助手已启动（无需辅助功能授权）"
echo "  ▶ 使用方式：选中文字后按 Cmd+C（复制），翻译弹窗即出现"
echo "  ▶ 设置：点击菜单栏「译」图标 → 设置…"
echo "  ▶ 保持本窗口打开，按 Ctrl+C 退出"
"$BIN"
