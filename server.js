#!/usr/bin/env node
/**
 * server.js — miaomiao翻译器（零依赖 HTTP 服务）。
 *
 * 启动:  node server.js [--port 6688]
 * 访问:  http://127.0.0.1:6688
 *
 * 路由:
 *   GET  /               网页界面
 *   GET  /api/translate?q=..&dir=auto|en2zh|zh2en
 *   GET  /api/suggest?q=..
 *   GET  /api/stats      词典加载情况
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { URL } = require('url');
const { spawn } = require('child_process');

const translate = require('./lib/translate');
const dict = require('./lib/dictionary');
const context = require('./lib/context');

const ROOT = __dirname;
const PUBLIC = path.join(ROOT, 'public');
const MODE_FILE = path.join(ROOT, 'data', 'selection-mode.json');

// ---------- 一键划词总开关 ----------
function getSelectionMode() {
  try {
    if (fs.existsSync(MODE_FILE)) {
      return JSON.parse(fs.readFileSync(MODE_FILE, 'utf8')).enabled === true;
    }
  } catch {}
  return false;   // 默认关闭，需在网页点「开启一键划词」
}
// ---------- 页面 UI 主题(供划词弹窗跟随) ----------
const UI_THEME_FILE = path.join(ROOT, 'data', 'ui-theme.json');
const UI_THEMES = ['apple', 'green-apple', 'banana', 'soda', 'guava'];
// 每套主题对应的弹窗配色(取自 public/index.html 的 CSS 变量)
const THEME_PALETTES = {
  apple:         { bgColor: '#FFFDF7', origColor: '#1D1D1F', transColor: '#1D1D1F', copyColor: '#FF3B30', closeColor: '#F0EAE0', borderColor: '#E8DFCF' },
  'green-apple': { bgColor: '#FBFDF2', origColor: '#20290F', transColor: '#20290F', copyColor: '#96D35F', closeColor: '#E2E9C2', borderColor: '#E2E9C2' },
  banana:        { bgColor: '#FFFDF4', origColor: '#3A2F0C', transColor: '#3A2F0C', copyColor: '#E8AD00', closeColor: '#F0E0A8', borderColor: '#F0E0A8' },
  soda:          { bgColor: '#F4FAFC', origColor: '#0E2F3A', transColor: '#0E2F3A', copyColor: '#74A7FE', closeColor: '#D3E2F5', borderColor: '#D3E2F5' },
  guava:         { bgColor: '#FFFAFC', origColor: '#3B1F28', transColor: '#3B1F28', copyColor: '#7CB342', closeColor: '#F7D6E0', borderColor: '#F3D9E2' },
};

function getUiTheme() {
  try {
    if (fs.existsSync(UI_THEME_FILE)) {
      const t = JSON.parse(fs.readFileSync(UI_THEME_FILE, 'utf8').replace(/^\uFEFF/, '')).theme;
      if (UI_THEMES.includes(t)) return t;
    }
  } catch {}
  return 'apple';
}
function setUiTheme(t) {
  if (!UI_THEMES.includes(t)) return false;
  try {
    fs.mkdirSync(path.dirname(UI_THEME_FILE), { recursive: true });
    fs.writeFileSync(UI_THEME_FILE, JSON.stringify({ theme: t }));
    return true;
  } catch { return false; }
}

// ---------- 划词弹窗配置(与 windows/xuanci_helper.ps1 的 DEFAULTS 保持一致) ----------
// Windows 划词助手读 windows/xuanci_config.json;
// macOS 不写 app 包内部(会破坏代码签名), 改写到用户目录(该配置在 Mac 上不参与渲染)
const XUANCI_FILE = process.platform === 'win32'
  ? path.join(ROOT, 'windows', 'xuanci_config.json')
  : path.join(os.homedir(), 'Library', 'Application Support', 'miaomiao-translator', 'xuanci_config.json');
const XUANCI_DEFAULTS = {
  version: 3,
  followTheme: true,
  width: 350,
  origFontSize: 14,
  transFontSize: 15,
  opacity: 0.98,
  radius: 16,
  bgColor: '#FFFDF7',
  copyColor: '#FF3B30',
  closeColor: '#F0EAE0',
  origColor: '#1D1D1F',
  transColor: '#1D1D1F',
};
const HEX_RE = /^#[0-9a-fA-F]{6}$/;

function readXuanciConfig() {
  try {
    if (fs.existsSync(XUANCI_FILE)) {
      const saved = JSON.parse(fs.readFileSync(XUANCI_FILE, 'utf8').replace(/^\uFEFF/, ''));
      if (saved && saved.version === 3) {
        const out = Object.assign({}, XUANCI_DEFAULTS);
        for (const k of Object.keys(XUANCI_DEFAULTS)) {
          if (saved[k] !== undefined && saved[k] !== null) out[k] = saved[k];
        }
        return out;
      }
    }
  } catch {}
  return Object.assign({}, XUANCI_DEFAULTS);
}

function writeXuanciConfig(raw) {
  try {
    const out = Object.assign({}, readXuanciConfig());
    const num = (v, min, max, dflt) => {
      const n = Number(v);
      if (!isFinite(n)) return dflt;
      return Math.min(max, Math.max(min, n));
    };
    out.width = Math.round(num(raw.width, 260, 560, out.width));
    out.origFontSize = Math.round(num(raw.origFontSize, 10, 24, out.origFontSize));
    out.transFontSize = Math.round(num(raw.transFontSize, 10, 24, out.transFontSize));
    out.opacity = num(raw.opacity, 0.3, 1, out.opacity);
    out.radius = Math.round(num(raw.radius, 0, 28, out.radius));
    for (const k of ['bgColor', 'copyColor', 'closeColor', 'origColor', 'transColor']) {
      if (typeof raw[k] === 'string' && HEX_RE.test(raw[k])) out[k] = raw[k].toUpperCase();
    }
    out.followTheme = raw.followTheme !== false;   // 默认跟随页面主题
    out.version = 3;
    fs.mkdirSync(path.dirname(XUANCI_FILE), { recursive: true });
    fs.writeFileSync(XUANCI_FILE, JSON.stringify(out, null, 2));
    return true;
  } catch { return false; }
}

function setSelectionMode(on) {
  try {
    fs.writeFileSync(MODE_FILE, JSON.stringify({ enabled: !!on }));
    return true;
  } catch { return false; }
}

// ---------- 神经翻译后端（常驻 Python 子进程，完全离线） ----------
// Python 路径：优先环境变量 NMT_PY；macOS 默认 /tmp 的 venv（重启会被清空，
// 故兜底用 app 内置便携 Python）；Windows 默认 neural/.venv
function findNmtPython() {
  if (process.env.NMT_PY && fs.existsSync(process.env.NMT_PY)) return process.env.NMT_PY;
  const bundled = path.join(ROOT, 'dist', 'miaomiao翻译器.app', 'Contents', 'Resources', 'python', 'bin', 'python3.12');
  const candidates = [
    '/tmp/offline-nmt-venv/bin/python',
    bundled,
    path.join(ROOT, 'neural', '.venv', 'Scripts', 'python.exe'),
    path.join(ROOT, 'neural', '.venv', 'bin', 'python'),
    path.join(ROOT, 'venv', 'Scripts', 'python.exe'),
  ];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return null;
}
const NMT_PY = findNmtPython();
/** 便携 Python 对应的依赖库目录（PYTHONPATH 用） */
function bundledPythonLibs() {
  const libs = path.join(ROOT, 'dist', 'miaomiao翻译器.app', 'Contents', 'Resources', 'python-libs');
  return fs.existsSync(libs) ? libs : null;
}
let nmt = null;             // child process
let nmtReady = false;       // 后端是否就绪（模型已加载）
let nmtQueue = [];
let nmtId = 0;

function startNmt() {
  if (!NMT_PY || !fs.existsSync(NMT_PY) || !fs.existsSync(path.join(ROOT, 'neural', 'nmt_server.py'))) {
    console.log('[nmt] 后端不可用（缺少 venv 或脚本），仅使用词典引擎');
    return;
  }
  const env = { ...process.env, PYTHONUTF8: '1' };   // 强制 Python UTF-8，避免 locale 编码导致乱码
  // 使用 app 内置便携 Python 时，补上其依赖库目录（torch/transformers）
  const libs = bundledPythonLibs();
  if (libs && !(process.env.PYTHONPATH || '').includes(libs)) {
    env.PYTHONPATH = libs + (process.env.PYTHONPATH ? ':' + process.env.PYTHONPATH : '');
  }
  nmt = spawn(NMT_PY, [path.join(ROOT, 'neural', 'nmt_server.py')], {
    stdio: ['pipe', 'pipe', 'inherit'],
    env,
  });
  // 必须按完整行解码：累积 Buffer，找到换行符再整体转 UTF-8（避免多字节字符被分块截断）
  let buf = Buffer.alloc(0);
  nmt.stdout.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    let nl;
    while ((nl = buf.indexOf(0x0a)) >= 0) {
      const line = buf.slice(0, nl).toString('utf8').trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      if (line.startsWith('{')) {
        try {
          const msg = JSON.parse(line);
          // 按 msg.id 精确匹配队列项（超时被移除后迟到的响应不得错配给其他请求）
          if (msg && typeof msg.id === 'number') {
            const i = nmtQueue.findIndex((j) => j.id === msg.id);
            if (i >= 0) {
              const job = nmtQueue.splice(i, 1)[0];
              job.resolve(msg);
            } else {
              console.log(`[nmt] 丢弃迟到响应 id=${msg.id}（请求已超时）`);
            }
          }
        } catch { /* 忽略坏行 */ }
      } else {
        console.log('[nmt]', line);
        if (line.includes('ready')) nmtReady = true;
      }
    }
  });
  // 子进程 error(无法执行/被杀毒拦截/路径过长): 不处理会导致 Node 未捕获异常退出
  nmt.on('error', (err) => {
    console.log(`[nmt] 子进程启动失败: ${err.message}，神经翻译将不可用（词典照常）`);
    nmtReady = false;
    nmtQueue.forEach((j) => j.resolve({ error: 'nmt backend error' }));
    nmtQueue = [];
    nmt = null;
  });
  // Python 突然退出时写 stdin 会异步 EPIPE → 不监听会崩
  if (nmt.stdin) nmt.stdin.on('error', () => { /* exit/error 回调里已统一降级 */ });
  nmt.on('exit', (code) => {
    console.log(`[nmt] 子进程退出 code=${code}，神经翻译将不可用`);
    nmtReady = false;
    nmtQueue.forEach((j) => j.resolve({ error: 'nmt backend exited' }));
    nmtQueue = [];
    nmt = null;
  });
}

function nmtRequest(text, dir, timeoutMs = 60000) {
  if (!nmt || !nmtReady) return Promise.resolve({ error: 'nmt 未就绪' });
  const id = ++nmtId;
  return new Promise((resolve) => {
    const job = { id, resolve };
    nmtQueue.push(job);
    try {
      nmt.stdin.write(JSON.stringify({ id, text, dir }) + '\n');
    } catch {
      // Python 子进程刚退出、exit 回调尚未置空 nmt 的间隙：同步写入会抛异常 → 优雅降级
      const i = nmtQueue.indexOf(job);
      if (i >= 0) nmtQueue.splice(i, 1);
      resolve({ error: 'nmt 后端不可用' });
      return;
    }
    setTimeout(() => {
      const i = nmtQueue.findIndex((j) => j.id === id);
      if (i >= 0) { nmtQueue.splice(i, 1); resolve({ error: 'nmt 超时' }); }
    }, timeoutMs);
  });
}

/** 神经输出清洗：截断退化循环（同一字符连续重复 8+ 次）。
 *  Marian 模型对代码/符号密集输入会陷入循环输出（如连续反斜杠），在此截断。 */
function sanitizeNmtOutput(text) {
  if (!text) return '';
  let s = String(text);
  const m = s.match(/(.)\1{7,}/);
  if (m) s = s.slice(0, m.index).trim();
  // 整段为同一短单元重复（如单词翻译 "苹果苹果"、"好好好好"）→ 折叠为一份。
  // 重复单元要求 ≥2 字符，避免误伤 "哈哈"（haha）这类合法双字词。
  const rep = s.match(/^(.{2,12})\1+$/);
  if (rep) s = rep[1];
  return s.trim();
}

/** 代码/标记片段占位保护：翻译前把反引号代码、URL、<...> 换成 CODE0/CODE1…
 *  翻译后再还原，避免模型对符号密集片段输出退化乱码。 */
/** 长文本按句切块(默认 80 字符/块): 模型对长段落的输出会提前停止(实测 ~4 句),
 *  导致结尾(或开头)整句丢失。切块后逐块翻译再拼接。 */
function splitForNmt(text, maxChars = 50) {
  const s = String(text || '').trim();
  if (!s) return [s];
  if (s.length <= maxChars) return [s];
  const parts = s.split(/(?<=[。！？!?；;\n])|(?<=[.!?]\s)/).filter((x) => x && x.trim());
  const chunks = [];
  let cur = '';
  for (const p of parts) {
    if (cur && (cur + p).length > maxChars) { chunks.push(cur); cur = ''; }
    cur += p;
    while (cur.length > maxChars * 2) {   // 单句超长 → 硬切
      chunks.push(cur.slice(0, maxChars));
      cur = cur.slice(maxChars);
    }
  }
  if (cur.trim()) chunks.push(cur);
  return chunks.length ? chunks : [s];
}

function safeNmtTranslate(text, dir) {
  const chunks = splitForNmt(text);
  if (chunks.length > 1) {
    // 逐块翻译后拼接(串行, 避免同时压满 CPU)
    return chunks.reduce((accP, chunk) => accP.then(async (acc) => {
      if (acc.error) return acc;
      const r = await safeNmtTranslateOne(chunk, dir);
      if (r.error) return r;
      return { text: acc.text ? (acc.text + ' ' + r.text) : r.text };
    }), Promise.resolve({ text: '' }));
  }
  return safeNmtTranslateOne(text, dir);
}

function safeNmtTranslateOne(text, dir) {
  const segs = [];
  const protectedText = String(text).replace(/`[^`]*`|https?:\/\/\S+|<\S+>/g, (m) => {
    segs.push(m);
    return 'CODE' + (segs.length - 1);
  });
  return nmtRequest(protectedText, dir).then((r) => {
    if (r.error) return r;
    let out = sanitizeNmtOutput(r.text);
    if (segs.length) {
      out = out.replace(/CODE(\d+)/g, (_, i) => (segs[+i] !== undefined ? segs[+i] : ''));
    }
    return { text: out };
  });
}

/** 判断是否为整句（应走神经翻译） */
function isSentence(input, dir) {
  const s = String(input).trim();
  if (/[。！？!?；;]/.test(s)) return true;
  if (dir === 'zh2en') {
    const cjk = (s.match(/[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/g) || []).length;
    return cjk >= 5;
  }
  const words = s.split(/\s+/).filter(Boolean).length;
  return words >= 4;
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
};

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve) => {
    // 必须累积 Buffer 后一次性按 UTF-8 解码：
    // 若逐个 chunk 转字符串，多字节字符被分块切断会产生乱码
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      chunks.push(c);
      size += c.length;
      if (size > 10e6) req.destroy();
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', () => resolve(''));
  });
}

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  const p = u.pathname;

  try {
    // API
    if (p === '/api/translate') {
      const q = (u.searchParams.get('q') || '').trim();
      const dir = u.searchParams.get('dir') || 'auto';
      const mode = u.searchParams.get('mode') || 'auto';
      if (!q) return sendJson(res, 400, { error: '缺少参数 q' });
      const t0 = Date.now();
      let degraded = false;
      let resultNote = '';

      // 解析方向（词典引擎内部逻辑）
      const d = translate.detectLang(q);
      const effDir = dir !== 'auto' ? dir : (d === 'zh' ? 'zh2en' : d === 'en' ? 'en2zh' : 'auto');

      const dictResult = translate.translate(q, dir);

      // 模式决策：单个词 / 词典收录的固定搭配 → 词典；其余全部走神经
      // （kind: word=词典整串命中, unknown=未收录单词(给联想), mixed=中英混合, error=无法识别）
      let useNmt = false;
      if (mode === 'nmt') useNmt = true;
      else if (mode === 'auto') {
        const k = dictResult.kind;
        const dictEligible = k === 'word' || k === 'unknown' || k === 'mixed' || !k || dictResult.error;
        useNmt = !dictEligible;
      }
      // 其它为 dict → 保持 false

      if (useNmt && (effDir === 'zh2en' || effDir === 'en2zh')) {
        const nr = await safeNmtTranslate(q, effDir);
        if (!nr.error && (nr.text || '').length >= 2) {
          const result = {
            engine: 'nmt', dir: effDir, detected: d, kind: 'sentence', input: q,
            translation: nr.text,
            dictRough: dictResult.rough || (dictResult.translation ? dictResult.translation[0] : ''),
            note: '神经翻译（本地模型）',
            ms: Date.now() - t0,
          };
          return sendJson(res, 200, result);
        }
        // 神经后端失败，或模型输出异常（退化乱码、为空）→ 降级词典并说明
        if (nr.error) resultNote = '神经后端暂不可用，已降级词典直译';
        else resultNote = '含代码/特殊符号，模型输出异常，已回退词典直译';
        degraded = true;
      }
      const result = dictResult;
      result.engine = 'dict';
      result.note = degraded ? resultNote : (result.note || undefined);
      result.ms = Date.now() - t0;
      // 带上页面当前主题与对应弹窗配色, 让划词弹窗跟随页面主题
      const theme = getUiTheme();
      result.uiTheme = theme;
      result.themePalette = THEME_PALETTES[theme];
      return sendJson(res, 200, result);
    }

    if (p === '/api/selection-mode') {
      if (req.method === 'POST') {
        // 仅放行本机来源（127.0.0.1 / localhost 均可，兼容用户用 localhost 打开网页）
        const origin = req.headers.origin || '';
        if (origin && !/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/i.test(origin)) {
          return sendJson(res, 403, { error: '跨源请求被拒绝' });
        }
        const body = JSON.parse((await readBody(req)) || '{}');
        const ok = setSelectionMode(body.enabled === true);
        return sendJson(res, ok ? 200 : 500, { enabled: getSelectionMode() });
      }
      return sendJson(res, 200, { enabled: getSelectionMode() });
    }

    // ---------- 页面主题（划词弹窗跟随） ----------
    if (p === '/api/ui-theme') {
      if (req.method === 'POST') {
        const origin = req.headers.origin || '';
        if (origin && !/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/i.test(origin)) {
          return sendJson(res, 403, { error: '跨源请求被拒绝' });
        }
        const body = JSON.parse((await readBody(req)) || '{}');
        const ok = setUiTheme(String(body.theme || ''));
        return sendJson(res, ok ? 200 : 400, ok ? { theme: getUiTheme() } : { error: '无效主题' });
      }
      return sendJson(res, 200, { theme: getUiTheme(), palette: THEME_PALETTES[getUiTheme()] });
    }

    // ---------- 划词弹窗配置（网页版设置页读写 windows/xuanci_config.json） ----------
    if (p === '/api/xuanci-config') {
      if (req.method === 'POST') {
        const origin = req.headers.origin || '';
        if (origin && !/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/i.test(origin)) {
          return sendJson(res, 403, { error: '跨源请求被拒绝' });
        }
        const body = JSON.parse((await readBody(req)) || '{}');
        const ok = writeXuanciConfig(body && body.config ? body.config : body);
        return sendJson(res, ok ? 200 : 500, ok ? { ok: true, config: readXuanciConfig() } : { error: '保存失败（检查目录权限）' });
      }
      return sendJson(res, 200, { config: readXuanciConfig() });
    }

    if (p === '/api/context-translate' && req.method === 'POST') {
      // 一键划词未开启 → 直接拒绝（划词功能不生效）
      if (!getSelectionMode()) {
        return sendJson(res, 200, { disabled: true, error: '划词功能未开启（请在网页上点击「开启一键划词」）' });
      }
      // 同源校验：仅放行本机来源（与 /api/selection-mode 一致）
      const cOrigin = req.headers.origin || '';
      if (cOrigin && !/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/i.test(cOrigin)) {
        return sendJson(res, 403, { error: '跨源请求被拒绝' });
      }
      const body = JSON.parse((await readBody(req)) || '{}');
      const t0 = Date.now();
      const result = await context.contextTranslate(body, (text, dir) => safeNmtTranslate(text, dir).then((r) => {
        if (r.error) throw new Error(r.error);
        return r.text;
      }));
      result.ms = Date.now() - t0;
      // 带上页面当前主题与对应的弹窗配色(划词弹窗跟随页面主题)
      const uiTheme = getUiTheme();
      result.uiTheme = uiTheme;
      result.themePalette = THEME_PALETTES[uiTheme];
      return sendJson(res, 200, result);
    }

    if (p === '/api/suggest') {
      const q = (u.searchParams.get('q') || '').trim();
      if (!q) return sendJson(res, 200, { suggestions: [] });
      return sendJson(res, 200, { suggestions: dict.suggestEn(q, 8) });
    }

    if (p === '/api/stats') {
      const s = dict.stats();
      s.nmt = { available: !!nmt, ready: nmtReady };
      return sendJson(res, 200, s);
    }

    // 静态文件
    let file = path.normalize(p === '/' ? '/index.html' : p);
    const full = path.join(PUBLIC, file);
    if (!full.startsWith(PUBLIC) || !fs.existsSync(full) || fs.statSync(full).isDirectory()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end('404 Not Found');
    }
    const ext = path.extname(full);
    res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
    fs.createReadStream(full).pipe(res);
  } catch (e) {
    sendJson(res, 500, { error: e.message });
  }
});

// ---------- 启动 ----------
const args = process.argv.slice(2);
let port = 6688;
const pi = args.indexOf('--port');
if (pi >= 0 && args[pi + 1]) port = parseInt(args[pi + 1], 10);
if (process.env.PORT) port = parseInt(process.env.PORT, 10);

dict.load();
startNmt();

// 端口被占用（服务已在运行 / 双击两次启动器）→ 友好提示并正常退出，不抛崩溃堆栈
server.on('error', (e) => {
  if (e && e.code === 'EADDRINUSE') {
    console.log('');
    console.log('  miaomiao翻译器：服务已在运行');
    console.log(`  请直接打开 http://127.0.0.1:${port} 使用（或先关闭旧进程再启动）`);
    console.log('');
    process.exit(0);
  }
  console.error('  [启动失败]', e.message);
  process.exit(1);
});

server.listen(port, '127.0.0.1', () => {
  console.log('');
  console.log('  ┌──────────────────────────────────────────────┐');
  console.log('  │  miaomiao翻译器  (中英互译 · 完全离线)        │');
  console.log(`  │  http://127.0.0.1:${port}                       │`);
  console.log('  │  词典 + 神经翻译双引擎                        │');
  console.log('  │  按 Ctrl+C 停止                                │');
  console.log('  └──────────────────────────────────────────────┘');
  console.log('');
});
