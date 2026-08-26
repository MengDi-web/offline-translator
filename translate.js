#!/usr/bin/env node
/**
 * translate.js — 命令行离线翻译。
 *
 * 用法:
 *   node translate.js "hello world"
 *   node translate.js "今天天气很好" --dir zh2en
 *   echo "你好" | node translate.js
 *   node translate.js              # 进入交互模式
 */
'use strict';

const readline = require('readline');
const translate = require('./lib/translate');

function formatWord(r) {
  const lines = [];
  if (r.dir === 'en2zh') {
    const head = [r.input];
    if (r.matched) {
      head.push(`(原形: ${r.matched}${r.phonetic ? ` /${r.phonetic}/` : ''})`);
    } else if (r.phonetic) {
      head.push(`/${r.phonetic}/`);
    }
    if (r.pos) head.push(`[${r.pos}]`);
    lines.push(head.join(' '));
    lines.push('─'.repeat(40));
    lines.push(r.translation.join('  |  '));
  } else {
    const head = [r.input];
    if (r.pinyin) head.push(`[${r.pinyin}]`);
    if (r.traditional && r.traditional !== r.simplified) head.push(`(繁体: ${r.traditional})`);
    lines.push(head.join(' '));
    lines.push('─'.repeat(40));
    lines.push(r.translation.join('  |  '));
  }
  return lines.join('\n');
}

function formatSentence(r) {
  const lines = [];
  lines.push(`输入: ${r.input}`);
  lines.push('─'.repeat(40));
  lines.push(`直译: ${r.rough}`);
  lines.push('');
  for (const g of r.gloss) {
    const mark = g.hit ? '·' : '×';
    const detail = g.translation || '(未收录)';
    const extra = g.phonetic ? ` ${g.phonetic}` : g.pinyin ? ` ${g.pinyin}` : '';
    const stemNote = g.matched ? `(=${g.matched})` : '';
    lines.push(`  ${mark} ${g.token}${stemNote}${extra} → ${detail}`);
  }
  lines.push(`(${r.note})`);
  return lines.join('\n');
}

function run(input, forcedDir) {
  const r = translate.translate(input, forcedDir);
  if (r.error) {
    console.log(`错误: ${r.error}`);
    if (r.suggestions && r.suggestions.length) {
      console.log(`你是不是想查: ${r.suggestions.join(', ')}`);
    }
    return;
  }
  if (r.kind === 'mixed') {
    console.log(`输入: ${r.input}`);
    console.log('─'.repeat(40));
    console.log(`直译: ${r.rough}`);
    console.log('');
    for (const p of r.parts) {
      console.log(p.kind === 'sentence' ? formatSentence(p) : formatWord(p));
      console.log('');
    }
    return;
  }
  if (r.kind === 'unknown') {
    console.log(`未在词典中找到「${r.input}」`);
    if (r.suggestions && r.suggestions.length) {
      console.log(`你是不是想查: ${r.suggestions.join(', ')}`);
    }
    return;
  }
  console.log(r.kind === 'sentence' ? formatSentence(r) : formatWord(r));
}

// ---------- 参数 ----------
const args = process.argv.slice(2);
let forcedDir = 'auto';
const di = args.indexOf('--dir');
if (di >= 0 && args[di + 1]) forcedDir = args[di + 1];
const queryArgs = di >= 0
  ? args.filter((a, i) => i !== di && i !== di + 1)
  : args;

// 有命令行参数 → 直接翻译
if (queryArgs.length) {
  run(queryArgs.join(' '), forcedDir);
} else if (!process.stdin.isTTY) {
  // stdin 非 TTY → 管道输入
  let data = '';
  process.stdin.on('data', (c) => (data += c));
  process.stdin.on('end', () => {
    const q = data.trim();
    if (q) run(q, forcedDir);
  });
} else {
  // 交互模式
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  console.log('离线翻译器（输入内容回车翻译，Ctrl+C 退出，支持中英互译）');
  rl.setPrompt('> ');
  rl.prompt();
  rl.on('line', (line) => {
    if (line.trim()) {
      run(line.trim(), forcedDir);
      console.log('');
    }
    rl.prompt();
  });
}
