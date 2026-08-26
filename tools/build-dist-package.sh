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
  --exclude 'neural/models' --exclude 'neural/data' --exclude '部署说明.md' --exclude '发布指南.md' \
  server.js translate.js package.json README.md LICENSE lib public data neural tools windows \
  /tmp/win-dist/
rm -f "$ROOT/dist/miaomiao翻译器-win.zip"
cd /tmp/win-dist && zip -rq "$ROOT/dist/miaomiao翻译器-win.zip" . && cd "$ROOT"

echo "== 2/2 组装安装包 =="
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
macOS（苹果电脑）安装说明 —— 只需 3 步

1. 双击解压 miaomiao翻译器-mac.zip → 得到 miaomiao翻译器.app
2. 双击 miaomiao翻译器.app
3. 若提示「无法验证开发者」：右键点该应用 → 打开 → 再点「打开」（仅第一次）

之后会自动打开翻译网页，菜单栏出现「译」图标。
使用：网页直接输入翻译；划词翻译 = 点网页「开启一键划词」→ 选中文字 → 按 Cmd+C。
无需安装任何东西（Node / Python / 模型都已内置），完全离线。
EOF

cat > "$PKG/Windows/安装说明.txt" <<'EOF'
Windows 安装说明 —— 只需 2 步

1. 双击「一键部署.cmd」→ 等待自动下载安装（首次约 5-15 分钟，需联网，全程不用操作）
2. 之后每次使用，双击「启动翻译器.bat」

使用：打开网页直接输入翻译；划词翻译 = 点网页「开启一键划词」→ 选中文字 → 按 Ctrl+C。
（首次若被 Windows 提示，选「仍要运行」即可）
EOF

cd dist && rm -f miaomiao翻译器-安装包.zip
zip -rq miaomiao翻译器-安装包.zip "miaomiao翻译器-安装包"
cd "$ROOT"
echo ""
echo "✅ 安装包完成: dist/miaomiao翻译器-安装包.zip ($(du -sh dist/miaomiao翻译器-安装包.zip | cut -f1))"
echo "   结构: macOS/ (app zip + 说明) · Windows/ (win zip + 说明) · 安装说明.txt"
