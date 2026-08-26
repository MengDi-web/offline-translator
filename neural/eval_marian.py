#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eval_marian.py — Marian 模型在 clean dev/test 上的 BLEU（预训练 vs 微调对比）

用法:
  python eval_marian.py --orientation zh2en                     # 预训练
  python eval_marian.py --orientation zh2en --ckpt checkpoints/ft-zh2en-best.pt
"""
import argparse, os
import torch
from transformers import MarianMTModel, MarianTokenizer

ROOT = os.environ.get('FT_ROOT') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--orientation', choices=['zh2en', 'en2zh'], required=True)
    p.add_argument('--ckpt', default=None)
    p.add_argument('--split', default='dev')
    p.add_argument('--samples', type=int, default=0)
    args = p.parse_args()

    model_name = 'opus-mt-zh-en' if args.orientation == 'zh2en' else 'opus-mt-en-zh'
    model_dir = os.path.join(ROOT, 'neural', 'models', model_name)
    if not os.path.exists(model_dir):
        model_dir = f'/mnt/home/mengd/nmt-train/neural/models/{model_name}'
    tok = MarianTokenizer.from_pretrained(model_dir)
    model = MarianMTModel.from_pretrained(model_dir)
    if args.ckpt:
        ck = torch.load(args.ckpt, map_location='cpu')
        sd = ck['model']
        if next(iter(sd.values())).dtype == torch.float16:
            sd = {k: v.float() for k, v in sd.items()}
        model.load_state_dict(sd)
        print(f'[model] fine-tuned ({args.ckpt}), train-bleu={ck.get("bleu")}')
    else:
        print('[model] pretrained')
    dev = 'cuda' if torch.cuda.is_available() else 'cpu'
    model.to(dev).eval()

    src_f, tgt_f = ('zh', 'en') if args.orientation == 'zh2en' else ('en', 'zh')
    data_dir = os.path.join(ROOT, 'neural', 'data', 'clean')
    src = open(os.path.join(data_dir, f'{args.split}.{src_f}'), encoding='utf-8').read().splitlines()
    tgt = open(os.path.join(data_dir, f'{args.split}.{tgt_f}'), encoding='utf-8').read().splitlines()
    print(f'[data] {args.split}: {len(src)}')

    import sacrebleu
    hyps = []
    with torch.no_grad():
        for i in range(0, len(src), 32):
            enc = tok(src[i:i+32], return_tensors='pt', padding=True, truncation=True, max_length=160).to(dev)
            out = model.generate(**enc, max_new_tokens=160, num_beams=4)
            for row in out:
                hyps.append(tok.decode(row, skip_special_tokens=True))
    b = sacrebleu.corpus_bleu(hyps, [[r] for r in tgt])
    print(f'[bleu] {args.orientation} {args.split}: {b.score:.2f}')

    if args.samples:
        print('\n--- 抽样 ---')
        for i in range(min(args.samples, len(src))):
            print(f'S: {src[i]}')
            print(f'R: {tgt[i]}')
            print(f'H: {hyps[i]}')
            print()

if __name__ == '__main__':
    main()
