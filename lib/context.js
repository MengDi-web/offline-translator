/**
 * context.js — 划词翻译核心逻辑（服务端）
 *
 * 职责：
 *   1. 自动补齐不完整划词（如 "appl" → "apple"，利用上下文文本扩展词边界）
 *   2. 提取划词周围 3-5 句上下文
 *   3. 判定词/句：句子走神经翻译；单词/短语走词典 + 上下文语境义项排序
 *
 * 由 server.js 挂载，nmtTranslate 为神经翻译回调。
 */
'use strict';

const dict = require('./dictionary');
const translate = require('./translate');

// 词字符：字母/数字/CJK/下划线/撇号/连字符（词内）
const WORD_CHAR = /[\p{L}\p{N}_'\-\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/u;

// ---------- 0. 文本清理（PDF 提取的字距杂质） ----------
function cleanText(s) {
  let t = String(s)
    .replace(/[\u200b\u200c\u200d\ufeff\u00ad]/g, '')                 // 零宽字符/软连字符
    .replace(/[\u00a0\u202f\u3000\u2000-\u200a\u205f]+/g, ' ')        // 特殊空格 → 普通空格
    .replace(/ +/g, ' ');                                                  // 多空格 → 单空格
  // CJK 之间空格：循环删除（"A B C" 连排需多轮）
  let prev;
  do {
    prev = t;
    t = t.replace(/([\u3400-\u4dbf\u4e00-\u9fff]) +([\u3400-\u4dbf\u4e00-\u9fff])/g, '$1$2');
  } while (t !== prev);
  return t;
}

// ---------- 0. PDF 断行归一化 ----------
function normalizeWrapped(s) {
  return String(s)
    .split(/\n\n+/)
    .map((p) =>
      p
        .split('\n')
        .map((line, i, arr) => {
          if (i === 0) return line;
          const prev = arr[i - 1];
          if (/[。！？!?；;”"…]$/.test(prev)) return '\n' + line;
          const prevCJK = /[\u3400-\u4dbf\u4e00-\u9fff]$/.test(prev);
          const curCJK = /^[\u3400-\u4dbf\u4e00-\u9fff]/.test(line);
          return (prevCJK && curCJK ? '' : ' ') + line;
        })
        .join('')
    )
    .join('\n\n');
}

// ---------- 1. 自动补齐 ----------
function completeSelection(selection, context) {
  const sel = String(selection || '').trim();
  const ctx = String(context || '');
  if (!sel) return { completed: sel, changed: false, located: false };

  const normCtx = ctx.replace(/\s+/g, ' ');
  const normSel = sel.replace(/\s+/g, ' ');

  let idx = normCtx.indexOf(normSel);
  let matched = normSel;
  if (idx < 0) {
    // 宽松匹配：去掉首尾标点再找
    const loose = normSel.replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, '');
    if (loose && loose.length >= 1) {
      idx = normCtx.indexOf(loose);
      if (idx >= 0) matched = loose;
    }
  }
  if (idx < 0) {
    // 上下文里找不到（比如浏览器未提供全文）→ 至少补齐 selection 自身末尾
    let start = sel.length;
    while (start > 0 && WORD_CHAR.test(sel[start - 1])) start--;
    const base = sel.slice(start);
    const noContext = !String(context || '').trim();
    return { completed: sel, changed: false, located: false, note: noContext ? null : '未能在上下文中定位划词' };
  }

  let start = idx;
  let end = idx + matched.length;
  while (start > 0 && WORD_CHAR.test(normCtx[start - 1])) start--;   // 左扩
  while (end < normCtx.length && WORD_CHAR.test(normCtx[end])) end++; // 右扩
  // CJK 无空格：仅当选中落在「单个 jieba 词」内部时才收敛到该词；
  // 若选中横跨多个词（短语/句子），保留完整跨度。
  const raw = normCtx.slice(start, end);
  if (/[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/.test(raw)) {
    const selStartAbs = idx;                       // 选中起点（绝对位置）
    const selEndAbs = idx + matched.length;        // 选中终点
    const toks = dict.segmentZh(raw);
    let acc = 0;
    let contained = null;                          // 包含选中起点的词
    let containedEnd = 0;
    for (const t of toks) {
      const tStartAbs = start + acc;
      const tEndAbs = tStartAbs + t.length;
      if (selStartAbs >= tStartAbs && selStartAbs < tEndAbs) {
        contained = t;
        containedEnd = tEndAbs;
      }
      acc += t.length;
    }
    if (contained && selEndAbs <= containedEnd) {
      // 整个选中落在同一个词内 → 补齐为该词
      start = containedEnd - contained.length;
      end = containedEnd;
    }
  }
  const completed = normCtx.slice(start, end).trim();

  return {
    completed,
    changed: completed !== normSel,
    located: true,
    start,
    end,
    normalized: normCtx,
  };
}

// ---------- 2. 上下文句子窗口（前后各 1-2 句，共 3-5 句） ----------
const SENT_BOUND = /[。！？；!?;\n]/;

function sentenceWindow(text, start, end, before = 2, after = 1) {
  const s = String(text || '');
  if (!s) return '';
  // 包含划词的句子起点
  let s0 = start;
  while (s0 > 0 && !SENT_BOUND.test(s[s0 - 1])) s0--;
  // 再往前取 before 句
  for (let k = 0; k < before; k++) {
    let i = s0 - 1;
    while (i > 0 && !SENT_BOUND.test(s[i])) i--;
    if (i <= 0) break;
    s0 = i;
  }
  // 包含划词的句子终点（含边界标点）
  let e1 = end;
  while (e1 < s.length && !SENT_BOUND.test(s[e1])) e1++;
  if (e1 < s.length) e1++;
  // 再往后取 after 句
  for (let k = 0; k < after; k++) {
    let i = e1;
    while (i < s.length && !SENT_BOUND.test(s[i])) i++;
    if (i >= s.length) break;
    e1 = Math.min(s.length, i + 1);
  }
  return s.slice(s0, e1).trim();
}

// ---------- 3. 义项按语境排序 ----------
/** 去掉 [医] 等方括号标注与词性前缀（仅用于计分，显示仍保留原文） */
function cleanSense(s) {
  return String(s)
    .replace(/\[[^\]]*\]/g, '')
    .replace(/^(v|n|a|adj|adv|prep|pron|conj|int|num|aux|art|vt|vi)\.\s*/i, '')
    .replace(/[，,、;；·\s]+/g, '')
    .trim();
}

/** 中文子串 n-gram 重叠度（比率归一化，消除"义项越长天然分越高"的偏差） */
function zhOverlap(sense, translated) {
  const t = String(translated || '');
  if (!t) return 0;
  const seen = new Set();
  for (let n = 1; n <= 2; n++) {
    for (let i = 0; i + n <= t.length; i++) seen.add(t.slice(i, i + n));
  }
  const cs = cleanSense(sense);
  if (!cs) return 0;
  let hits = 0, total = 0;
  for (let n = 1; n <= 2; n++) {
    for (let i = 0; i + n <= cs.length; i++) { total++; if (seen.has(cs.slice(i, i + n))) hits++; }
  }
  return total ? hits / total : 0;
}

/** 英文单词重叠度（比率归一化） */
function enOverlap(sense, translated) {
  const t = String(translated || '').toLowerCase();
  const words = new Set(t.split(/[^a-z']+/).filter(Boolean));
  const sw = new Set(['the', 'a', 'an', 'of', 'to', 'in', 'and', 'is', 'are', 'was', 'were', 'that', 'this', 'it', 'on', 'for', 'with', 'as', 'by', 'at', 'be', 'from']);
  const ws = String(sense).toLowerCase().split(/[^a-z']+/).filter(Boolean);
  if (!ws.length) return 0;
  let hits = 0;
  for (const w of ws) {
    if (words.has(w) && !sw.has(w)) hits++;
  }
  return hits / ws.length;
}

function rankSenses(senses, translated, dir) {
  const scored = senses.map((sense, index) => ({
    sense,
    index,
    score: dir === 'en2zh' ? zhOverlap(sense, translated) : enOverlap(sense, translated),
  }));
  scored.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score;
    // 平分时：无 [标注] 的义项优先（"苹果" 应排在 "[医] 苹果" 前），其次更简洁者
    const an = /\[[^\]]*\]/.test(a.sense) ? 1 : 0;
    const bn = /\[[^\]]*\]/.test(b.sense) ? 1 : 0;
    if (an !== bn) return an - bn;
    const la = cleanSense(a.sense).length, lb = cleanSense(b.sense).length;
    if (la !== lb) return la - lb;
    return a.index - b.index;
  });
  return scored;
}

// ---------- 4. 词/句判定 ----------
function isSentenceText(text, dir) {
  const s = String(text || '').trim();
  if (/[。！？!?；;]/.test(s)) return true;
  if (dir === 'zh2en') return (s.match(/[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/g) || []).length >= 6;
  return s.split(/\s+/).filter(Boolean).length >= 5;
}

// ---------- 主入口 ----------
/**
 * @param {object} payload
 * @param {string} payload.selection  划词原文
 * @param {string} payload.context    上下文全文（尽量多给）
 * @param {number} [payload.pos]      划词在 context 中的位置
 * @param {object} [payload.bounds]   屏幕坐标（原样返回给前端定位）
 * @param {function} nmtTranslate     (text, dir) => Promise<string> 神经翻译
 */
async function contextTranslate(payload, nmtTranslate) {
  const selection = cleanText(normalizeWrapped(String(payload.selection || '').trim()));  // PDF 断行合并 + 字距清理
  const context = cleanText(String(payload.context || ''));
  const bounds = payload.bounds || null;
  if (!selection) return { error: '划词为空' };
  // 通用垃圾识别（复制保护输出的单字符重复/符号串/低多样性文本）
  const GARBAGE = /[{}[\]|~^`\\<>=-]/g;
  const garbageRatio = (selection.match(GARBAGE) || []).length / Math.max(selection.length, 1);
  const repeatGarbage = /(.)\1{9,}/.test(selection);
  const lowDiversity = selection.length >= 16 && new Set(selection).size <= 2;
  if (garbageRatio > 0.3 || repeatGarbage || lowDiversity) {
    return { error: '复制内容疑似乱码（可能来自应用的复制保护），无法翻译' };
  }

  const completedInfo = completeSelection(selection, context);
  const completed = completedInfo.completed;
  const detected = translate.detectLang(completed);
  const dir = detected === 'zh' ? 'zh2en' : detected === 'en' ? 'en2zh' : 'auto';

  // 重新定位 completed 计算句子窗口
  let win = '';
  if (completedInfo.located) {
    win = sentenceWindow(completedInfo.normalized, completedInfo.start, completedInfo.end);
  } else if (context) {
    win = context.slice(0, 1500);
  }

  const kind = isSentenceText(completed, dir);
  const out = {
    original: selection,
    completed,
    changed: !!completedInfo.changed,
    located: !!completedInfo.located,
    kind: kind ? 'sentence' : 'word',
    dir,
    bounds,
    note: completedInfo.note || null,
  };

  // 词典义项（词/短语时）
  if (!kind) {
    if (dir === 'en2zh') {
      const r = translate.lookupEnResult(completed);
      if (r) out.dictSenses = r.translation;
    } else if (dir === 'zh2en') {
      const r = translate.lookupZhResult(completed);
      if (r) out.dictSenses = r.translation;
    }
  }

  // 神经翻译：句子 → 直接翻 selection；词 → 翻所在句（语境）；词典查不到的词 → 直接翻该词
  const nmtText = kind ? completed : (win || completed);
  if (nmtText && nmtTranslate && dir !== 'auto') {
    try {
      const t = await nmtTranslate(nmtText, dir);
      if (kind) out.translation = t;
      else if (win) out.contextTranslation = t;
      else if (!out.dictSenses) out.translation = t;   // 无词典无上下文 → 神经直译该词
    } catch (e) {
      out.nmtError = e.message;
    }
  }

  // 词：语境义项排序（拆分子义项，如 "银行, 堤, 岸" → 分别排序）
  if (!kind && out.dictSenses && out.contextTranslation) {
    const subs = [];
    for (const s of out.dictSenses) {
      for (const part of String(s).split(/[,，、;；]/)) {
        const p = part.replace(/^(v|n|a|adj|adv|prep|pron|conj|int|num|aux|art)\.\s*/i, '').trim();
        if (p && p.length >= 1) subs.push({ parent: s, sub: p });
      }
    }
    if (subs.length) {
      const ranked = rankSenses(subs.map((x) => x.sub), out.contextTranslation, dir);
      out.rankedSenses = ranked.map((r) => ({ ...r, parent: subs[r.index].parent })).slice(0, 5);
      out.bestSense = out.rankedSenses.length ? out.rankedSenses[0] : null;
    }
    out.contextSentences = win;
  } else if (win) {
    out.contextSentences = win;
  }

  return out;
}

module.exports = { contextTranslate, completeSelection, sentenceWindow, rankSenses };
