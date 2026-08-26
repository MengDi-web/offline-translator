#!/usr/bin/env node
/**
 * build-index.js — 把原始词典数据 (ECDICT csv + CC-CEDICT json) 转换成
 * 应用运行时使用的轻量索引文件：
 *
 *   data/common.json   ECDICT 按词频取前 N 个常用词（英→中），启动时全量载入内存
 *   data/cedict.json   CC-CEDICT 压缩为数组（中→英），启动时全量载入内存
 *
 * 用法: node tools/build-index.js [--common N] [--full]
 *   --common N  常用词数量上限（默认 60000）
 *   --full      额外生成 data/ecdict.full.json（完整 ECDICT，按词排序，可二分查找，
 *               默认不生成以控制体积；生成后 loader 会自动启用全量查询）
 *
 * 数据来源与许可：
 *   ECDICT     https://github.com/skywind3000/ECDICT  （英汉词典数据，免费）
 *   CC-CEDICT  https://www.mdbg.net/chinese/dictionary?page=cc-cedict （CC-BY-SA-4.0）
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const RAW = path.join(ROOT, 'data', 'raw');
const DATA = path.join(ROOT, 'data');

const args = process.argv.slice(2);
const commonMax = parseArg('--common', args, 60000);
// 默认生成完整 ECDICT 索引（大幅提升短语/生僻词覆盖与联想）
const wantFull = !args.includes('--no-full');

// ---------- ECDICT CSV 解析 ----------
// 列: word,phonetic,definition,translation,pos,collins,oxford,tag,bnc,frq,exchange,detail,audio
// 我们只用: word / phonetic / translation / pos / bnc / frq
function parseCsvLine(line) {
  const cols = [];
  let cur = '', inQ = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '"') {
      if (inQ && line[i + 1] === '"') { cur += '"'; i++; }
      else inQ = !inQ;
    } else if (c === ',' && !inQ) {
      cols.push(cur); cur = '';
    } else cur += c;
  }
  cols.push(cur);
  return cols;
}

function buildEcdict() {
  const csvPath = path.join(RAW, 'ecdict.csv');
  if (!fs.existsSync(csvPath)) {
    console.error(`未找到 ${csvPath}，请先运行 node tools/fetch-data.js 下载数据`);
    process.exit(1);
  }
  console.log('解析 ECDICT csv ...');
  const lines = fs.readFileSync(csvPath, 'utf8').split('\n');
  const entries = [];
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    const c = parseCsvLine(line);
    if (!c[0]) continue;
    const word = c[0].toLowerCase();
    const phonetic = c[1] || '';
    // CSV 里的 \n 是字面反斜杠 n，转成真实换行，作为多义项分隔符
    const translation = (c[3] || '').replace(/\\n/g, '\n').trim();
    if (!translation) continue;
    const pos = c[4] || '';
    const bnc = parseInt(c[8], 10) || 0;
    const frq = parseInt(c[9], 10) || 0;
    // 过滤明显噪声（纯符号、超长）
    if (word.length > 64 || !/[a-z\u00c0-\u024f]/.test(word)) continue;
    const score = frq > 0 ? frq : (bnc > 0 ? bnc * 10 : 0);
    entries.push({ word, phonetic, translation, pos, score });
  }
  console.log(`ECDICT 有效词条: ${entries.length}`);

  // 词频排序取常用词
  const byScore = [...entries].sort((a, b) => b.score - a.score);
  const common = [];
  const seen = new Set();
  for (const e of byScore) {
    if (common.length >= commonMax) break;
    if (seen.has(e.word)) continue;
    seen.add(e.word);
    common.push([e.word, e.phonetic, e.pos, e.translation]);
  }
  // 额外收录高频短语（含空格的多词条目），提升句子直译质量。
  // ECDICT 多词短语大多 bnc/frq 为 0，因此不要求分数，按分数降序取前 12000 条。
  let phraseAdded = 0;
  for (const e of byScore) {
    if (phraseAdded >= 12000) break;
    if (seen.has(e.word)) continue;
    if (!/\s/.test(e.word)) continue;          // 只要多词短语
    if (e.word.length > 60) continue;
    seen.add(e.word);
    common.push([e.word, e.phonetic, e.pos, e.translation]);
    phraseAdded++;
  }
  console.log(`常用词: ${common.length}（含短语 ${phraseAdded}）`);
  fs.writeFileSync(path.join(DATA, 'common.json'), JSON.stringify(common));
  console.log(`已生成 data/common.json (${common.length} 词, ${Math.round(fs.statSync(path.join(DATA, 'common.json')).size / 1048576)}MB)`);

  if (wantFull) {
    // 全量: 按词排序数组，运行时二分查找（只保留 word + trans，控制体积）
    const seenWords = new Set();
    const full = [];
    for (const e of entries) {
      if (seenWords.has(e.word)) continue;
      seenWords.add(e.word);
      full.push([e.word, e.translation]);
    }
    full.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
    fs.writeFileSync(path.join(DATA, 'ecdict.full.json'), JSON.stringify(full));
    console.log(`已生成 data/ecdict.full.json (${full.length} 词, ${Math.round(fs.statSync(path.join(DATA, 'ecdict.full.json')).size / 1048576)}MB)`);
  }
}

// ---------- CC-CEDICT JSON 压缩 ----------
function buildCedict() {
  const jsonPath = path.join(RAW, 'cedict.json');
  if (!fs.existsSync(jsonPath)) {
    console.error(`未找到 ${jsonPath}，请先运行 node tools/fetch-data.js`);
    process.exit(1);
  }
  console.log('解析 CC-CEDICT json ...');
  const raw = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
  // 压缩: [simplified, traditional, pinyin, "def1 / def2 / ..."]
  const out = raw.map(e => [
    e.simplified,
    e.traditional,
    e.pinyin,
    Array.isArray(e.english) ? e.english.join(' / ') : String(e.english),
  ]);
  fs.writeFileSync(path.join(DATA, 'cedict.json'), JSON.stringify(out));
  console.log(`已生成 data/cedict.json (${out.length} 词条, ${Math.round(fs.statSync(path.join(DATA, 'cedict.json')).size / 1048576)}MB)`);
}

function parseArg(name, argv, def) {
  const i = argv.indexOf(name);
  if (i >= 0 && argv[i + 1]) {
    const n = parseInt(argv[i + 1], 10);
    if (!isNaN(n)) return n;
  }
  return def;
}

// ---------- 中文分词词表（jieba 词频 + CC-CEDICT 补充） ----------
// 输出 data/seg-zh.json: [[word, score], ...]，score = log(freq) - log(总词频)
// 用于 Viterbi 动态规划分词：score(path) = Σ score(w)，天然偏好"词数少、词频高"的切分。
function buildSeg() {
  const jiebaPath = path.join(RAW, 'jieba-dict.txt');
  if (!fs.existsSync(jiebaPath)) {
    console.error(`未找到 ${jiebaPath}，请先运行 node tools/fetch-data.js`);
    process.exit(1);
  }
  console.log('构建中文分词词表 ...');
  const lines = fs.readFileSync(jiebaPath, 'utf8').split('\n');
  const wordFreq = new Map();
  for (const l of lines) {
    const m = l.match(/^(\S+)\s+(\d+)/);
    if (!m) continue;
    const w = m[1];
    const f = parseInt(m[2], 10);
    if (!Number.isFinite(f) || f < 30) continue;            // 低频词（覆盖 97.5% 语料即可）
    if (!/^[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+$/.test(w)) continue; // 只收纯中文词
    if (w.length > 12) continue;
    if (f > (wordFreq.get(w) || 0)) wordFreq.set(w, f);
  }
  // 用 CC-CEDICT 的多字词补充（jieba 未收录的，给基础词频 500）
  const cedict = JSON.parse(fs.readFileSync(path.join(DATA, 'cedict.json'), 'utf8'));
  let added = 0;
  for (const [simp] of cedict) {
    if (simp.length >= 2 && simp.length <= 12 && /^[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+$/.test(simp)) {
      if (!wordFreq.has(simp)) { wordFreq.set(simp, 500); added++; }
    }
  }
  let total = 0;
  for (const f of wordFreq.values()) total += f;
  const logT = Math.log(total);
  const unknownScore = Math.log(1) - logT;
  const arr = [['', unknownScore]]; // 空 key 记录未知单字分数
  for (const [w, f] of wordFreq) arr.push([w, Math.log(f) - logT]);
  fs.writeFileSync(path.join(DATA, 'seg-zh.json'), JSON.stringify(arr));
  console.log(`已生成 data/seg-zh.json (${arr.length - 1} 词, 含 cedict 补充 ${added}, ${Math.round(fs.statSync(path.join(DATA, 'seg-zh.json')).size / 1048576)}MB)`);
}

buildEcdict();
buildCedict();
buildSeg();
console.log('完成。');
