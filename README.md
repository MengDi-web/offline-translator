# miaomiao翻译器 🔤↔🀄

**完全离线**的中英互译工具：**神经翻译 + 词典双引擎**，不依赖任何在线 API，不上传任何内容。
含 **macOS 原生划词助手** 与 **Windows 版划词助手**（PowerShell）。

- 🚫 全程不联网：神经模型 + 词典数据全部本地
- 🧠 神经引擎（句子级）：本地微调的 Marian NMT 模型（中→英 / 英→中）
- 📖 词典引擎（词/短语级）：ECDICT + CC-CEDICT + jieba 分词
- 🖱️ 划词翻译：选中文字 → **Cmd+C / Ctrl+C** → 鼠标旁弹出译文（含语境义项、自动补齐、复制按钮、自定义外观）
- 💻 网页界面（http://127.0.0.1:6688）+ 命令行
- 🎛️ 设置：弹窗宽度 / 划词字号 / 翻译字号 / 字体颜色 / 背景色与透明度 / 复制键·关闭键颜色 / 圆角弧度

## 快速开始

```bash
# 依赖: Node.js ≥ 16（macOS 另需 Python 3 以获得神经翻译；无 Python 自动降级词典引擎）

# ① 获取词典数据（仓库含 data/ 可跳过；否则联网生成一次）
node tools/fetch-data.js && node tools/build-index.js

# ② 获取神经模型（优先 Release 微调版；回退 hf-mirror 预训练）
node tools/fetch-models.js

# ③ 启动
node server.js        # 网页界面 → http://127.0.0.1:6688
```

**macOS 划词**：双击 `划词翻译.command`（自动起服务 + 后台常驻启动助手，**可完全关闭终端**；助手发现服务未运行会自动拉起，无需再开终端；菜单栏「译」图标可设置/退出）。
**Windows 划词**：双击 `windows\start_translator.bat`（详见 [windows/安装说明.md](windows/安装说明.md)）。

## 划词翻译（双平台）

| 能力 | 说明 |
|---|---|
| Ctrl+C/Cmd+C 触发 | 复制即翻译，弹窗出现在鼠标旁，点「✕」关闭 |
| 自动补齐 | 划词不完整自动补全（如 appl → apple；人工 → 人工智能） |
| 语境义项 | 词典多义词按上下文排序（bank 在河畔语境 → 岸） |
| 词/句分流 | 词走词典+语境；整句走神经翻译 |
| 乱码防御 | 识别复制保护产生的垃圾（花括号/波浪线/等号串）并提示 |
| 设置 | 弹窗形式 / 字号 / 字体颜色 / 背景 / 其它（按键颜色），全部持久保存 |

## 目录结构

```
├── server.js            零依赖本地服务器（node:http + 神经子进程）
├── translate.js         命令行入口
├── lib/                 词典引擎 + 划词上下文服务（context.js）
├── public/index.html    网页界面（单文件，三引擎模式）
├── neural/
│   ├── models/          神经模型（Release 附件下载，不入库）
│   ├── nmt_server.py    常驻神经翻译后端
│   ├── fine_tune.py     微调脚本（CUDA/MPS 自适应）
│   └── eval_*.py        评测（clean-dev / 长难句分领域）
├── 划词助手.swift        macOS 划词助手源码（AppKit）
├── windows/             Windows 版（PowerShell 划词助手 + 启动脚本 + 安装说明）
├── tools/               词典/模型构建脚本
└── data/                词典数据（ECDICT / CC-CEDICT / jieba）
```

## 训练报告

中→英模型在 [Helsinki opus-mt-zh-en](https://huggingface.co/Helsinki-NLP/opus-mt-zh-en) 基础上，
用 13.9 万对平行语料（WikiMatrix + TED + WMT-News + 长难句库）在 GPU 服务器上微调：
**dev BLEU 40.85**，长难句分领域 BLEU **48.29**（金融 55 / 政社 50 / 医学 46）。
英→中采用 opus-mt-en-zh 预训练（fp16 压缩）。训练脚本见 `neural/`。

### 迭代中的关键教训
1. `spm.encode(out_type=int)` 返回的是 spm **局部 id**，必须经 `convert_tokens_to_ids` 映射到模型词表
2. transformers 5.x 移除了 `as_target_tokenizer`，需手工用 `spm_target` 编码目标侧
3. 语言检测 CJK 正则必须带 `/g` 标志（否则中英混合文本被误判为英文）

## 许可与致谢

- 本仓库代码：**MIT**（见 LICENSE）
- 词典数据：[ECDICT](https://github.com/skywind3000/ECDICT)（免费英汉）、[CC-CEDICT](https://www.mdbg.net/chinese/dictionary?page=cc-cedict)（CC-BY-SA 4.0）、[jieba](https://github.com/fxsjy/jieba)（MIT）
- 模型：[Helsinki-NLP/opus-mt](https://huggingface.co/Helsinki-NLP)（MIT）
- 长难句训练语料：本仓库 `翻译数据库/`（用户自制，用于微调与分领域评测）

> 注意事项：`neural/data/` 中的平行语料（来自 WikiMatrix/TED/WMT）因各自许可不同**不入库**，
> 仅提供 `neural/prepare.py` 等构建脚本，可自行下载 OPUS 语料重建。
