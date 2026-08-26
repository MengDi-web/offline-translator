#!/usr/bin/env node
/**
 * fetch-models.js — 下载神经翻译模型到 neural/models/
 *
 * 优先从 GitHub Release 附件下载微调模型（离线翻译器仓库 Release 中的 models 资产）；
 * 若 Release 不可用，回退从 hf-mirror 下载预训练模型并用本地 Python 转成 fp16。
 *
 * 用法:
 *   node tools/fetch-models.js                      # 默认 Release 地址
 *   RELEASE_URL=https://github.com/MengDi-web/offline-translator/releases/download/models node tools/fetch-models.js
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const MODELS = path.join(ROOT, 'neural', 'models');
const RELEASE = process.env.RELEASE_URL || 'https://github.com/MengDi-web/offline-translator/releases/download/models';

// 每个方向需要的小文件（tokenizer/config），Release 与 hf-mirror 都提供
const SMALL_FILES = ['config.json', 'generation_config.json', 'source.spm', 'target.spm', 'vocab.json'];

const DIRS = {
  'opus-mt-zh-en-ft': { hf: 'Helsinki-NLP/opus-mt-zh-en', bin: 'opus-mt-zh-en-ft-pytorch_model.bin' },
  'opus-mt-en-zh-ft': { hf: 'Helsinki-NLP/opus-mt-en-zh', bin: 'opus-mt-en-zh-ft-pytorch_model.bin' },
};

function sh(cmd, timeout = 600000) {
  execFileSync('/bin/bash', ['-lc', cmd], { stdio: 'inherit', timeout });
}

function httpOk(url, maxTime = 10) {
  try {
    execFileSync('curl', ['-sL', '--max-time', String(maxTime), '-o', '/dev/null', '-w', '%{http_code}', url], { stdio: 'pipe' });
    return true;
  } catch { return false; }
}

function downloadSmallFromHF(outDir, hfRepo) {
  fs.mkdirSync(outDir, { recursive: true });
  for (const f of SMALL_FILES) {
    sh(`curl -sL --retry 3 -o "${outDir}/${f}" "https://hf-mirror.com/${hfRepo}/resolve/main/${f}"`);
  }
}

function downloadFromRelease(dir, info) {
  const outDir = path.join(MODELS, dir);
  fs.mkdirSync(outDir, { recursive: true });
  downloadSmallFromHF(outDir, info.hf);   // 小文件与预训练一致，统一从 hf-mirror
  const url = `${RELEASE}/${info.bin}`;
  if (httpOk(url)) {
    sh(`curl -sL --retry 3 -o "${path.join(outDir, 'pytorch_model.bin')}" "${url}"`);
    console.log(`✅ ${dir} 已从 Release 下载微调权重`);
    return true;
  }
  return false;
}

function downloadFromHFAndConvert(dir, hfRepo) {
  const outDir = path.join(MODELS, dir);
  fs.mkdirSync(outDir, { recursive: true });
  console.log(`⬇️  从 hf-mirror 下载预训练 ${hfRepo}（无微调权重，可用但非最优）...`);
  for (const f of SMALL_FILES) {
    sh(`curl -sL --retry 3 -o "${outDir}/${f}" "https://hf-mirror.com/${hfRepo}/resolve/main/${f}"`);
  }
  sh(`curl -sL --retry 3 -o "${outDir}/pytorch_model.bin.fp32" "https://hf-mirror.com/${hfRepo}/resolve/main/pytorch_model.bin"`);
  // 用 Python 转 fp16（需要 torch）
  const py = process.env.NMT_PY || '/tmp/offline-nmt-venv/bin/python';
  const script = `
import torch, os
from transformers import MarianMTModel
src = '${outDir}/pytorch_model.bin.fp32'
m = MarianMTModel.from_pretrained('${outDir}')
m.half()
torch.save(m.state_dict(), os.path.join('${outDir}', 'pytorch_model.bin'))
os.remove(src)
print('converted to fp16')
`;
  fs.writeFileSync('/tmp/convert_fp16.py', script);
  sh(`${py} /tmp/convert_fp16.py`);
  console.log(`✅ ${dir} 已从 hf-mirror 下载并转 fp16`);
}

function main() {
  fs.mkdirSync(MODELS, { recursive: true });
  for (const [dir, info] of Object.entries(DIRS)) {
    const outDir = path.join(MODELS, dir);
    if (fs.existsSync(path.join(outDir, 'pytorch_model.bin'))) {
      console.log(`[跳过] ${dir} 已存在`);
      continue;
    }
    if (!downloadFromRelease(dir, info)) {
      console.log(`[回退] Release 不可用，改用 hf-mirror 预训练 ${info.hf}`);
      downloadFromHFAndConvert(dir, info.hf);
    }
  }
  console.log('\n完成。启动: node server.js （自动加载 neural/models/）');
}

main();
