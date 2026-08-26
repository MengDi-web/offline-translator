#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_long_data.py — 处理用户提供的「长难句翻译数据库」

用法: python build_long_data.py

输入: 翻译数据库/长难句翻译数据库.jsonl  (字段: en / zh / domain)
输出:
  neural/data/long/train.{en,zh}    每个 domain 留出 5 条后剩余的 250 条
  neural/data/long/dev.{en,zh}      每个 domain 留出 5 条 = 50 条评测
  neural/data/long/dev.meta.jsonl   dev 每行的 domain 标注（分领域评测用）
  neural/data/mix/train.{en,zh}     基础平行语料(clean/) + 长难句×20 上采样混用
"""
import json, os, random, shutil

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
LONG_JSONL = os.path.join(ROOT, '翻译数据库', '长难句翻译数据库.jsonl')
LONG_DIR = os.path.join(ROOT, 'neural', 'data', 'long')
MIX_DIR = os.path.join(ROOT, 'neural', 'data', 'mix')
CLEAN_DIR = os.path.join(ROOT, 'neural', 'data', 'clean')

HOLD_OUT_PER_DOMAIN = 5
UPSAMPLE = 20

def main():
    random.seed(7)
    # 读取长难句
    rows = []
    with open(LONG_JSONL, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            rows.append(d)
    print('长难句总数:', len(rows))

    # 按 domain 分组，组内打乱，留出评测集
    by_dom = {}
    for d in rows:
        by_dom.setdefault(d['domain'], []).append(d)
    train, dev, dev_meta = [], [], []
    for dom, items in sorted(by_dom.items()):
        random.shuffle(items)
        dev_items = items[:HOLD_OUT_PER_DOMAIN]
        tr_items = items[HOLD_OUT_PER_DOMAIN:]
        dev.extend(dev_items)
        train.extend(tr_items)
        for it in dev_items:
            dev_meta.append({'domain': dom, 'id': it.get('id')})
    random.shuffle(train)
    print(f'train: {len(train)} (每域留出 {HOLD_OUT_PER_DOMAIN}, 共 {len(dev)} 评测)')

    os.makedirs(LONG_DIR, exist_ok=True)
    os.makedirs(MIX_DIR, exist_ok=True)
    with open(os.path.join(LONG_DIR, 'train.en'), 'w', encoding='utf-8') as fe, \
         open(os.path.join(LONG_DIR, 'train.zh'), 'w', encoding='utf-8') as fz:
        for it in train:
            fe.write(it['en'].strip() + '\n'); fz.write(it['zh'].strip() + '\n')
    with open(os.path.join(LONG_DIR, 'dev.en'), 'w', encoding='utf-8') as fe, \
         open(os.path.join(LONG_DIR, 'dev.zh'), 'w', encoding='utf-8') as fz:
        for it in dev:
            fe.write(it['en'].strip() + '\n'); fz.write(it['zh'].strip() + '\n')
    with open(os.path.join(LONG_DIR, 'dev.meta.jsonl'), 'w', encoding='utf-8') as fm:
        for m in dev_meta:
            fm.write(json.dumps(m, ensure_ascii=False) + '\n')
    print('long/ 数据已写出')

    # 混用: 基础平行语料 + 长难句 × UPSAMPLE
    base_en = open(os.path.join(CLEAN_DIR, 'train.en'), encoding='utf-8').read().splitlines()
    base_zh = open(os.path.join(CLEAN_DIR, 'train.zh'), encoding='utf-8').read().splitlines()
    long_en = open(os.path.join(LONG_DIR, 'train.en'), encoding='utf-8').read().splitlines()
    long_zh = open(os.path.join(LONG_DIR, 'train.zh'), encoding='utf-8').read().splitlines()
    mix_en = list(base_en) + long_en * UPSAMPLE
    mix_zh = list(base_zh) + long_zh * UPSAMPLE
    print(f'mix: base {len(base_en)} + 长难句 {len(long_en)}×{UPSAMPLE}={len(long_en)*UPSAMPLE} → {len(mix_en)}')
    with open(os.path.join(MIX_DIR, 'train.en'), 'w', encoding='utf-8') as fe, \
         open(os.path.join(MIX_DIR, 'train.zh'), 'w', encoding='utf-8') as fz:
        fe.write('\n'.join(mix_en) + '\n'); fz.write('\n'.join(mix_zh) + '\n')
    print('mix/ 数据已写出')

    mb = sum(os.path.getsize(os.path.join(MIX_DIR, f)) for f in os.listdir(MIX_DIR)) / 1e6
    print(f'mix 数据大小: {mb:.1f} MB')

if __name__ == '__main__':
    main()
