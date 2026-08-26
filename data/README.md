# 离线中英互译词典数据说明

本项目内置两份开源离线词典数据（已生成压缩索引，运行时完全不联网）：

## 1. ECDICT — 英汉词典
- 来源: https://github.com/skywind3000/ECDICT
- 用途: 英文单词/短语 → 中文释义（含音标、词性）
- 获取方式: npm 包 `ecdict@0.0.4`（`assets/ecdict.csv`，约 66MB）
- 本项目使用其常用词子集（约 6 万词 + 1.2 万短语），生成 `data/common.json`

## 2. CC-CEDICT — 汉英词典
- 来源: https://www.mdbg.net/chinese/dictionary?page=cc-cedict
- 用途: 中文（简/繁）→ 英文释义（含拼音）
- 许可: **CC-BY-SA 4.0**
- 获取方式: npm 包 `cedict-json@1.3.20251213`（`cedict.json`，约 16.5MB）
- 本项目生成 `data/cedict.json`

## 3. jieba 分词词频词典（中文分词）
- 来源: https://github.com/fxsjy/jieba （MIT 许可）
- 用途: 中文句子切词（词频模型 + Viterbi 动态规划），解决
  "南京市长江大桥" 这类歧义切分
- 获取方式: `https://cdn.jsdelivr.net/gh/fxsjy/jieba@master/jieba/dict.txt`
- 本项目取其词频 ≥30 的纯中文词（覆盖 97.5% 语料），并合并
  CC-CEDICT 多字词（基础词频 500），生成 `data/seg-zh.json`

## 4. 可选: 完整版 ECDICT（增强英→中覆盖）
- 默认生成 `data/ecdict.full.json`（约 38MB，懒加载 + 二分查找 + 联想纠错）
- 不需要可运行 `node tools/build-index.js --no-full` 重建以节省空间

## 数据重建
```bash
node tools/fetch-data.js    # 一次性下载原始数据（需联网）
node tools/build-index.js   # 生成压缩索引（本地运行）
```

## 许可与致谢
- ECDICT 数据免费开放，版权归其作者 skywind3000 所有
- CC-CEDICT 依据 CC-BY-SA 4.0 许可使用，版权归 MDBG 及贡献者所有
- 本项目代码 (server.js / lib / tools / public) 为 MIT 许可

*翻译结果为词典级直译（单词/短语精确释义 + 句子逐词直译），
不是神经网络整句翻译 —— 这是"完全离线"的代价，但查词查短语非常可靠。*
