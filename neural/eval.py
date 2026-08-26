#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eval.py — 评估已训练模型 (dev/test BLEU + 抽样译文)

用法: python eval.py [--ckpt checkpoints/best.pt] [--split dev] [--n 20]
"""
import argparse, os, sys
import torch
from train import NMT, SP, PAD, BOS, EOS, VOCAB, DEVICE, load_data, encode

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--ckpt', default=os.path.join(ROOT, 'neural', 'checkpoints', 'best.pt'))
    p.add_argument('--split', default='dev')
    p.add_argument('--n', type=int, default=20)
    p.add_argument('--beam', type=int, default=1)
    args = p.parse_args()
    if not os.path.exists(args.ckpt):
        print('checkpoint not found:', args.ckpt); sys.exit(1)

    ck = torch.load(args.ckpt, map_location=DEVICE)
    model = NMT(VOCAB, 256, 3, 4, 1024, 0.1).to(DEVICE)
    sd = ck['model']
    if next(iter(sd.values())).dtype == torch.float16:
        sd = {k: v.float() for k, v in sd.items()}
    model.load_state_dict(sd)
    print(f'loaded {args.ckpt} (step {ck.get("step")}, bleu {ck.get("bleu")})')

    src, tgt = load_data(args.split)
    hyps, refs = [], []
    with torch.no_grad():
        for i in range(0, len(src), 64):
            sb = torch.zeros(min(64, len(src) - i), max(len(x) for x in src[i:i+64]), dtype=torch.long).fill_(PAD).to(DEVICE)
            for k, toks in enumerate(src[i:i+64]):
                sb[k, :len(toks)] = torch.tensor(toks)
            ys = model.translate_batch(sb)
            for k, row in enumerate(ys):
                toks = row.tolist()
                if EOS in toks: toks = toks[:toks.index(EOS)]
                hyps.append(SP.decode([t for t in toks if t not in (BOS, EOS, PAD)]))
                refs.append([SP.decode(tgt[i + k])])
    import sacrebleu
    b = sacrebleu.corpus_bleu(hyps, refs)
    print(f'{args.split} BLEU: {b.score:.2f}')

    print('\n--- 抽样译文 ---')
    for k in range(min(args.n, len(src))):
        print(f'S: {SP.decode(src[k])}')
        print(f'R: {refs[k][0]}')
        print(f'H: {hyps[k]}')
        print()

if __name__ == '__main__':
    main()
