#!/bin/bash
# build-dist-package.sh — 构建「miaomiao翻译器-安装包」（内含 macOS / Windows 两个子包 + 说明）
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PKG="$ROOT/dist/miaomiao翻译器-安装包"

echo "== 1/2 准备 Windows 包（源码 + 词典，不含模型）=="
rm -rf /tmp/win-dist
mkdir -p /tmp/win-dist
rsync -a --exclude '.git' --exclude 'dist' --exclude 'build' \
  --exclude '划词助手' --exclude '划词助手.app' --exclude '*.command' \
  --exclude '*.icns' --exclude 'miaomiao图标.png' --exclude '翻译数据库' \
  --exclude 'neural/models' --exclude 'neural/data' --exclude 'neural/probe_servers.py' --exclude 'neural/setup_remote.py' --exclude 'neural/gpu_status.py' --exclude 'neural/build_ft_models.py' --exclude '部署说明.md' --exclude '发布指南.md' \
  server.js translate.js package.json README.md LICENSE lib public data neural tools windows \
  /tmp/win-dist/
rm -f "$ROOT/dist/miaomiao翻译器-win.zip"
python3 "$ROOT/tools/zip-utf8.py" /tmp/win-dist "$ROOT/dist/miaomiao翻译器-win.zip"

echo "== 2/3 打包 macOS 子包（ditto：保留符号链接/权限/签名）=="
# 必须用 ditto 而非 zip：Python zipfile 会把 app 内的符号链接存成普通文件，
# 解压后代码签名封印破坏，用户会看到「应用已损坏」
rm -f "$ROOT/dist/miaomiao翻译器-mac.zip"
codesign --force --sign - --deep "$ROOT/dist/miaomiao翻译器.app"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/miaomiao翻译器.app" "$ROOT/dist/miaomiao翻译器-mac.zip"

echo "== 3/3 组装安装包 =="
rm -rf "$PKG"
mkdir -p "$PKG/macOS" "$PKG/Windows"
cp "$ROOT/dist/miaomiao翻译器-mac.zip" "$PKG/macOS/"
cp "$ROOT/dist/miaomiao翻译器-win.zip" "$PKG/Windows/"

cat > "$PKG/安装说明.txt" <<'EOF'
miaomiao翻译器 · 安装包

请先确定你的电脑系统，然后进入对应文件夹：
- 苹果电脑（Mac）  → 打开「macOS」文件夹，按里面的安装说明操作
- Windows 电脑     → 打开「Windows」文件夹，按里面的安装说明操作

全程只需要双击鼠标，不需要输入任何命令。
EOF

cat > "$PKG/macOS/安装说明.txt" <<'EOF'
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

cat > "$PKG/Windows/安装说明.txt" <<'EOF'
⚠ 第一步必看：请先把整个压缩包解压到文件夹（右键 → 全部解压），
  不要在压缩包里面直接双击运行，否则会报"找不到 server.js"。

Windows 安装说明 —— 只需 2 步

1. 双击「一键部署.cmd」→ 等待自动下载安装（首次约 5-15 分钟，需联网，全程不用操作）
2. 之后每次使用，双击「启动翻译器.bat」→ 保持黑色窗口打开，
   再打开浏览器，地址栏输入:  http://127.0.0.1:6688  回车即可翻译

划词翻译（可选）：在网页上点一次「开启一键划词」按钮，
之后在任何软件里选中文字 → Ctrl+C → 鼠标旁弹出翻译（托盘图标可退出）。

（首次若被 Windows 提示，选「仍要运行」即可；关闭黑色窗口 = 停止服务）
EOF

cd dist && rm -f miaomiao翻译器-安装包.zip
python3 "$ROOT/tools/zip-utf8.py" "miaomiao翻译器-安装包" "miaomiao翻译器-安装包.zip" "miaomiao翻译器-安装包"
cd "$ROOT"
echo ""
echo "✅ 安装包完成: dist/miaomiao翻译器-安装包.zip ($(du -sh dist/miaomiao翻译器-安装包.zip | cut -f1))"
echo "   结构: macOS/ (app zip + 说明) · Windows/ (win zip + 说明) · 安装说明.txt"
