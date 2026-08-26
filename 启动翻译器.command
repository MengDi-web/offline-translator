#!/bin/bash
# 启动本地离线翻译器（macOS 双击运行）
cd "$(dirname "$0")"
PORT=6688

# 找 Node（常见路径兜底）
if ! command -v node >/dev/null 2>&1; then
  if [ -x /usr/local/bin/node ]; then export PATH="/usr/local/bin:$PATH"
  elif [ -x /opt/homebrew/bin/node ]; then export PATH="/opt/homebrew/bin:$PATH"
  else
    echo "未找到 Node.js，请先安装: https://nodejs.org"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
  fi
fi

# 检查数据是否就绪
if [ ! -f "data/common.json" ] || [ ! -f "data/cedict.json" ]; then
  echo "词典数据缺失，正在下载并构建（需要联网，仅此一次）..."
  node tools/fetch-data.js && node tools/build-index.js || {
    echo "数据准备失败"; read -n 1 -s -r -p "按任意键退出..."; exit 1
  }
fi

node server.js --port "$PORT" &
SERVER_PID=$!
sleep 1
open "http://127.0.0.1:$PORT"
echo "服务已启动: http://127.0.0.1:$PORT （关闭本窗口即停止）"
wait $SERVER_PID
