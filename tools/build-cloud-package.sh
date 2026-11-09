#!/bin/bash
# build-cloud-package.sh — 构建「网盘分发版」：不依赖 GitHub
#   Windows: 内置模型(297MB, 部署时跳过模型下载) + Node/Python 走国内镜像
#   macOS:   ditto 打包(保留符号链接/签名), 完全自包含
#   输出: dist/网盘分发/
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

echo "== 1/3 Windows 完整版（内置模型）=="
rm -rf /tmp/win-full && mkdir -p /tmp/win-full
rsync -a --exclude '.git' --exclude 'dist' --exclude 'build' \
  --exclude '划词助手' --exclude '划词助手.app' --exclude '*.command' \
  --exclude '*.icns' --exclude 'miaomiao图标.png' --exclude '翻译数据库' \
  --exclude 'neural/data' --exclude 'neural/probe_servers.py' --exclude 'neural/setup_remote.py' \
  --exclude 'neural/gpu_status.py' --exclude 'neural/build_ft_models.py' \
  --exclude '部署说明.md' --exclude '发布指南.md' --exclude '*.DS_Store' \
  server.js translate.js package.json README.md LICENSE lib public data neural tools windows \
  /tmp/win-full/
rm -f "/tmp/win-full/neural/models/opus-mt-zh-en-ft/opus-mt-zh-en-ft-pytorch_model.bin" \
      "/tmp/win-full/neural/models/opus-mt-en-zh-ft/opus-mt-en-zh-ft-pytorch_model.bin"
# 内置 Windows Python 依赖 wheel（离线安装，无需联网）
WHEELS="$ROOT/dist/wheels-win"
if [ ! -d "$WHEELS" ] || [ -z "$(ls "$WHEELS"/*.whl 2>/dev/null)" ]; then
  echo "   下载 Windows 依赖 wheel（仅构建机需要联网）..."
  mkdir -p "$WHEELS"
  python3 -m pip download torch --index-url https://download.pytorch.org/whl/cpu \
    --platform win_amd64 --python-version 312 --only-binary=:all: -d "$WHEELS" -q
  python3 -m pip download transformers sentencepiece sacrebleu \
    --platform win_amd64 --python-version 312 --only-binary=:all: -d "$WHEELS" -q
fi
cp -R "$WHEELS" /tmp/win-full/wheels

# 内置 Node / Python 运行时（完全离线安装）
OFFLINE="$ROOT/dist/offline-win"
if [ -d "$OFFLINE" ] && [ -n "$(ls "$OFFLINE"/* 2>/dev/null)" ]; then
  mkdir -p /tmp/win-full/offline && cp "$OFFLINE"/* /tmp/win-full/offline/
fi

rm -f "$ROOT/dist/miaomiao翻译器-win-完整版.zip"
python3 "$ROOT/tools/zip-utf8.py" /tmp/win-full "$ROOT/dist/miaomiao翻译器-win-完整版.zip"

echo "== 2/3 macOS 子包（ditto）=="
codesign --force --sign - --deep "$ROOT/dist/miaomiao翻译器.app"
rm -f "$ROOT/dist/miaomiao翻译器-mac.zip"
ditto -c -k --sequesterRsrc --keepParent \
  "$ROOT/dist/miaomiao翻译器.app" "$ROOT/dist/miaomiao翻译器-mac.zip"

echo "== 3/3 组装网盘分发目录 =="
OUT="$ROOT/dist/网盘分发"
rm -rf "$OUT"
mkdir -p "$OUT/macOS" "$OUT/Windows"
cp "$ROOT/dist/miaomiao翻译器-mac.zip" "$OUT/macOS/"
cp "$ROOT/dist/miaomiao翻译器-win-完整版.zip" "$OUT/Windows/"

cat > "$OUT/macOS/安装说明.txt" <<'EOF'
macOS（苹果电脑）安装说明

适用条件：仅支持 Apple 芯片（M1 / M2 / M3 / M4），系统 macOS 11 及以上。
（Intel 芯片的旧 Mac 不支持）

【安装 3 步】
1. 双击解压 miaomiao翻译器-mac.zip
   （用系统自带「归档实用工具」解压，不要用第三方解压软件）
   → 得到 miaomiao翻译器.app
2. 把 miaomiao翻译器.app 拖到「应用程序」文件夹
3. 首次打开（未签名软件，macOS 会拦一次）：
   · 双击 miaomiao翻译器.app
   · 若提示「无法验证开发者」或「Apple 无法验证…」：
     打开「系统设置」→「隐私与安全性」→ 往下滚动找到「安全性」
     → 点「仍要打开」→ 输入电脑密码 → 再点「仍要打开」
   · （macOS 14 及更早系统：也可右键点 app → 打开 → 再点「打开」）

首次启动约 10-20 秒（后台要加载翻译引擎），窗口出现前请稍等，不要重复双击。

【使用】
· 窗口里输入文字 → 自动翻译（可在右上角切换主题）
· 划词：点右上角「开启一键划词」→ 选中文字按 Cmd+C → 弹窗翻译

【安全】
· 完全离线：Node / Python / 模型 / 词典全部内置，不联网、不上传
· 不需要管理员权限，不写系统目录，只监听本机 127.0.0.1
· 卸载：直接把 app 拖到废纸篓，无残留

EOF

cat > "$OUT/Windows/安装说明.txt" <<'EOF'
Windows 安装说明 —— 2 步 + 每次 1 步

【第一次，约 5-10 分钟】
  ⚠ 请解压到「纯英文路径」（如 D:\miaomiao），不要放中文文件夹或微信/QQ 接收目录，
    中文路径会导致翻译模型加载失败。
1. 先解压整个压缩包到文件夹（右键 → 全部解压；不要在压缩包里直接双击）
2. 进入解压出的文件夹 → windows → 双击「一键部署.cmd」
   【完全离线】翻译模型、Python 依赖、Node 和 Python 运行时全部内置，
   全程无需联网，不会卡在下载，约 5-10 分钟装完。

【以后每次使用】
1. 双击 windows\启动翻译器.bat → 保持黑色窗口打开
2. 会自动弹出独立窗口（无地址栏，像软件一样，无需手动输网址）
   如果窗口没弹出：打开浏览器，地址栏输入 http://127.0.0.1:6688 → 回车

划词（可选）：网页上点一次「开启一键划词」→ 之后任意软件选中文字按 Ctrl+C 弹窗翻译。

注意：黑色窗口就是服务，不要关闭；关掉就停止翻译。
安全：不需要管理员权限（Python 装到当前用户），不写注册表，只监听本机 127.0.0.1。
卸载：直接删除整个文件夹即可。
EOF

cat > "$OUT/安装说明.txt" <<'EOF'
miaomiao翻译器 · 网盘分发版
=============================
按对方的电脑系统发对应的文件夹：

  macOS\miaomiao翻译器-mac.zip        苹果电脑用（Apple 芯片 M1-M4）
  Windows\miaomiao翻译器-win-完整版.zip  Windows 电脑用（模型已内置）

都是完全离线的中英互译工具：
· 词典 + 本地神经翻译双引擎
· 不联网、不上传、不需要管理员权限
· 卸载 = 删除文件，零残留

各文件夹内有该系统的详细安装说明。
EOF

echo "✅ 网盘分发版完成: dist/网盘分发/ ($(du -sh "$OUT" | cut -f1))"
echo "   macOS/  ·  Windows/"
