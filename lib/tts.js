/**
 * tts.js — 离线朗读（macOS 系统自带 `say`，无需联网）。
 * 非 macOS 环境优雅降级返回 false。
 */
'use strict';

const { execFile } = require('child_process');

// 优先使用的语音（macOS 内置）
const VOICES = {
  en: ['Albert', 'Samantha', 'Daniel'],
  zh: ['Eddy', 'Flo', 'Meijia', 'Ting-Ting'],
};

function isMac() {
  return process.platform === 'darwin';
}

function speak(text, lang, cb) {
  const list = VOICES[lang === 'zh' ? 'zh' : 'en'] || VOICES.en;
  if (!isMac()) return cb(new Error('当前系统不支持 say 命令'));
  const tryVoice = (i) => {
    if (i >= list.length) return cb(new Error('没有可用的语音'));
    execFile('say', ['-v', list[i], String(text)], { timeout: 30000 }, (err) => {
      if (err) tryVoice(i + 1);
      else cb(null);
    });
  };
  tryVoice(0);
}

function speakSync(text, lang) {
  return new Promise((resolve) => {
    speak(text, lang, (err) => resolve({ ok: !err, error: err ? err.message : null }));
  });
}

module.exports = { speak, speakSync, isMac };
