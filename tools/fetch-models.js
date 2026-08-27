#!/usr/bin/env node
/**
 * fetch-models.js — 下载神经翻译模型到 neural/models/（macOS / Windows / Linux 跨平台）
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
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const MODELS = path.join(ROOT, 'neural', 'models');
const RELEASE = process.env.RELEASE_URL || 'https://github.com/MengDi-web/offline-translator/releases/download/models';
const IS_WIN = process.platform === 'win32';
const NULL_DEV = IS_WIN ? 'NUL' : '/dev/null';
const TMP_DIR = os.tmpdir();

// 每个方向需要的小文件（tokenizer/config），Release 与 hf-mirror 都提供
const SMALL_FILES = ['config.json', 'generation_config.json', 'source.spm', 'target.spm', 'vocab.json'];

// 微调权重的 SHA-256（自有 Release 资产的固定值，用于完整性校验；hf-mirror 预训练回退不校验）
const FT_HASHES = {
  'opus-mt-zh-en-ft': '26ad21337e57cb3b93d705664feafc3fbffb1ad378dafa7d139fd4fc6d0db213',
  'opus-mt-en-zh-ft': 'b5ecff1bba068a7b1f855179f5b1fb4d949d3fe57c8031d21f3822ee0a17ab6e',
};

/** 平台相关命令执行（Windows 用 cmd.exe，其它用 bash） */
function sh(cmd, timeout = 600000) {
  if (IS_WIN) execFileSync('cmd.exe', ['/c', cmd], { stdio: 'inherit', timeout });
  else execFileSync('/bin/bash', ['-lc', cmd], { stdio: 'inherit', timeout });
}

/** 计算文件 SHA-256（Windows 用 certutil，其它用 shasum） */
function sha256(file) {
  if (IS_WIN) {
    const out = execFileSync('certutil', ['-hashfile', file, 'SHA256']).toString();
    const m = out.match(/[0-9a-f]{64}/i);
    return m ? m[0].toLowerCase() : '';
  }
  return execFileSync('shasum', ['-a', '256', file]).toString().trim().split(/\s+/)[0];
}

function httpOk(url, maxTime = 10) {
  try {
    const code = execFileSync('curl', ['-sL', '--max-time', String(maxTime), '-o', NULL_DEV, '-w', '%{http_code}', url], { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
    return code.startsWith('2');   // 只有 2xx 才算可用（404 不能当成功）
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
    const binPath = path.join(outDir, 'pytorch_model.bin');
    sh(`curl -sL --retry 3 -o "${binPath}" "${url}"`);
    const want = FT_HASHES[dir];
    if (want) {
      const got = sha256(binPath);
      if (got !== want) {
        fs.unlinkSync(binPath);
        throw new Error(`模型完整性校验失败：${dir} SHA-256 应为 ${want}，实际 ${got}（下载被篡改或损坏，请重试）`);
      }
      console.log(`  ✅ SHA-256 校验通过`);
    }
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
  // 用 Python 转 fp16（需要 torch；Windows 默认项目内 venv，其它平台默认 /tmp venv 或 NMT_PY）
  const py = process.env.NMT_PY || (IS_WIN
    ? path.join(ROOT, 'neural', '.venv', 'Scripts', 'python.exe')
    : '/tmp/offline-nmt-venv/bin/python');
  const scriptPath = path.join(TMP_DIR, 'convert_fp16.py');
  const script = `
import torch, os
from transformers import MarianMTModel
src = r'${outDir}\\pytorch_model.bin.fp32'
m = MarianMTModel.from_pretrained(r'${outDir}')
m.half()
torch.save(m.state_dict(), os.path.join(r'${outDir}', 'pytorch_model.bin'))
os.remove(src)
print('converted to fp16')
`;
  fs.writeFileSync(scriptPath, script);
  sh(`"${py}" "${scriptPath}"`);
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
