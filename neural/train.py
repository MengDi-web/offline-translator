#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
train.py — 从零训练中英神经机器翻译 (Transformer, SentencePiece)

用法:
  python train.py --limit 20000 --epochs 1          # 校准速度（小样本）
  python train.py --epochs 3                         # 正式训练
  python train.py --resume checkpoints/latest.pt     # 续训

输出:
  neural/checkpoints/best.pt  (dev BLEU 最优, fp16 压缩)
  neural/checkpoints/latest.pt
  neural/data/spm/spm.model   (SentencePiece 词表)
"""
import argparse, math, os, random, sys, time
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import sentencepiece as spm

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
CLEAN = os.path.join(ROOT, 'neural', 'data', 'clean')
SPM_DIR = os.path.join(ROOT, 'neural', 'data', 'spm')
CKPT_DIR = os.path.join(ROOT, 'neural', 'checkpoints')
os.makedirs(SPM_DIR, exist_ok=True)
os.makedirs(CKPT_DIR, exist_ok=True)

DEVICE = 'mps' if torch.backends.mps.is_available() else 'cpu'
print(f'device: {DEVICE}')

# ---------------- 超参数 ----------------
def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--limit', type=int, default=0, help='只用前 N 条训练(校准用)')
    p.add_argument('--epochs', type=int, default=3)
    p.add_argument('--resume', default=None)
    p.add_argument('--vocab', type=int, default=16000)
    p.add_argument('--d_model', type=int, default=256)
    p.add_argument('--layers', type=int, default=3)
    p.add_argument('--heads', type=int, default=4)
    p.add_argument('--ff', type=int, default=1024)
    p.add_argument('--dropout', type=float, default=0.1)
    p.add_argument('--max_len', type=int, default=128)
    p.add_argument('--max_tokens', type=int, default=4096)
    p.add_argument('--warmup', type=int, default=4000)
    p.add_argument('--label_smooth', type=float, default=0.1)
    p.add_argument('--log_every', type=int, default=500)
    p.add_argument('--eval_every', type=int, default=0, help='每 N 步评估一次(0=每轮末)')
    return p.parse_args()

ARGS = parse_args()

# ---------------- SentencePiece ----------------
def train_spm():
    os.makedirs(SPM_DIR, exist_ok=True)
    model_path = os.path.join(SPM_DIR, 'spm.model')
    if os.path.exists(model_path):
        return spm.SentencePieceProcessor(model_file=model_path)
    # 合并中英文做共享词表
    concat = os.path.join(SPM_DIR, 'concat.txt')
    with open(concat, 'w', encoding='utf-8') as out, \
         open(os.path.join(CLEAN, 'train.en'), encoding='utf-8') as fe, \
         open(os.path.join(CLEAN, 'train.zh'), encoding='utf-8') as fz:
        for e, z in zip(fe, fz):
            out.write(e.strip() + '\n' + z.strip() + '\n')
    print('training SentencePiece ...')
    spm.SentencePieceTrainer.train(
        input=concat,
        model_prefix=os.path.join(SPM_DIR, 'spm'),
        vocab_size=ARGS.vocab,
        model_type='bpe',
        character_coverage=1.0,
        byte_fallback=True,
        bos_id=1, eos_id=2, pad_id=0, unk_id=3,
        max_sentence_length=10000,
    )
    os.remove(concat)
    return spm.SentencePieceProcessor(model_file=model_path)

SP = train_spm()
PAD, BOS, EOS = SP.pad_id(), SP.bos_id(), SP.eos_id()
VOCAB = SP.get_piece_size()
print(f'vocab size: {VOCAB}')

def encode(line):
    ids = SP.encode(line, out_type=int)
    return [BOS] + ids[:ARGS.max_len - 2] + [EOS]

# ---------------- 数据 ----------------
def load_data(split, limit=0):
    src, tgt = [], []
    with open(os.path.join(CLEAN, f'{split}.en'), encoding='utf-8') as fe, \
         open(os.path.join(CLEAN, f'{split}.zh'), encoding='utf-8') as fz:
        for i, (e, z) in enumerate(zip(fe, fz)):
            if limit and i >= limit: break
            src.append(encode(e.strip()))
            tgt.append(encode(z.strip()))
    return src, tgt

def make_batches(src, tgt, max_tokens):
    idx = list(range(len(src)))
    random.shuffle(idx)
    batches = []
    cur, cur_tokens = [], 0
    for i in idx:
        toks = max(len(src[i]), len(tgt[i]))
        if cur and cur_tokens + toks > max_tokens:
            batches.append(cur); cur, cur_tokens = [], 0
        cur.append(i); cur_tokens += toks
    if cur: batches.append(cur)
    return batches

def collate(indices, src, tgt):
    sl = torch.tensor([len(src[i]) for i in indices], dtype=torch.long)
    tl = torch.tensor([len(tgt[i]) for i in indices], dtype=torch.long)
    sm, tm = sl.max().item(), tl.max().item()
    sb = torch.zeros(len(indices), sm, dtype=torch.long).fill_(PAD)
    tb = torch.zeros(len(indices), tm, dtype=torch.long).fill_(PAD)
    for k, i in enumerate(indices):
        sb[k, :len(src[i])] = torch.tensor(src[i], dtype=torch.long)
        tb[k, :len(tgt[i])] = torch.tensor(tgt[i], dtype=torch.long)
    return sb.to(DEVICE), tb.to(DEVICE)

# ---------------- 模型 ----------------
class PosEnc(nn.Module):
    def __init__(self, d, dropout, max_len=512):
        super().__init__()
        self.dropout = nn.Dropout(dropout)
        pe = torch.zeros(max_len, d)
        pos = torch.arange(0, max_len).unsqueeze(1).float()
        div = torch.exp(torch.arange(0, d, 2).float() * (-math.log(10000.0) / d))
        pe[:, 0::2] = torch.sin(pos * div)
        pe[:, 1::2] = torch.cos(pos * div)
        self.register_buffer('pe', pe)
    def forward(self, x):
        return self.dropout(x + self.pe[:x.size(1)])

class NMT(nn.Module):
    def __init__(self, vocab, d, nlayers, heads, ff, dropout):
        super().__init__()
        self.emb = nn.Embedding(vocab, d, padding_idx=PAD)
        self.pos = PosEnc(d, dropout)
        layer = nn.TransformerEncoderLayer(d, heads, ff, dropout, batch_first=True, norm_first=True)
        self.encoder = nn.TransformerEncoder(layer, nlayers)
        dlayer = nn.TransformerDecoderLayer(d, heads, ff, dropout, batch_first=True, norm_first=True)
        self.decoder = nn.TransformerDecoder(dlayer, nlayers)
        self.out = nn.Linear(d, vocab)
    def forward(self, src, tgt):
        smask = (src == PAD)
        tmask = (tgt == PAD)
        mem = self.encoder(self.pos(self.emb(src)), src_key_padding_mask=smask)
        tgt_in = tgt[:, :-1]
        tgt_mask = torch.triu(torch.full((tgt_in.size(1), tgt_in.size(1)), float('-inf')), diagonal=1, device=tgt.device)
        dec = self.decoder(self.pos(self.emb(tgt_in)), mem,
                           tgt_mask=tgt_mask,
                           tgt_key_padding_mask=tmask[:, :-1],
                           memory_key_padding_mask=smask)
        return self.out(dec)
    @torch.no_grad()
    def translate_batch(self, src, max_len=128):
        self.eval()
        smask = (src == PAD)
        mem = self.encoder(self.pos(self.emb(src)), src_key_padding_mask=smask)
        bsz = src.size(0)
        ys = torch.full((bsz, 1), BOS, dtype=torch.long, device=src.device)
        for _ in range(max_len):
            tmask = torch.zeros_like(ys).bool()
            tgt_mask = torch.triu(torch.full((ys.size(1), ys.size(1)), float('-inf')), diagonal=1, device=src.device)
            dec = self.decoder(self.pos(self.emb(ys)), mem,
                               tgt_mask=tgt_mask, tgt_key_padding_mask=tmask,
                               memory_key_padding_mask=smask)
            logits = self.out(dec[:, -1])
            nxt = logits.argmax(-1).unsqueeze(1)
            ys = torch.cat([ys, nxt], dim=1)
            done = (ys == EOS).any(dim=1)
            if done.all(): break
        return ys
    def translate_one(self, toks, max_len=128):
        ys = self.translate_batch(torch.tensor([toks], device=DEVICE), max_len)
        out = ys[0].tolist()
        if EOS in out: out = out[:out.index(EOS)]
        return SP.decode([t for t in out if t not in (BOS, EOS, PAD)])

# ---------------- 训练 ----------------
def main():
    src_tr, tgt_tr = load_data('train', ARGS.limit)
    src_dev, tgt_dev = load_data('dev')
    print(f'train pairs: {len(src_tr)}, dev pairs: {len(src_dev)}')

    model = NMT(VOCAB, ARGS.d_model, ARGS.layers, ARGS.heads, ARGS.ff, ARGS.dropout).to(DEVICE)
    n_params = sum(p.numel() for p in model.parameters())
    print(f'model params: {n_params/1e6:.1f}M')
    print(f'checkpoint est: {n_params*4/1e6:.0f}MB fp32 / {n_params*2/1e6:.0f}MB fp16')

    opt = torch.optim.Adam(model.parameters(), betas=(0.9, 0.98), eps=1e-9)
    step, best_bleu, epoch0 = 0, 0.0, 0
    if ARGS.resume:
        ck = torch.load(ARGS.resume, map_location=DEVICE)
        model.load_state_dict(ck['model'])
        opt.load_state_dict(ck['opt'])
        step, best_bleu, epoch0 = ck['step'], ck.get('best_bleu', 0), ck['epoch']
        print(f'resumed from step {step}, best_bleu {best_bleu:.2f}')

    crit = nn.CrossEntropyLoss(ignore_index=PAD, label_smoothing=ARGS.label_smooth)
    d_inv = ARGS.d_model ** -0.5

    def lr_at(s):
        return d_inv * min(s ** -0.5, s * ARGS.warmup ** -1.5)

    def evaluate():
        model.eval()
        hyps, refs = [], []
        for i in range(0, len(src_dev), 64):
            sb = torch.zeros(min(64, len(src_dev) - i), max(len(x) for x in src_dev[i:i+64]), dtype=torch.long).fill_(PAD).to(DEVICE)
            for k, toks in enumerate(src_dev[i:i+64]):
                sb[k, :len(toks)] = torch.tensor(toks)
            ys = model.translate_batch(sb)
            for k, row in enumerate(ys):
                toks = row.tolist()
                if EOS in toks: toks = toks[:toks.index(EOS)]
                hyps.append(SP.decode([t for t in toks if t not in (BOS, EOS, PAD)]))
                refs.append([SP.decode(tgt_dev[i+k])])
        import sacrebleu
        return sacrebleu.corpus_bleu(hyps, refs).score

    t0 = time.time()
    for epoch in range(epoch0, ARGS.epochs):
        batches = make_batches(src_tr, tgt_tr, ARGS.max_tokens)
        model.train()
        for bi, bidx in enumerate(batches):
            opt.zero_grad()
            src, tgt = collate(bidx, src_tr, tgt_tr)
            logits = model(src, tgt)
            loss = crit(logits.reshape(-1, VOCAB), tgt[:, 1:].reshape(-1))
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.param_groups[0]['lr'] = lr_at(step + 1)
            opt.step()
            step += 1
            if step % ARGS.log_every == 0:
                spd = step / max(time.time() - t0, 1e-9)
                print(f'epoch {epoch} step {step} loss {loss.item():.3f} lr {opt.param_groups[0]["lr"]:.2e} {spd:.1f} step/s', flush=True)
            if ARGS.eval_every and step % ARGS.eval_every == 0:
                bleu = evaluate()
                print(f'  [eval @{step}] BLEU {bleu:.2f}', flush=True)
                model.train()
        # 每轮末评估 + 存档
        bleu = evaluate()
        print(f'== epoch {epoch} done: dev BLEU {bleu:.2f} ==', flush=True)
        ck = {'model': model.state_dict(), 'opt': opt.state_dict(), 'step': step, 'epoch': epoch + 1, 'best_bleu': max(best_bleu, bleu)}
        torch.save(ck, os.path.join(CKPT_DIR, 'latest.pt'))
        if bleu > best_bleu:
            best_bleu = bleu
            torch.save({'model': {k: v.half() for k, v in model.state_dict().items()},
                        'step': step, 'epoch': epoch + 1, 'bleu': bleu},
                       os.path.join(CKPT_DIR, 'best.pt'))
            print(f'  -> saved best.pt (BLEU {bleu:.2f})')
        model.train()
    print(f'done. best dev BLEU: {best_bleu:.2f}')

if __name__ == '__main__':
    main()
