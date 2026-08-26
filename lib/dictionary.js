/**
 * dictionary.js — 词典加载与查询（纯本地，零依赖）。
 *
 * 数据文件（由 tools/build-index.js 生成）：
 *   data/common.json       ECDICT 常用词（英→中），启动时载入内存
 *   data/cedict.json       CC-CEDICT（中→英），启动时载入内存
 *   data/ecdict.full.json  完整 ECDICT（可选，懒加载，二分查找）
 */
'use strict';

const fs = require('fs');
const path = require('path');

const DATA_DIR = path.join(__dirname, '..', 'data');
const COMMON_PATH = path.join(DATA_DIR, 'common.json');
const CEDICT_PATH = path.join(DATA_DIR, 'cedict.json');
const FULL_PATH = path.join(DATA_DIR, 'ecdict.full.json');
const SEG_PATH = path.join(DATA_DIR, 'seg-zh.json');

let enMap = null;      // Map<word, {ph, pos, trans}>
let zhMap = null;      // Map<key, idx>  (key = 简体 / 繁体)
let zhEntries = null;  // [[simp, trad, pinyin, defs], ...]
let fullArray = null;  // [[word, trans], ...] 按 word 排序（懒加载）
let segMap = null;     // Map<word, score> 中文分词词表
let segUnknown = 0;    // 未知单字分数

function load() {
  if (enMap && zhMap) return;
  const t0 = Date.now();

  // ECDICT 常用词
  enMap = new Map();
  if (fs.existsSync(COMMON_PATH)) {
    const arr = JSON.parse(fs.readFileSync(COMMON_PATH, 'utf8'));
    for (const [word, ph, pos, trans] of arr) {
      enMap.set(word, { ph, pos, trans });
    }
  }

  // CC-CEDICT
  zhEntries = [];
  zhMap = new Map();
  if (fs.existsSync(CEDICT_PATH)) {
    zhEntries = JSON.parse(fs.readFileSync(CEDICT_PATH, 'utf8'));
    // 同词多条目时保留义项最多的（如 说: shui4"劝说" vs shuo1"说话" → 保留 shuo1）
    const senseCounts = zhEntries.map(e => e[3].split(' / ').length);
    for (let i = 0; i < zhEntries.length; i++) {
      const [simp, trad] = zhEntries[i];
      if (simp && (!zhMap.has(simp) || senseCounts[i] > senseCounts[zhMap.get(simp)])) zhMap.set(simp, i);
      if (trad && (!zhMap.has(trad) || senseCounts[i] > senseCounts[zhMap.get(trad)])) zhMap.set(trad, i);
    }
  }

  console.error(`[dict] 载入完成: EN ${enMap.size} 词, ZH ${zhMap.size} 词条, ${Date.now() - t0}ms`);
}

function stats() {
  load();
  return {
    enCommon: enMap.size,
    zhEntries: zhEntries.length,
    zhKeys: zhMap.size,
    fullAvailable: fs.existsSync(FULL_PATH),
  };
}

// ---------- 英→中 ----------
/** 精确查词（全小写形式） */
function lookupEn(word) {
  load();
  const w = String(word).toLowerCase().trim();
  if (!w) return null;
  if (enMap.has(w)) {
    const e = enMap.get(w);
    return { word: w, ph: e.ph, pos: e.pos, trans: e.trans, source: 'common' };
  }
  const f = lookupEnFull(w);
  if (f) return f;
  return null;
}

/** 完整 ECDICT 二分查找（懒加载）。全量条目格式: [word, trans] */
function lookupEnFull(word) {
  if (!fs.existsSync(FULL_PATH)) return null;
  if (!fullArray) {
    const t0 = Date.now();
    fullArray = JSON.parse(fs.readFileSync(FULL_PATH, 'utf8'));
    console.error(`[dict] 完整 ECDICT 懒加载: ${fullArray.length} 词, ${Date.now() - t0}ms`);
  }
  const w = String(word).toLowerCase().trim();
  let lo = 0, hi = fullArray.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const wm = fullArray[mid][0];
    if (wm === w) {
      const [word, trans] = fullArray[mid];
      return { word, ph: '', pos: '', trans, source: 'full' };
    }
    if (wm < w) lo = mid + 1;
    else hi = mid - 1;
  }
  return null;
}

/** Damerau-Levenshtein 编辑距离（相邻换位算 1 步，适合纠错） */
function damerau(a, b) {
  const m = a.length, n = b.length;
  if (Math.abs(m - n) > 3) return 99;
  const dp = [];
  for (let i = 0; i <= m; i++) { dp.push(new Array(n + 1).fill(0)); dp[i][0] = i; }
  for (let j = 0; j <= n; j++) dp[0][j] = j;
  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        dp[i][j] = Math.min(dp[i][j], dp[i - 2][j - 2] + 1);
      }
    }
  }
  return dp[m][n];
}

/** 前缀建议（补全输入时的联想词）：优先全量索引按字母序，再用常用词表补充，最后容错纠正 */
function suggestEn(prefix, n = 8) {
  load();
  const p = String(prefix).toLowerCase().trim();
  if (!p) return [];
  const out = [];
  const seen = new Set();
  // 1) 全量表（按词字母序）— 主来源，二分定位后顺序扫描
  if (fs.existsSync(FULL_PATH)) {
    if (!fullArray) {
      fullArray = JSON.parse(fs.readFileSync(FULL_PATH, 'utf8'));
    }
    let lo = 0, hi = fullArray.length - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (fullArray[mid][0] < p) lo = mid + 1;
      else hi = mid;
    }
    for (let i = lo; i < fullArray.length && out.length < n; i++) {
      const w = fullArray[i][0];
      if (w.startsWith(p)) {
        if (!seen.has(w)) { seen.add(w); out.push(w); }
      } else break;
    }
    // 2) 容错联想：前缀无命中时，对常用词表做编辑距离匹配。
    //    排序：距离近者优先；同距离内首字母匹配优先，再按字母序。
    if (out.length === 0) {
      const fuzzy = [];
      for (const w of enMap.keys()) {
        if (w.length < 3 || Math.abs(w.length - p.length) > 2) continue;
        const d = damerau(w, p);
        if (d <= 2) fuzzy.push([d, w, w[0] === p[0] ? 1 : 0]);
      }
      fuzzy.sort((a, b) => a[0] - b[0] || b[2] - a[2] || (a[1] < b[1] ? -1 : 1));
      for (const [, w] of fuzzy) {
        if (!seen.has(w)) { seen.add(w); out.push(w); }
        if (out.length >= n) break;
      }
    }
  }
  // 3) 常用词表补充（剩余名额）
  if (out.length < n) {
    for (const w of enMap.keys()) {
      if (w.startsWith(p) && !seen.has(w)) {
        seen.add(w); out.push(w);
        if (out.length >= n) break;
      }
    }
  }
  return out.slice(0, n);
}

// ---------- 中→英 ----------
/** 中文最长词条长度（用于贪心分词） */
function zhMaxLen() {
  load();
  let m = 0;
  for (const k of zhMap.keys()) if (k.length > m) m = k.length;
  return m;
}

/** 按 key（简/繁体）查中文词条 */
function lookupZh(key) {
  load();
  const k = String(key).trim();
  if (!k) return null;
  const idx = zhMap.get(k);
  if (idx === undefined) return null;
  const [simp, trad, pinyin, defs] = zhEntries[idx];
  return { simp, trad, pinyin, defs, source: 'cedict' };
}

/** 取某个 key 存在与否 */
function hasZh(key) {
  load();
  return zhMap.has(String(key).trim());
}

// ---------- 中文分词（Viterbi 动态规划，jieba 词频模型） ----------
const SEG_MAX_LEN = 12;

function loadSeg() {
  if (segMap) return;
  const t0 = Date.now();
  segMap = new Map();
  if (fs.existsSync(SEG_PATH)) {
    const arr = JSON.parse(fs.readFileSync(SEG_PATH, 'utf8'));
    for (const [w, s] of arr) {
      if (w === '') segUnknown = s;   // 首元素记录未知单字分数
      else segMap.set(w, s);
    }
  } else {
    segUnknown = -20;
  }
  console.error(`[dict] 分词词表载入: ${segMap.size} 词, ${Date.now() - t0}ms`);
}

/**
 * Viterbi 分词：最大化 Σ score(w)，其中 score 已含 -log(总词频) 项，
 * 因此"词数少、词频高"的切分天然占优。
 */
function segmentZh(text) {
  loadSeg();
  const s = String(text);
  const n = s.length;
  if (n === 0) return [];
  const dp = new Float64Array(n + 1).fill(-Infinity);
  const back = new Int32Array(n + 1).fill(-1);
  const backLen = new Int32Array(n + 1).fill(0);
  dp[0] = 0;
  for (let i = 0; i < n; i++) {
    if (dp[i] === -Infinity) continue;
    const maxLen = Math.min(SEG_MAX_LEN, n - i);
    // 长度降序：同分时优先更长词
    for (let len = maxLen; len >= 1; len--) {
      let sc;
      if (len === 1 && !segMap.has(s[i])) sc = segUnknown;
      else sc = segMap.get(s.slice(i, i + len));
      if (sc === undefined) continue;
      const cand = dp[i] + sc;
      if (cand > dp[i + len]) {
        dp[i + len] = cand;
        back[i + len] = i;
        backLen[i + len] = len;
      }
    }
  }
  const out = [];
  let p = n;
  while (p > 0) {
    const st = back[p];
    out.unshift(s.slice(st, st + backLen[p]));
    p = st;
  }
  return out;
}

module.exports = { load, stats, lookupEn, lookupEnFull, suggestEn, lookupZh, hasZh, zhMaxLen, segmentZh };
