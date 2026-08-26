#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prepare.py — 平行语料清洗与切分

输入: neural/data/raw/*.txt  (OPUS moses 格式: 每行 "英文\\t中文")
输出: neural/data/clean/{train,dev,test}.{en,zh}

过滤规则:
  - 空行 / 过长（两侧 ≤ 200 字符）
  - 长度比异常 (0.25 ≤ zh_len/en_len ≤ 4)
  - 语言纯度: en 侧 ASCII 字母占比 ≥ 0.5; zh 侧 CJK 占比 ≥ 0.4
  - 完全重复对去重
  - 每语料库上限（平衡领域），总量上限（控制 500MB 预算）
"""
import os, re, random, sys

ROOT = os.path.join(os.path.dirname(__file__), '..')
RAW_DIR = os.path.join(ROOT, 'neural', 'data', 'raw')
OUT_DIR = os.path.join(ROOT, 'neural', 'data', 'clean')

CJK_RE = re.compile(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]')
ASCII_RE = re.compile(r'[a-zA-Z]')

PER_CORPUS_CAP = 120000   # 每个语料库最多取多少对（平衡领域）
TOTAL_CAP = 320000        # 总量上限（内存/磁盘预算）

def is_clean(en, zh):
    en = en.strip(); zh = zh.strip()
    if not en or not zh: return False
    if len(en) > 200 or len(zh) > 200: return False
    if len(en) < 2 or len(zh) < 2: return False
    ratio = len(zh) / max(len(en), 1)
    if ratio < 0.25 or ratio > 4: return False
    en_letters = len(ASCII_RE.findall(en)) / len(en)
    zh_cjk = len(CJK_RE.findall(zh)) / len(zh)
    if en_letters < 0.5: return False
    if zh_cjk < 0.4: return False
    return True

def iter_corpus(fname):
    """按语料格式产出 (en, zh) 对：
       - side-by-side: {name}.en-zh.en / {name}.en-zh.zh
       - tab 分隔: {name}.txt 每行 "en\\tzh"
    """
    path = os.path.join(RAW_DIR, fname)
    if fname.endswith('.en'):
        zh_path = path[:-3] + '.zh'   # 只替换结尾的 .en
        if os.path.exists(zh_path):
            with open(path, encoding='utf-8') as fe, open(zh_path, encoding='utf-8') as fz:
                for e, z in zip(fe, fz):
                    yield e.strip(), z.strip()
            return
    with open(path, encoding='utf-8') as f:
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) >= 2:
                yield parts[0].strip(), parts[1].strip()

def main():
    random.seed(42)
    os.makedirs(OUT_DIR, exist_ok=True)
    seen = set()
    pairs = []
    # 只处理 side-by-side 的 .en 文件和 tab 的 .txt 文件（跳过 .zh/.xml/README/LICENSE）
    files = []
    for f in os.listdir(RAW_DIR):
        if f.endswith('.en') or f.endswith('.txt'):
            files.append(f)
    files.sort()
    if not files:
        print('no corpus files found in', RAW_DIR); sys.exit(1)

    for fname in files:
        n_raw = n_clean = 0
        for en, zh in iter_corpus(fname):
            n_raw += 1
            if not is_clean(en, zh): continue
            key = (en, zh)
            if key in seen: continue
            seen.add(key)
            pairs.append((en, zh))
            n_clean += 1
            if n_clean >= PER_CORPUS_CAP: break
        print(f'[{fname}] raw={n_raw} clean={n_clean}')

    random.shuffle(pairs)
    pairs = pairs[:TOTAL_CAP]
    print(f'total pairs: {len(pairs)}')

    n_test = n_dev = 2000
    test, dev, train = pairs[:n_test], pairs[n_test:n_test + n_dev], pairs[n_test + n_dev:]
    for split, data in [('train', train), ('dev', dev), ('test', test)]:
        with open(os.path.join(OUT_DIR, f'{split}.en'), 'w', encoding='utf-8') as fe, \
             open(os.path.join(OUT_DIR, f'{split}.zh'), 'w', encoding='utf-8') as fz:
            for en, zh in data:
                fe.write(en + '\n'); fz.write(zh + '\n')
        print(f'{split}: {len(data)}')

    # 预算自查
    total_mb = sum(os.path.getsize(os.path.join(OUT_DIR, f)) for f in os.listdir(OUT_DIR)) / 1e6
    print(f'clean data size: {total_mb:.1f} MB')

if __name__ == '__main__':
    main()
