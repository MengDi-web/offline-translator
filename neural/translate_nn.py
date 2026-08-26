#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
translate_nn.py — 神经模型命令行翻译（中英双向）

用法:
  python translate_nn.py "我不明白你为什么这么说"
  echo "hello world" | python translate_nn.py
  python translate_nn.py                 # 交互模式
"""
import os, sys, torch
from train import NMT, SP, PAD, BOS, EOS, VOCAB, DEVICE, encode

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

def load_model():
    ck_path = os.path.join(ROOT, 'neural', 'checkpoints', 'best.pt')
    if not os.path.exists(ck_path):
        print('未找到模型', ck_path); sys.exit(1)
    ck = torch.load(ck_path, map_location=DEVICE)
    model = NMT(VOCAB, 256, 3, 4, 1024, 0.1).to(DEVICE)
    sd = ck['model']
    if next(iter(sd.values())).dtype == torch.float16:
        sd = {k: v.float() for k, v in sd.items()}
    model.load_state_dict(sd)
    model.eval()
    return model

def translate(model, text):
    toks = encode(text.strip())
    with torch.no_grad():
        return model.translate_one(toks)

def main():
    model = load_model()
    args = sys.argv[1:]
    if args:
        print(translate(model, ' '.join(args)))
    elif not sys.stdin.isatty():
        for line in sys.stdin:
            line = line.strip()
            if line: print(translate(model, line))
    else:
        print('神经翻译（Ctrl+C 退出）')
        try:
            while True:
                line = input('> ').strip()
                if line: print(translate(model, line))
        except (EOFError, KeyboardInterrupt):
            pass

if __name__ == '__main__':
    main()
