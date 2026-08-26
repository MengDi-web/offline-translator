#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eval_long.py — 长难句分领域评测（预训练 vs 微调）

用法:
  python eval_long.py --orientation zh2en --ckpt checkpoints/ft-zh2en-best.pt
  python eval_long.py --orientation en2zh --ckpt checkpoints/ft-en2zh-best.pt --pretrained

按 domain 字段分领域统计 BLEU，并打印抽样译文对比。
"""
import argparse, json, os
import torch
from transformers import MarianMTModel, MarianTokenizer

ROOT = os.environ.get('FT_ROOT') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
LONG_DIR = os.path.join(ROOT, 'neural', 'data', 'long')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--orientation', choices=['zh2en', 'en2zh'], required=True)
    p.add_argument('--ckpt', default=None, help='微调检查点；不传则只用预训练')
    p.add_argument('--n', type=int, default=0, help='抽样展示条数(0=全部)')
    args = p.parse_args()

    model_name = 'opus-mt-zh-en' if args.orientation == 'zh2en' else 'opus-mt-en-zh'
    model_dir = os.path.join(ROOT, 'neural', 'models', model_name)
    if not os.path.exists(model_dir):
        model_dir = f'/tmp/nmt-models/{model_name}'
    tok = MarianTokenizer.from_pretrained(model_dir)
    model = MarianMTModel.from_pretrained(model_dir)
    if args.ckpt and os.path.exists(args.ckpt):
        ck = torch.load(args.ckpt, map_location='cpu')
        sd = ck['model']
        if next(iter(sd.values())).dtype == torch.float16:
            sd = {k: v.float() for k, v in sd.items()}
        model.load_state_dict(sd)
        print(f'loaded fine-tuned: {args.ckpt} (bleu {ck.get("bleu")})')
    else:
        print('using pretrained model')
    model.eval()
    dev = 'cuda' if torch.cuda.is_available() else ('mps' if torch.backends.mps.is_available() else 'cpu')
    model.to(dev)

    src_f, tgt_f = ('zh', 'en') if args.orientation == 'zh2en' else ('en', 'zh')
    src = open(os.path.join(LONG_DIR, f'dev.{src_f}'), encoding='utf-8').read().splitlines()
    tgt = open(os.path.join(LONG_DIR, f'dev.{tgt_f}'), encoding='utf-8').read().splitlines()
    meta = [json.loads(l) for l in open(os.path.join(LONG_DIR, 'dev.meta.jsonl'), encoding='utf-8')]

    import sacrebleu
    hyps = []
    with torch.no_grad():
        for i in range(0, len(src), 8):
            enc = tok(src[i:i+8], return_tensors='pt', padding=True, truncation=True, max_length=200).to(dev)
            out = model.generate(**enc, max_new_tokens=200, num_beams=4)
            for row in out:
                hyps.append(tok.decode(row, skip_special_tokens=True))

    overall = sacrebleu.corpus_bleu(hyps, [[r] for r in tgt]).score
    print(f'\n=== {args.orientation} 总体 BLEU: {overall:.2f} ===')
    by_dom = {}
    for i, m in enumerate(meta):
        by_dom.setdefault(m['domain'], {'ref': [], 'hyp': []})
        by_dom[m['domain']]['ref'].append(tgt[i])
        by_dom[m['domain']]['hyp'].append(hyps[i])
    print(f'\n--- 分领域 BLEU ---')
    for dom, d in sorted(by_dom.items()):
        b = sacrebleu.corpus_bleu(d['hyp'], [[r] for r in d['ref']]).score
        print(f'  {dom}: {b:.2f}')

    if args.n:
        print('\n--- 抽样译文 ---')
        import random
        random.seed(3)
        for i in random.sample(range(len(src)), min(args.n, len(src))):
            print(f'S: {src[i]}')
            print(f'R: {tgt[i]}')
            print(f'H: {hyps[i]}')
            print()

if __name__ == '__main__':
    main()
