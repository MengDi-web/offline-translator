/**
 * translate.js — 离线中英互译引擎（词典级：单词/短语精确翻译 + 句子逐词直译）。
 * 完全本地运行，不发起任何网络请求。
 */
'use strict';

const dict = require('./dictionary');

// ---------- 语言检测 ----------
// 注意：CJK_RE 不带 /g 用于 .test()；计数必须用带 /g 的版本，
// 否则 match() 只返回第一个匹配，中文会被误判为英文（历史 bug 根因）
const CJK_RE = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/;
const CJK_RE_G = /[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/g;

function detectLang(text) {
  const s = String(text || '');
  const cjk = (s.match(CJK_RE_G) || []).length;
  const letters = (s.match(/[a-zA-Z]/g) || []).length;
  if (cjk === 0 && letters === 0) return 'unknown';
  // 1 个汉字 ≈ 5 个英文字母（约等于一个英文词）：中文为主的中英混合文本应判为 zh
  return cjk > letters / 5 ? 'zh' : 'en';
}

// ---------- 英文形态处理 ----------
const IRREGULAR = {
  is: 'be', are: 'be', am: 'be', was: 'be', were: 'be', been: 'be', being: 'be',
  has: 'have', had: 'have', having: 'have',
  does: 'do', did: 'do', done: 'do', doing: 'do',
  goes: 'go', went: 'go', gone: 'go', going: 'go',
  came: 'come', comes: 'come', coming: 'come',
  saw: 'see', seen: 'see', seeing: 'see',
  made: 'make', makes: 'make', making: 'make',
  took: 'take', takes: 'take', taken: 'take', taking: 'take',
  got: 'get', gets: 'get', gotten: 'get', getting: 'get',
  said: 'say', says: 'say', saying: 'say',
  told: 'tell', tells: 'tell', telling: 'tell',
  thought: 'think', thinks: 'think', thinking: 'think',
  knew: 'know', knows: 'know', known: 'know', knowing: 'know',
  gave: 'give', gives: 'give', given: 'give', giving: 'give',
  found: 'find', finds: 'find', finding: 'find',
  felt: 'feel', feels: 'feel', feeling: 'feel',
  left: 'leave', leaves: 'leave', leaving: 'leave',
  wrote: 'write', writes: 'write', written: 'write', writing: 'write',
  read: 'read', reads: 'read', reading: 'read',
  ran: 'run', runs: 'run', running: 'run',
  ate: 'eat', eats: 'eat', eaten: 'eat', eating: 'eat',
  slept: 'sleep', sleeps: 'sleep', sleeping: 'sleep',
  bought: 'buy', buys: 'buy', buying: 'buy',
  brought: 'bring', brings: 'bring', bringing: 'bring',
  taught: 'teach', teaches: 'teach', teaching: 'teach',
  began: 'begin', begins: 'begin', begun: 'begin', beginning: 'begin',
  better: 'good', best: 'good', worse: 'bad', worst: 'bad',
  more: 'many', most: 'many', less: 'little', least: 'little',
  ours: 'we', theirs: 'they', hers: 'she', his: 'he', its: 'it', yours: 'you',
  me: 'i', us: 'we', him: 'he', them: 'they', her: 'she',
};

/** 归一化英文：小写、去标点 */
function normEn(word) {
  return String(word).toLowerCase().replace(/[^a-z\u00c0-\u024f\s'-]/g, ' ').trim();
}

/** 词干还原（先查不规则表，再尝试去后缀） */
function stemEn(word) {
  const w = String(word).toLowerCase();
  if (IRREGULAR[w]) return IRREGULAR[w];
  if (w.length <= 4) return w;
  let stem = w;
  if (stem.endsWith('ies')) stem = stem.slice(0, -3) + 'y';
  else if (stem.endsWith('es')) stem = stem.slice(0, -2);
  else if (stem.endsWith('ed')) stem = stem.slice(0, -2);
  else if (stem.endsWith('ing')) stem = stem.slice(0, -3);
  else if (stem.endsWith('s') && !stem.endsWith('ss')) stem = stem.slice(0, -1);
  // 双写辅音还原: stopped→stop, running→run, planned→plan
  if (stem.length > 3 && /(.)\1$/.test(stem) && 'bcdfghjklmnpqrstvwxz'.includes(stem.slice(-1))) {
    stem = stem.slice(0, -1);
  }
  return stem.length >= 3 ? stem : w;
}

/** 取译文中第一个“干净”的义项（用于直译拼接） */
// 跳过明显不适合直译的义项类型：姓氏、旧称、量词、异体、缩写、台湾注音等
const SKIP_SENSE = /^(surname\b|old name\b|variant of\b|abbr\.?\s+of\b|cl[:：]|taiwan pr\.|tw pr\.)/i;

function firstSense(trans) {
  if (!trans) return '';
  // ECDICT 用 | 或换行分隔义项；CC-CEDICT 合并后用 " / " 分隔；同义项内用 ; 分隔
  const parts = String(trans).split(/[|\n]|\s\/\s/);
  const stripped = [];
  for (const raw of parts) {
    let p = (raw.split(';')[0] || '').trim();
    p = p.replace(/^(v|n|a|adj|adv|prep|pron|conj|int|num|aux|art)\.\s*/i, '').trim();
    if (p) stripped.push(p);
  }
  for (const p of stripped) {
    if (!SKIP_SENSE.test(p)) return p;
  }
  return stripped[0] || '';
}

/** 清理直译文本：拍平空白、去掉括号注记 */
function cleanRough(s) {
  return String(s).replace(/\([^)]*\)/g, '').replace(/\s+/g, ' ').trim();
}

// ---------- 英文分词（含短语贪心匹配） ----------
/** 单个英文词的完整查询：精确 → 词干还原 → 加 e / 去所有格 */
function lookupEnAny(word) {
  const n = normEn(word);
  if (!n) return null;
  let e = dict.lookupEn(n);
  if (e) return { entry: e, matched: null };
  const stem = stemEn(n);
  if (stem !== n) {
    e = dict.lookupEn(stem);
    if (e) return { entry: e, matched: stem };
  }
  if (!e && !stem.endsWith('e') && stem.length >= 3) {
    e = dict.lookupEn(stem + 'e');
    if (e) return { entry: e, matched: stem + 'e' };
  }
  if (!e && n.endsWith("'s")) {
    e = dict.lookupEn(n.replace(/'s$/, ''));
    if (e) return { entry: e, matched: n.replace(/'s$/, '') };
  }
  return null;
}

function enTokens(text) {
  const clean = normEn(text);
  const tokens = clean.split(/\s+/).filter(Boolean);
  // 贪心: 先试 2-3 词短语，再退到单词
  const out = [];
  let i = 0;
  while (i < tokens.length) {
    let matched = null;
    for (let len = Math.min(3, tokens.length - i); len >= 1; len--) {
      const phrase = tokens.slice(i, i + len).join(' ');
      const e = len > 1 ? dict.lookupEn(phrase) : lookupEnAny(phrase);
      if (e) { matched = { token: phrase, entry: e.entry || e, matched: e.matched || null, words: len }; break; }
    }
    if (matched) {
      out.push(matched);
      i += matched.words;
    } else {
      out.push({ token: tokens[i], entry: null });
      i++;
    }
  }
  return out;
}

// ---------- 中文分词（Viterbi 动态规划 + 词频模型） ----------
function zhTokens(text) {
  const s = String(text).trim();
  const out = [];
  // 按语段切分：中文段（分词）、字母数字段（整段）、其他（标点，丢弃）
  const runs = s.split(/([\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+|[a-zA-Z0-9]+)/).filter(Boolean);
  for (const run of runs) {
    if (CJK_RE.test(run)) {
      for (const w of dict.segmentZh(run)) {
        const e = dict.lookupZh(w);
        out.push({ token: w, entry: e });
      }
    } else if (/[a-zA-Z0-9]/.test(run)) {
      out.push({ token: run, entry: null });
    }
  }
  return out;
}

// ---------- 单条查询（单词/短语） ----------
function lookupEnResult(word) {
  const w = String(word).trim();
  if (!w) return null;
  const r = lookupEnAny(w);
  if (!r) return null;
  const e = r.entry;
  const senses = String(e.trans).split(/[|\n]/).map(s => s.trim()).filter(Boolean);
  return {
    word: w,
    matched: r.matched,
    phonetic: e.ph || '',
    pos: e.pos || '',
    translation: senses,
    source: e.source,
  };
}

function lookupZhResult(text) {
  const s = String(text).trim();
  if (!s) return null;
  // 整体精确（最长匹配）
  const e = dict.lookupZh(s);
  if (e) {
    return {
      simplified: e.simp,
      traditional: e.trad,
      pinyin: e.pinyin,
      translation: e.defs.split(' / ').filter(Boolean),
      source: e.source,
    };
  }
  return null;
}

// ---------- 主入口 ----------
/** 混合中英文：按语段切分，各自翻译 */
const MIXED_RE = /([\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+)|(\s+)|([^\s\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff][^\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]*)/g;

function translationTextOf(r) {
  return r.rough || (Array.isArray(r.translation) ? r.translation[0] : r.translation) || '';
}

/** 中英混合按方向翻译：目标语言原样保留，另一语言翻译成目标语言 */
function translateMixedDir(input, dir) {
  const out = [];
  MIXED_RE.lastIndex = 0;
  let m;
  while ((m = MIXED_RE.exec(input))) {
    if (m[1]) {                                   // 中文段
      if (dir === 'zh2en') out.push(translationTextOf(translate(m[1], 'zh2en')) || m[1]);
      else out.push(m[1]);                        // en2zh: 中文保留
    } else if (m[2]) {                            // 空白保留
      out.push(m[2]);
    } else {                                      // 英文/其它段
      const seg = m[3].trim();
      if (dir === 'zh2en') out.push(seg || m[3]); // 保留英文
      else out.push(seg ? (translationTextOf(translate(seg, 'en2zh')) || seg) : m[3]);
    }
  }
  const joined = out.join('');
  return { dir, detected: 'mixed', kind: 'mixed', input,
           translation: joined, rough: joined,
           note: dir === 'en2zh' ? '英译中，中文原样保留' : '中译英，英文原样保留' };
}

/** 自动检测混合文本：按主导语言翻译(少数语言译成多数语言, 输出单一语言更连贯) */
function translateMixedDominant(input) {
  // 主导语言判定：中文字符数 vs 英文单词数（更符合"哪部分是主干"的直觉）
  // 中文严格多于英文词数 → 中文主导(英译中,保留中文)；平局或英文多 → 英文主导(中译英,保留英文)
  const cjkCount = (String(input).match(/[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/g) || []).length;
  const latinWords = (String(input).match(/[a-zA-Z]+/g) || []).length;
  // 2×中文字数 >= 3×英文词数 → 中文主导；否则英文主导（英文"骨架"权重更高）
  return translateMixedDir(input, cjkCount * 2 >= latinWords * 3 ? 'en2zh' : 'zh2en');
}

/** 少数语言是否只是个别词(≤2英文词 或 ≤3汉字)：
 *  是 → 视为主语言句子，不做混合分段(让整句走神经) */
function isTrivialMixed(input) {
  const cjk = (String(input).match(/[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+/g) || []).join('');
  const latinWords = (String(input).match(/[a-zA-Z]+/g) || []).length;
  const cjkChars = cjk.length;
  const latinSmall = latinWords <= 2;
  const cjkSmall = cjkChars <= 3;
  // 引号内的外文(如 "I love you" / 'crush') → 视为整句的一部分, 不做混合分段
  const quoted = /["'"'“”‘’「」][^"'\u201c\u201d\u2018\u2019\u300c\u300d]*[a-zA-Z]/.test(String(input));
  return quoted || (latinSmall && !cjkSmall) || (cjkSmall && !latinSmall);
}

function translateMixed(input) {
  const segs = String(input).split(/([\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+)/).filter(Boolean);
  const parts = [];
  for (const seg of segs) {
    const d = detectLang(seg);
    if (d === 'zh') parts.push(translate(seg, 'zh2en'));
    else if (d === 'en') parts.push(translate(seg, 'en2zh'));
  }
  const rough = parts.map(p => p.rough || (p.translation ? p.translation[0] : '')).filter(Boolean).join(' ');
  return { dir: 'mixed', detected: 'mixed', kind: 'mixed', input, parts, rough };
}

function translate(text, forcedDir) {
  const input = String(text || '').trim();
  if (!input) return { error: '请输入要翻译的内容' };

  dict.load();
  const detected = detectLang(input);
  // 中英混合文本（未手动指定方向）→ 分段各自翻译
  CJK_RE.lastIndex = 0;
  const hasCjk = CJK_RE.test(input);
  const hasLatin = /[a-zA-Z]/.test(input);
  if (hasCjk && hasLatin) {
    // 强制方向：目标语言原样保留，另一语言翻译成目标语言
    if (forcedDir === 'en' || forcedDir === 'en2zh') return translateMixedDir(input, 'en2zh');
    if (forcedDir === 'zh' || forcedDir === 'zh2en') return translateMixedDir(input, 'zh2en');
    // auto / 未指定：
    if (isTrivialMixed(input)) {
      // 少数语言只是个别词(如引号里的英文单词) → 按主语言整句处理(走神经)
    } else {
      // 两段都成规模 → 主导语言法（少数语言译成多数语言）
      return translateMixedDominant(input);
    }
  }
  const dir = forcedDir && forcedDir !== 'auto'
    ? (forcedDir === 'en' ? 'en2zh' : forcedDir === 'zh' ? 'zh2en' : forcedDir)
    : (detected === 'en' ? 'en2zh' : detected === 'zh' ? 'zh2en' : 'unknown');
  if (dir === 'unknown') return { error: '无法识别的语言（请检查输入）', detected };

  if (dir === 'en2zh') {
    // 单词 / 短语？
    if (/^[a-zA-Z][a-zA-Z' -]*$/.test(input) && input.split(/\s+/).length <= 4) {
      const r = lookupEnResult(input);
      if (r) {
        return {
          dir, detected, kind: 'word',
          input,
          phonetic: r.phonetic, pos: r.pos,
          translation: r.translation,
          matched: r.matched,
        };
      }
      // 多词短语未收录 → 降级为逐词直译；单词未收录 → 给联想建议
      if (input.split(/\s+/).length === 1) {
        return { dir, detected, kind: 'unknown', input, suggestions: dict.suggestEn(input.split(/\s+/)[0], 8) };
      }
    }
    // 句子 → 逐词直译
    const tokens = enTokens(input);
    const gloss = tokens.map(t => {
      let trans = null, ph = '', pos = '', matched = null;
      if (t.entry) {
        trans = firstSense(t.entry.trans);
        ph = t.entry.ph;
        pos = t.entry.pos;
        matched = t.matched || null;
      }
      return { token: t.token, translation: trans, phonetic: ph, pos, matched, hit: !!t.entry };
    });
    const rough = cleanRough(gloss.map(g => g.translation || g.token).join(' '));
    return { dir, detected, kind: 'sentence', input, gloss, rough, note: '词典直译（逐词/短语），非神经网络整句翻译' };
  }

  // zh2en
  if (/^[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3001\u3002\uff0c\uff1f\uff01、，。？！·\s]+$/.test(input) && input.replace(/\s/g, '').length <= 12) {
    const r = lookupZhResult(input);
    if (r) {
      return {
        dir, detected, kind: 'word',
        input,
        simplified: r.simplified, traditional: r.traditional, pinyin: r.pinyin,
        translation: r.translation,
      };
    }
  }
  // 句子 → 分词直译
  const tokens = zhTokens(input);
  const gloss = tokens.map(t => {
    let trans = null, py = '';
    if (t.entry) {
      trans = firstSense(t.entry.defs);
      py = t.entry.pinyin;
    }
    return { token: t.token, translation: trans, pinyin: py, hit: !!t.entry };
  });
  const rough = cleanRough(gloss.map(g => g.translation || g.token).join(' '));
  return { dir, detected, kind: 'sentence', input, gloss, rough, note: '词典直译（逐词/短语），非神经网络整句翻译' };
}

module.exports = { translate, translateMixed, detectLang, lookupEnResult, lookupZhResult };
