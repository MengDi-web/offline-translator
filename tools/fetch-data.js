#!/usr/bin/env node
/**
 * fetch-data.js — 一次性下载开源离线词典数据到 data/raw/。
 * 只需在有网的时候执行一次；之后的翻译完全离线，不再需要网络。
 *
 *   ECDICT (英→中, ~66MB)     https://unpkg.com/ecdict@0.0.4/assets/ecdict.csv
 *   CC-CEDICT (中→英, ~16MB)  https://unpkg.com/cedict-json@1.3.20251213/cedict.json
 *   jieba 分词词频 (~5.7MB)   https://cdn.jsdelivr.net/gh/fxsjy/jieba@master/jieba/dict.txt
 *
 * 用法: node tools/fetch-data.js
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const RAW = path.join(ROOT, 'data', 'raw');

const SOURCES = [
  {
    name: 'ecdict.csv',
    url: 'https://unpkg.com/ecdict@0.0.4/assets/ecdict.csv',
    size: 65936699,
    note: 'ECDICT 英汉词典 (skywind3000/ECDICT)',
  },
  {
    name: 'cedict.json',
    url: 'https://unpkg.com/cedict-json@1.3.20251213/cedict.json',
    size: 16527854,
    note: 'CC-CEDICT 汉英词典 (CC-BY-SA-4.0)',
  },
  {
    name: 'jieba-dict.txt',
    url: 'https://cdn.jsdelivr.net/gh/fxsjy/jieba@master/jieba/dict.txt',
    size: 5970000,
    note: 'jieba 中文分词词频词典 (fxsjy/jieba, MIT)',
  },
];

fs.mkdirSync(RAW, { recursive: true });

for (const src of SOURCES) {
  const dest = path.join(RAW, src.name);
  if (fs.existsSync(dest) && fs.statSync(dest).size > src.size * 0.9) {
    console.log(`[跳过] ${dest} 已存在`);
    continue;
  }
  console.log(`[下载] ${src.note}: ${src.url}`);
  try {
    execFileSync('curl', ['-sL', '--retry', '2', '-o', dest, src.url], {
      stdio: 'inherit',
      timeout: 600000,
    });
    const size = fs.statSync(dest).size;
    console.log(`[完成] ${dest} (${Math.round(size / 1048576)}MB)`);
  } catch (e) {
    console.error(`[失败] ${src.url}: ${e.message}`);
    process.exitCode = 1;
  }
}

console.log('\n数据就绪。下一步: node tools/build-index.js');
