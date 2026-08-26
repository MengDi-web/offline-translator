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
function setSelectionMode(on) {
  try {
    fs.writeFileSync(MODE_FILE, JSON.stringify({ enabled: !!on }));
    return true;
  } catch { return false; }
}

// ---------- 神经翻译后端（常驻 Python 子进程，完全离线） ----------
// Python 路径：优先环境变量 NMT_PY；macOS 默认 /tmp 的 venv；Windows 默认 neural/.venv
function findNmtPython() {
  if (process.env.NMT_PY && fs.existsSync(process.env.NMT_PY)) return process.env.NMT_PY;
  const candidates = [
    '/tmp/offline-nmt-venv/bin/python',
    path.join(ROOT, 'neural', '.venv', 'Scripts', 'python.exe'),
    path.join(ROOT, 'neural', '.venv', 'bin', 'python'),
    path.join(ROOT, 'venv', 'Scripts', 'python.exe'),
  ];
  for (const c of candidates) if (fs.existsSync(c)) return c;
  return null;
}
const NMT_PY = findNmtPython();
let nmt = null;             // child process
let nmtReady = false;       // 后端是否就绪（模型已加载）
let nmtQueue = [];
let nmtId = 0;

function startNmt() {
  if (!NMT_PY || !fs.existsSync(NMT_PY) || !fs.existsSync(path.join(ROOT, 'neural', 'nmt_server.py'))) {
    console.log('[nmt] 后端不可用（缺少 venv 或脚本），仅使用词典引擎');
    return;
  }
  nmt = spawn(NMT_PY, [path.join(ROOT, 'neural', 'nmt_server.py')], {
    stdio: ['pipe', 'pipe', 'inherit'],
    env: { ...process.env, PYTHONUTF8: '1' },   // 强制 Python UTF-8，避免 locale 编码导致乱码
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
          const job = nmtQueue.shift();
          if (job) job.resolve(msg);
        } catch { /* 忽略坏行 */ }
      } else {
        console.log('[nmt]', line);
        if (line.includes('ready')) nmtReady = true;
      }
    }
  });
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
    nmtQueue.push({ id, resolve });
    nmt.stdin.write(JSON.stringify({ id, text, dir }) + '\n');
    setTimeout(() => {
      const i = nmtQueue.findIndex((j) => j.id === id);
      if (i >= 0) { nmtQueue.splice(i, 1); resolve({ error: 'nmt 超时' }); }
    }, timeoutMs);
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

      // 解析方向（词典引擎内部逻辑）
      const d = translate.detectLang(q);
      const effDir = dir !== 'auto' ? dir : (d === 'zh' ? 'zh2en' : d === 'en' ? 'en2zh' : 'auto');

      const dictResult = translate.translate(q, dir);

      // 模式决策：auto → 整句走神经、词/短语走词典；nmt → 全部走神经；dict → 全部走词典
      let useNmt = false;
      if (mode === 'nmt') useNmt = true;
      else if (mode === 'auto') useNmt = isSentence(q, effDir);
      else useNmt = false;

      if (useNmt && (effDir === 'zh2en' || effDir === 'en2zh')) {
        const nr = await nmtRequest(q, effDir);
        if (!nr.error) {
          const result = {
            engine: 'nmt', dir: effDir, detected: d, kind: 'sentence', input: q,
            translation: nr.text,
            dictRough: dictResult.rough || (dictResult.translation ? dictResult.translation[0] : ''),
            note: '神经翻译（本地模型）',
            ms: Date.now() - t0,
          };
          return sendJson(res, 200, result);
        }
        // 神经后端失败 → 降级词典
      }
      const result = dictResult;
      result.engine = 'dict';
      result.ms = Date.now() - t0;
      return sendJson(res, 200, result);
    }

    if (p === '/api/selection-mode') {
      if (req.method === 'POST') {
        const body = JSON.parse((await readBody(req)) || '{}');
        const ok = setSelectionMode(body.enabled === true);
        return sendJson(res, ok ? 200 : 500, { enabled: getSelectionMode() });
      }
      return sendJson(res, 200, { enabled: getSelectionMode() });
    }

    if (p === '/api/context-translate' && req.method === 'POST') {
      // 一键划词未开启 → 直接拒绝（划词功能不生效）
      if (!getSelectionMode()) {
        return sendJson(res, 200, { disabled: true, error: '划词功能未开启（请在网页上点击「开启一键划词」）' });
      }
      const body = JSON.parse((await readBody(req)) || '{}');
      const t0 = Date.now();
      const result = await context.contextTranslate(body, (text, dir) => nmtRequest(text, dir).then((r) => {
        if (r.error) throw new Error(r.error);
        return r.text;
      }));
      result.ms = Date.now() - t0;
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
