#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fine_tune.py — 微调 Helsinki opus-mt 预训练模型（借鉴 Argos 路线）
方向: zh → en

用法:
  python fine_tune.py --limit 20000 --epochs 1     # 校准
  python fine_tune.py --epochs 2 --lr 3e-5         # 正式微调
  python fine_tune.py --resume checkpoints/ft-latest.pt

输出: neural/checkpoints/ft-best.pt (fp16, dev BLEU 最优)
"""
import argparse, math, os, random, time
import torch
import torch.nn as nn
import torch.nn.functional as F
from transformers import MarianMTModel, MarianTokenizer

ROOT = os.environ.get('FT_ROOT') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
DATA_BASE = os.path.join(ROOT, 'neural', 'data')
CKPT_DIR = os.path.join(ROOT, 'neural', 'checkpoints')
os.makedirs(CKPT_DIR, exist_ok=True)

DEVICE = 'cuda' if torch.cuda.is_available() else ('mps' if torch.backends.mps.is_available() else 'cpu')
print('device:', DEVICE)

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--limit', type=int, default=0)
    p.add_argument('--epochs', type=int, default=2)
    p.add_argument('--lr', type=float, default=3e-5)
    p.add_argument('--warmup', type=int, default=500)
    p.add_argument('--batch', type=int, default=24)
    p.add_argument('--max_len', type=int, default=96)
    p.add_argument('--max_steps', type=int, default=0, help='0=不限制')
    p.add_argument('--resume', default=None)
    p.add_argument('--log_every', type=int, default=200)
    p.add_argument('--data', choices=['clean', 'mix', 'long'], default='mix',
                   help='训练数据目录: clean=基础语料, mix=基础+长难句(默认), long=仅长难句')
    p.add_argument('--orientation', choices=['zh2en', 'en2zh'], default='zh2en',
                   help='训练方向（长难句库可互换两列）')
    p.add_argument('--tag', default='ft', help='检查点文件名后缀')
    p.add_argument('--lang_code', default=None, help='目标侧语言代码前缀，如 >>cmn_Hans<< (en2zh 用)')
    return p.parse_args()

ARGS = parse_args()

# 按方向确定源/目标文件后缀与预训练模型目录
SRC_SUF, TGT_SUF = ('zh', 'en') if ARGS.orientation == 'zh2en' else ('en', 'zh')
MODEL_DIR = os.path.join(ROOT, 'neural', 'models',
                         'opus-mt-zh-en' if ARGS.orientation == 'zh2en' else 'opus-mt-en-zh')
CKPT_BEST = os.path.join(CKPT_DIR, f'ft-{ARGS.tag}-best.pt')
CKPT_LATEST = os.path.join(CKPT_DIR, f'ft-{ARGS.tag}-latest.pt')

print('loading tokenizer/model from', MODEL_DIR)
tok = MarianTokenizer.from_pretrained(MODEL_DIR)
model = MarianMTModel.from_pretrained(MODEL_DIR).to(DEVICE)
print(f'model params: {sum(p.numel() for p in model.parameters())/1e6:.1f}M')

def load_lines(split, limit=0):
    src, tgt = [], []
    # dev 评测集始终用基础语料（mix/long 只有 train）
    data_dir = os.path.join(DATA_BASE, 'clean' if split == 'dev' else ARGS.data)
    with open(os.path.join(data_dir, f'{split}.{SRC_SUF}'), encoding='utf-8') as fs, \
         open(os.path.join(data_dir, f'{split}.{TGT_SUF}'), encoding='utf-8') as ft:
        for i, (s, t) in enumerate(zip(fs, ft)):
            if limit and i >= limit: break
            src.append(s.strip()); tgt.append(t.strip())
    return src, tgt

def collate(batch):
    src_txt, tgt_txt = zip(*batch)
    enc = tok(src_txt, return_tensors='pt', padding=True, truncation=True, max_length=ARGS.max_len)
    # 关键：目标侧必须用 target spm 切词，再映射到模型词表 id。
    # 注意 spm.encode(out_type=int) 返回的是 spm 局部 id（与模型词表 id 不同！），
    # 必须用 convert_tokens_to_ids 转换。
    tgt_ids = []
    for t in tgt_txt:
        pieces = tok.spm_target.encode(t, out_type=str)[:ARGS.max_len - 1]
        ids = [i for i in tok.convert_tokens_to_ids(pieces) if i >= 0]
        if ARGS.lang_code:
            cid = tok.convert_tokens_to_ids([ARGS.lang_code])[0]
            ids = [cid] + ids   # 语言代码前缀（多语言目标 spm 的预训练约定）
        tgt_ids.append(ids + [tok.eos_token_id])
    maxl = max(len(x) for x in tgt_ids)
    dec = torch.full((len(tgt_ids), maxl), tok.pad_token_id, dtype=torch.long)
    for i, ids in enumerate(tgt_ids):
        dec[i, :len(ids)] = torch.tensor(ids)
    return {k: v.to(DEVICE) for k, v in enc.items()}, dec.to(DEVICE)

def make_batches(src, tgt, bsz):
    idx = list(range(len(src)))
    random.shuffle(idx)
    return [idx[i:i+bsz] for i in range(0, len(idx), bsz)]

def evaluate():
    model.eval()
    from transformers import MarianTokenizer
    hyps, refs = [], []
    with torch.no_grad():
        for i in range(0, len(dev_src), 32):
            enc = tok(dev_src[i:i+32], return_tensors='pt', padding=True, truncation=True, max_length=ARGS.max_len).to(DEVICE)
            out = model.generate(**enc, max_new_tokens=96, num_beams=4)
            for k, row in enumerate(out):
                hyps.append(tok.decode(row, skip_special_tokens=True))
                refs.append([dev_tgt[i+k]])
    import sacrebleu
    return sacrebleu.corpus_bleu(hyps, refs).score

train_src, train_tgt = load_lines('train', ARGS.limit)
dev_src, dev_tgt = load_lines('dev')
print(f'train: {len(train_src)}, dev: {len(dev_src)}')

opt = torch.optim.AdamW(model.parameters(), lr=ARGS.lr, weight_decay=0.01)
sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min((s+1)/ARGS.warmup, 1.0))
crit = nn.CrossEntropyLoss(ignore_index=tok.pad_token_id, label_smoothing=0.1)

step, best_bleu, epoch0 = 0, 0.0, 0
if ARGS.resume:
    ck = torch.load(ARGS.resume, map_location=DEVICE)
    model.load_state_dict(ck['model'])
    opt.load_state_dict(ck['opt'])
    step, best_bleu, epoch0 = ck['step'], ck.get('best_bleu', 0), ck['epoch']
    print(f'resumed step {step}, best {best_bleu:.2f}')

t0 = time.time()
for epoch in range(epoch0, ARGS.epochs):
    batches = make_batches(train_src, train_tgt, ARGS.batch)
    model.train()
    for bi, bidx in enumerate(batches):
        opt.zero_grad()
        enc, dec_ids = collate([(train_src[i], train_tgt[i]) for i in bidx])
        out = model(**enc, labels=dec_ids)
        loss = out.loss
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step(); sched.step(); step += 1
        if step % ARGS.log_every == 0:
            spd = step / max(time.time() - t0, 1e-9)
            print(f'epoch {epoch} step {step} loss {loss.item():.3f} lr {opt.param_groups[0]["lr"]:.1e} {spd:.2f} step/s', flush=True)
        if ARGS.max_steps and step >= ARGS.max_steps:
            break
    bleu = evaluate()
    print(f'== epoch {epoch}: dev BLEU {bleu:.2f} ==', flush=True)
    ck = {'model': model.state_dict(), 'opt': opt.state_dict(), 'step': step, 'epoch': epoch+1, 'best_bleu': max(best_bleu, bleu)}
    torch.save(ck, CKPT_LATEST)
    if bleu > best_bleu:
        best_bleu = bleu
        torch.save({'model': {k: v.half() for k, v in model.state_dict().items()}, 'step': step, 'epoch': epoch+1, 'bleu': bleu},
                   CKPT_BEST)
        print(f'  -> saved {os.path.basename(CKPT_BEST)} (BLEU {bleu:.2f})')
    model.train()
    if ARGS.max_steps and step >= ARGS.max_steps:
        break
print(f'done. best dev BLEU: {best_bleu:.2f}')
