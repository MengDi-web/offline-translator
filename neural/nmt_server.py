#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
nmt_server.py — 常驻神经翻译后端（stdin/stdout JSON 协议）

Node server.js 启动本进程，通过行式 JSON 通信：
  -> {"id":1,"text":"中文句子","dir":"zh2en"}
  <- {"id":1,"text":"English sentence"}

完全离线；模型缓存在内存中，多次请求不重复加载。
模型目录（均为独立 fp16 模型，含微调权重）：
  zh2en -> neural/models/opus-mt-zh-en-ft
  en2zh -> neural/models/opus-mt-en-zh-ft (或回退预训练)
"""
import json, os, sys, torch

ROOT = os.environ.get('MIAOMIAO_ROOT') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
MODELS = {
    'zh2en': os.path.join(ROOT, 'neural', 'models', 'opus-mt-zh-en-ft'),
    'en2zh': os.path.join(ROOT, 'neural', 'models', 'opus-mt-en-zh-ft'),
}
# 回退：en2zh 暂无微调版时用 /tmp 预训练
FALLBACK = {
    'en2zh': '/tmp/nmt-models/opus-mt-en-zh',
}

device = 'mps' if torch.backends.mps.is_available() else 'cpu'
_loaded = {}

def _ascii_safe_dir(model_dir):
    """Windows 下 sentencepiece 的 C++ 加载器不认中文路径（Illegal byte sequence）。
    若模型目录含非 ASCII 字符，则把模型文件复制/硬链接到临时纯英文目录再加载。"""
    if not model_dir or all(ord(c) < 128 for c in str(model_dir)):
        return model_dir
    import tempfile, shutil, hashlib
    tag = hashlib.md5(str(model_dir).encode('utf-8')).hexdigest()[:10]
    dst = os.path.join(tempfile.gettempdir(), 'miaomiao-model-' + tag)
    need = ['config.json', 'pytorch_model.bin', 'source.spm', 'target.spm', 'vocab.json', 'generation_config.json']
    if not all(os.path.exists(os.path.join(dst, f)) for f in need if os.path.exists(os.path.join(model_dir, f))):
        os.makedirs(dst, exist_ok=True)
        for f in os.listdir(model_dir):
            src = os.path.join(model_dir, f)
            if not os.path.isfile(src):
                continue
            tgt = os.path.join(dst, f)
            if os.path.exists(tgt):
                continue
            try:
                os.link(src, tgt)          # 硬链接(同盘, 不占额外空间)
            except Exception:
                shutil.copy2(src, tgt)     # 跨盘/无权限 → 复制
        print(f'[路径含中文] 模型已映射到纯英文目录: {dst}', flush=True)
    return dst


def get_model(direction):
    if direction in _loaded:
        return _loaded[direction]
    from transformers import MarianMTModel, MarianTokenizer
    model_dir = MODELS.get(direction)
    if not (model_dir and os.path.exists(os.path.join(model_dir, 'pytorch_model.bin'))):
        model_dir = FALLBACK.get(direction)
        print(f'[{direction}] 使用预训练回退: {model_dir}', flush=True)
    model_dir = _ascii_safe_dir(model_dir)
    model = MarianMTModel.from_pretrained(model_dir).to(device)
    tok = MarianTokenizer.from_pretrained(model_dir)
    model.eval()
    _loaded[direction] = (model, tok)
    print(f'[{direction}] 模型就绪: {model_dir}', flush=True)
    return _loaded[direction]

def translate(direction, text, num_beams=4):
    model, tok = get_model(direction)
    with torch.no_grad():
        enc = tok(text, return_tensors='pt', truncation=True, max_length=256).to(device)
        out = model.generate(**enc, max_new_tokens=256, num_beams=num_beams)
        return tok.decode(out[0], skip_special_tokens=True)

def main():
    # 锁定 UTF-8 编码（避免 locale 影响导致中英文字符乱码）
    if hasattr(sys.stdin, 'reconfigure'):
        sys.stdin.reconfigure(encoding='utf-8')
        sys.stdout.reconfigure(encoding='utf-8')
    print('NMT server ready, device=' + device, flush=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            text = req.get('text', '')
            direction = req.get('dir', 'zh2en')
            if not text:
                resp = {'id': req.get('id'), 'error': 'empty'}
            else:
                resp = {'id': req.get('id'), 'text': translate(direction, text)}
        except Exception as e:
            import traceback
            traceback.print_exc()
            resp = {'id': req.get('id'), 'error': str(e)}
        sys.stdout.write(json.dumps(resp, ensure_ascii=False) + '\n')
        sys.stdout.flush()

if __name__ == '__main__':
    main()
