#!/usr/bin/env python
"""Казахское ядро Гига Писаря: GigaAM Multilingual (multilingual_ctc) в ONNX.

Эталон для swift/CTC.swift. Зависимости те же, что у giga_core: onnxruntime,
numpy, pyyaml. PyTorch и библиотека gigaam не нужны.

Порядок: звук → лог-мел-признаки (те же, что у v3) → модель целиком
(энкодер + CTC-голова в одном графе) → жадное CTC-декодирование по буквам →
слова со временем → пунктуация по правилам (kk_punct).

    python kk_core.py запись.wav [ещё.wav ...]      # модель ищется в ~/.giga/model-kk
"""
from __future__ import annotations

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from giga_core import Features, read_wav  # noqa: E402
from kk_punct import punctuate            # noqa: E402

MODEL_NAME = "multilingual_ctc"
SAMPLE_RATE = 16000
MAX_CHUNK = 24.0


def find_model_dir(extra: str = "") -> str:
    for path in [extra, os.environ.get("PISAR_KK_MODEL_DIR", ""),
                 os.path.expanduser("~/.giga/model-kk")]:
        if path and os.path.exists(os.path.join(path, f"{MODEL_NAME}.yaml")):
            return path
    raise FileNotFoundError("не нашёл казахскую модель: укажите PISAR_KK_MODEL_DIR")


def silences(x: np.ndarray, rate: int = SAMPLE_RATE, noise_db: float = -35,
             min_seconds: float = 0.3) -> list:
    """Середины пауз — ровно как Audio.silences в Swift (по сэмплам, без ffmpeg)."""
    quiet = (np.abs(x) < np.float32(10.0 ** (noise_db / 20.0))).astype(np.int8)
    # отрезки тишины [start, i): i — первый громкий сэмпл после них.
    # Тишина в самом конце записи не считается — как и в Swift.
    d = np.diff(np.concatenate([[0], quiet]))
    starts = np.nonzero(d == 1)[0]
    ends = np.nonzero(d == -1)[0]
    starts = starts[:len(ends)]
    min_run = int(min_seconds * rate)
    return [(s + e) / 2.0 / rate for s, e in zip(starts, ends) if e - s >= min_run]


def chunk_bounds(total: float, sil: list, max_chunk: float = MAX_CHUNK) -> list:
    bounds, pos = [], 0.0
    while total - pos > max_chunk:
        cand = [s for s in sil if pos + 3 < s <= pos + max_chunk]
        cut = cand[-1] if cand else pos + max_chunk
        bounds.append((pos, cut))
        pos = cut
    bounds.append((pos, total))
    return bounds


class KazakhEngine:
    def __init__(self, model_dir: str = "", threads: int = 0):
        import onnxruntime as rt
        import yaml

        self.model_dir = find_model_dir(model_dir)
        with open(os.path.join(self.model_dir, f"{MODEL_NAME}.yaml"), encoding="utf-8") as f:
            cfg = yaml.safe_load(f)
        with open(os.path.join(self.model_dir, f"{MODEL_NAME}_vocab.json"), encoding="utf-8") as f:
            self.vocab = json.load(f)
        self.blank_id = len(self.vocab)
        self.features = Features(cfg)
        # Словарь общий для пяти языков, язык модели не задать. На коротких
        # фразах казахский путается с узбекским, а тот пишется латиницей:
        # «Mening otim» вместо «Менің атым». Поэтому латиницу запрещаем —
        # из оставшихся букв самое вероятное написание и есть казахское.
        self.allowed = np.array([not ("a" <= ch <= "z") for ch in self.vocab] + [True])

        opts = rt.SessionOptions()
        opts.graph_optimization_level = rt.GraphOptimizationLevel.ORT_ENABLE_ALL
        opts.intra_op_num_threads = threads or min(8, os.cpu_count() or 4)
        opts.log_severity_level = 3
        self.sess = rt.InferenceSession(os.path.join(self.model_dir, f"{MODEL_NAME}.onnx"),
                                        providers=["CPUExecutionProvider"], sess_options=opts)

    def words_wave(self, wav: np.ndarray, offset: float = 0.0) -> list:
        """Одна волна (≤ 25 с) → [(слово, начало, конец)] в секундах от offset."""
        feats = self.features(wav)
        if feats.shape[2] == 0:
            return []
        lens = np.array([self.features.out_len(len(wav))], dtype=np.int64)
        log_probs, enc_len = self.sess.run(
            None, {i.name: v for i, v in zip(self.sess.get_inputs(), [feats, lens])})
        lp = np.where(self.allowed[np.newaxis, :], log_probs[0], -np.inf)
        labels = lp.argmax(axis=-1)                    # [T], только разрешённые буквы
        T = labels.shape[0]
        n = min(int(np.asarray(enc_len).reshape(-1)[0]), T)
        if n == 0:
            return []
        shift = len(wav) / SAMPLE_RATE / n             # секунд на кадр энкодера

        words, chars, frames = [], [], []

        def commit():
            if chars:
                text = "".join(chars)
                words.append((text, offset + frames[0] * shift, offset + (frames[-1] + 1) * shift))
            chars.clear()
            frames.clear()

        prev = -1
        for t in range(n):
            k = int(labels[t])
            if k != self.blank_id and k != prev:
                ch = self.vocab[k]
                if ch == " ":
                    commit()
                else:
                    chars.append(ch)
                    frames.append(t)
            prev = k
        commit()
        return words

    def words(self, samples: np.ndarray) -> list:
        total = len(samples) / SAMPLE_RATE
        if total <= MAX_CHUNK + 1:
            return self.words_wave(samples)
        out = []
        for a, b in chunk_bounds(total, silences(samples)):
            x = samples[min(len(samples), int(a * SAMPLE_RATE)):min(len(samples), int(b * SAMPLE_RATE))]
            if len(x):
                out += self.words_wave(x, offset=a)
        return out

    def transcribe_samples(self, samples: np.ndarray, punct: bool = True) -> str:
        w = self.words(samples)
        return punctuate(w) if punct else " ".join(x[0] for x in w)

    def transcribe(self, wav_path: str, punct: bool = True) -> str:
        return self.transcribe_samples(read_wav(wav_path), punct)


if __name__ == "__main__":
    eng = KazakhEngine()
    for p in sys.argv[1:]:
        print(eng.transcribe(p))
