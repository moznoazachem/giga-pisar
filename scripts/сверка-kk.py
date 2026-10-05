#!/usr/bin/env python
"""Сверка казахского ядра: Swift (build/kktest) против Python (server/kk_core.py).

    ./scripts/kktest.sh
    python scripts/сверка-kk.py запись.wav [ещё.wav ...]

Две проверки:
  1. правила пунктуации — на одних и тех же словах обязаны совпасть до буквы;
  2. распознавание целиком — совпадение ≥ 99% по символам (дрожание float).
Записи — 16 кГц, моно, 16 бит (такие пишет само приложение):
    ffmpeg -i вход.m4a -ac 1 -ar 16000 запись.wav
"""
import difflib
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "server"))
from kk_core import KazakhEngine, read_wav  # noqa: E402
from kk_punct import punctuate             # noqa: E402

BIN = os.path.join(HERE, "..", "build", "kktest")


def swift(*args):
    out = subprocess.run([BIN, *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"kktest упал:\n{out.stderr}")
    return [s.strip() for s in out.stdout.splitlines()]


def main():
    files = sys.argv[1:]
    if not files:
        sys.exit(__doc__)
    if not os.path.exists(BIN):
        sys.exit("нет build/kktest — сначала ./scripts/kktest.sh")

    eng = KazakhEngine()
    print(f"модель: {eng.model_dir}\n")

    print("── 1. правила пунктуации")
    rules_ok = True
    words_by_file = {}
    for path in files:
        words = eng.words(read_wav(path))
        words_by_file[path] = words
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            json.dump(words, f, ensure_ascii=False)
        s = swift("--punct", f.name)[0]
        os.unlink(f.name)
        p = punctuate(words)
        same = s == p
        rules_ok &= same
        print(f"  {os.path.basename(path)}: {'✓ совпало' if same else '✗ РАЗОШЛОСЬ'}")
        if not same:
            for d in difflib.ndiff(p.split(), s.split()):
                if d[0] in "+-":
                    print("     ", d)

    print("\n── 2. распознавание целиком")
    sw = swift(*files)
    total = matched = 0
    for path, s in zip(files, sw):
        p = punctuate(words_by_file[path])
        m = difflib.SequenceMatcher(None, p, s)
        matched += sum(b.size for b in m.get_matching_blocks())
        total += max(len(p), len(s))
        print(f"  {os.path.basename(path)}: {'✓ совпало' if s == p else '≈ разошлось'}")
        if s != p:
            print(f"      питон: {p[:200]!r}")
            print(f"      свифт: {s[:200]!r}")
    share = matched / total if total else 1.0
    print(f"\n── Итог: правила {'✓' if rules_ok else '✗'}, совпадение текста {share * 100:.2f}%")
    sys.exit(0 if rules_ok and share >= 0.99 else 1)


if __name__ == "__main__":
    main()
