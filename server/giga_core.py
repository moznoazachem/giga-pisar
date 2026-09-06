#!/usr/bin/env python
"""Ядро Гига Писаря: распознавание речи моделью GigaAM v3 в формате ONNX.

Один и тот же движок для всех трёх оболочек — командной строки, сервера
и маковского приложения. Считает на процессоре, в сеть ничего не уходит.

Зависимости намеренно скромные: onnxruntime, numpy, sentencepiece, pyyaml.
Библиотека gigaam НЕ нужна: она тянет за собой PyTorch (треть гигабайта),
хотя для счёта его не использует. Всё, что она делала, повторено здесь —
это же и будет образцом, если ядро когда-нибудь перепишут на Swift.

Порядок работы: звук → лог-мел-признаки → энкодер → жадное декодирование
RNN-T (декодер и джойнт по кадрам) → склейка кусочков слов токенизатором.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

SAMPLE_RATE = 16000
MODEL_NAME = "v3_e2e_rnnt"

MAX_CHUNK = 24.0        # предел одного прохода модели — 25 секунд
SILENCE_DB = -35        # порог тишины для нарезки
SILENCE_MIN = 0.3       # минимальная длина паузы, секунды
MAX_SYMBOLS_PER_FRAME = 3   # столько букв максимум с одного кадра


# ─────────────────────────── признаки звука ───────────────────────────
# Повтор torchaudio.transforms.MelSpectrogram с параметрами из yaml модели.
# Расхождение здесь даёт на выходе не «чуть хуже», а бессмыслицу,
# поэтому всё сверяется с образцом в scripts/сверка.py.

def _hz_to_mel(freq):
    """Шкала мелов, вариант htk — тот же, что берёт torchaudio по умолчанию."""
    return 2595.0 * np.log10(1.0 + freq / 700.0)


def _mel_to_hz(mels):
    return 700.0 * (10.0 ** (mels / 2595.0) - 1.0)


def _mel_filterbank(n_freqs, f_min, f_max, n_mels, sample_rate):
    """Треугольные фильтры, как в torchaudio.functional.melscale_fbanks (norm=None)."""
    all_freqs = np.linspace(0, sample_rate // 2, n_freqs)
    m_pts = np.linspace(_hz_to_mel(f_min), _hz_to_mel(f_max), n_mels + 2)
    f_pts = _mel_to_hz(m_pts)

    f_diff = f_pts[1:] - f_pts[:-1]                       # [n_mels+1]
    slopes = f_pts[np.newaxis, :] - all_freqs[:, np.newaxis]   # [n_freqs, n_mels+2]
    down = -slopes[:, :-2] / f_diff[np.newaxis, :-1]
    up = slopes[:, 2:] / f_diff[np.newaxis, 1:]
    return np.maximum(0.0, np.minimum(down, up))          # [n_freqs, n_mels]


class Features:
    """Превращает звуковую волну в лог-мел-спектрограмму для энкодера."""

    def __init__(self, cfg: dict):
        pre = cfg["preprocessor"]
        self.sample_rate = int(pre.get("sample_rate", SAMPLE_RATE))
        self.n_mels = int(pre["features"])
        self.n_fft = int(pre.get("n_fft", self.sample_rate // 40))
        self.win_length = int(pre.get("win_length", self.sample_rate // 40))
        self.hop_length = int(pre.get("hop_length", self.sample_rate // 100))
        self.center = bool(pre.get("center", True))

        # окно Ханна, периодическое — так его строит torch.hann_window
        n = np.arange(self.win_length)
        self.window = (0.5 - 0.5 * np.cos(2.0 * np.pi * n / self.win_length)).astype(np.float32)

        self.fb = _mel_filterbank(
            n_freqs=self.n_fft // 2 + 1,
            f_min=0.0,
            f_max=self.sample_rate / 2.0,
            n_mels=self.n_mels,
            sample_rate=self.sample_rate,
        ).astype(np.float32)

    def out_len(self, n_samples: int) -> int:
        """Сколько кадров получится — та же формула, что в оригинале."""
        if self.center:
            return n_samples // self.hop_length + 1
        return (n_samples - self.win_length) // self.hop_length + 1

    def __call__(self, wav: np.ndarray) -> np.ndarray:
        """Волна [samples] → признаки [1, n_mels, кадры], float32."""
        # Считаем в float32 — той же точности, в которой модель обучали.
        # Двойная точность даёт чуть другие числа в тихих полосах, а после
        # логарифма этого хватает, чтобы изредка перевернуть выбор буквы.
        x = np.asarray(wav, dtype=np.float32)
        if self.center:
            pad = self.n_fft // 2
            x = np.pad(x, (pad, pad), mode="reflect")

        n_frames = max(0, (len(x) - self.n_fft) // self.hop_length + 1)
        idx = np.arange(self.n_fft)[np.newaxis, :] + \
            self.hop_length * np.arange(n_frames)[:, np.newaxis]
        frames = (x[idx] * self.window[np.newaxis, :]).astype(np.float32)  # [кадры, n_fft]

        spec = (np.abs(np.fft.rfft(frames, n=self.n_fft, axis=1)) ** 2).astype(np.float32)
        mel = spec @ self.fb                               # [кадры, n_mels]
        mel = np.log(np.clip(mel, 1e-9, 1e9))
        return mel.T[np.newaxis, :, :].astype(np.float32)  # [1, n_mels, кадры]


# ─────────────────────────── работа с файлами ───────────────────────────

def ffmpeg(*args) -> None:
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def duration(path: str) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", path],
        capture_output=True, text=True, check=True,
    )
    return float(out.stdout.strip())


def find_silences(path: str) -> list:
    """Середины пауз — кандидаты в точки разреза."""
    out = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", path, "-af",
         f"silencedetect=noise={SILENCE_DB}dB:d={SILENCE_MIN}", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    points, start = [], None
    for line in out.stderr.splitlines():
        if "silence_start:" in line:
            start = float(line.split("silence_start:")[1].strip())
        elif "silence_end:" in line and start is not None:
            end = float(line.split("silence_end:")[1].split("|")[0].strip())
            points.append((start + end) / 2)
            start = None
    return points


def chunk_bounds(total: float, silences: list) -> list:
    """Куски не длиннее предела, разрез — по последней паузе перед ним."""
    bounds, pos = [], 0.0
    while total - pos > MAX_CHUNK:
        candidates = [s for s in silences if pos + 3 < s <= pos + MAX_CHUNK]
        cut = candidates[-1] if candidates else pos + MAX_CHUNK
        bounds.append((pos, cut))
        pos = cut
    bounds.append((pos, total))
    return bounds


def read_wav(path: str) -> np.ndarray:
    """Читает 16-битный моно wav своими силами — без лишних зависимостей."""
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2 or w.getnchannels() != 1:
            raise ValueError(f"ожидался 16-битный моно wav: {path}")
        data = w.readframes(w.getnframes())
    return np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0


# ─────────────────────────── сам движок ───────────────────────────

def find_model_dir(extra: str = "") -> str:
    """Ищет папку с моделью: явно указанная → переменная среды → обычные места."""
    # Сначала явно указанная, потом своя — та, что лежит рядом с кодом,
    # потом уже чужие места. Иначе установка тянула бы модель от соседа
    # и переставала работать, стоит тому съехать.
    candidates = [
        extra,
        os.environ.get("PISAR_MODEL_DIR", ""),
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "model"),
        "/opt/gigaam/onnx_int8",
        os.path.expanduser("~/projects/gigaam-cli/onnx_int8"),
    ]
    for path in candidates:
        if path and os.path.exists(os.path.join(path, f"{MODEL_NAME}.yaml")):
            return path
    raise FileNotFoundError(
        "Не нашёл модель. Укажите папку через PISAR_MODEL_DIR или --model-dir.\n"
        "Скачать: https://github.com/moznoazachem/giga-pisar-cli/releases"
    )


class Engine:
    """Загруженная модель. Создаётся один раз, потом зовите transcribe()."""

    def __init__(self, model_dir: str = "", threads: int = 0):
        import onnxruntime as rt
        import yaml
        from sentencepiece import SentencePieceProcessor

        self.model_dir = find_model_dir(model_dir)
        with open(os.path.join(self.model_dir, f"{MODEL_NAME}.yaml"), encoding="utf-8") as f:
            cfg = yaml.safe_load(f)
        self.cfg = cfg

        opts = rt.SessionOptions()
        opts.graph_optimization_level = rt.GraphOptimizationLevel.ORT_ENABLE_ALL
        opts.intra_op_num_threads = threads or min(8, os.cpu_count() or 4)
        opts.execution_mode = rt.ExecutionMode.ORT_SEQUENTIAL
        opts.log_severity_level = 3

        def sess(suffix):
            path = os.path.join(self.model_dir, f"{MODEL_NAME}_{suffix}.onnx")
            return rt.InferenceSession(path, providers=["CPUExecutionProvider"], sess_options=opts)

        self.enc, self.pred, self.joint = sess("encoder"), sess("decoder"), sess("joint")

        # Токенизатор ищем рядом с моделью. В yaml прописан абсолютный путь
        # с машины, где делали экспорт, — на чужой машине он не существует.
        tok = os.path.join(self.model_dir, f"{MODEL_NAME}_tokenizer.model")
        if not os.path.exists(tok):
            tok = cfg.get("decoding", {}).get("model_path", "")
        if not tok or not os.path.exists(tok):
            raise FileNotFoundError(f"не нашёл токенизатор рядом с моделью: {self.model_dir}")
        self.sp = SentencePieceProcessor()
        self.sp.load(tok)

        self.blank_id = len(self.sp)
        self.pred_hidden = int(cfg["head"]["decoder"]["pred_hidden"])
        self.pred_layers = int(cfg["head"]["decoder"]["pred_rnn_layers"])
        self.features = Features(cfg)

    # ── распознавание одной волны (не длиннее предела модели)
    def transcribe_wave(self, wav: np.ndarray) -> str:
        feats = self.features(wav)
        lens = np.array([self.features.out_len(len(wav))], dtype=np.int64)

        enc_out = self.enc.run(
            [n.name for n in self.enc.get_outputs()],
            {n.name: v for n, v in zip(self.enc.get_inputs(), [feats, lens])},
        )
        enc_features, enc_len = enc_out[0], int(np.asarray(enc_out[1]).reshape(-1)[0])
        return self.sp.decode(self._decode_rnnt(enc_features, enc_len))

    def _decode_rnnt(self, enc_features: np.ndarray, enc_len: int) -> list:
        """Жадное декодирование RNN-T для одной записи."""
        dtype = np.float32
        enc_features = np.asarray(enc_features, dtype=dtype, order="C")

        pred_names = [n.name for n in self.pred.get_outputs()]
        joint_names = [n.name for n in self.joint.get_outputs()]
        pred_in = [n.name for n in self.pred.get_inputs()]
        joint_in = [n.name for n in self.joint.get_inputs()]

        hyp = []
        label = np.array([[self.blank_id]], dtype=np.int64)
        h = np.zeros((self.pred_layers, 1, self.pred_hidden), dtype=dtype)
        c = np.zeros((self.pred_layers, 1, self.pred_hidden), dtype=dtype)
        started = False   # до первой буквы состояние декодера — нулевое

        total = enc_features.shape[2]
        for t in range(min(enc_len, total)):
            f = enc_features[:, :, t:t + 1]
            for _ in range(MAX_SYMBOLS_PER_FRAME):
                if started:
                    args = [label, h, c]
                else:
                    args = [np.array([[self.blank_id]], dtype=np.int64),
                            np.zeros_like(h), np.zeros_like(c)]

                g, h_new, c_new = self.pred.run(pred_names, dict(zip(pred_in, args)))
                out = self.joint.run(joint_names, dict(zip(joint_in, [f, g.swapaxes(1, 2)])))
                k = int(out[0][:, 0, 0, :].argmax(axis=-1)[0])

                if k == self.blank_id:
                    break
                hyp.append(k)
                label = np.array([[k]], dtype=np.int64)
                h, c, started = h_new, c_new, True
        return hyp

    # ── распознавание файла любого формата, с нарезкой длинных
    def transcribe(self, path: str) -> str:
        with tempfile.TemporaryDirectory() as tmp:
            wav = os.path.join(tmp, "in.wav")
            ffmpeg("-i", path, "-ac", "1", "-ar", str(SAMPLE_RATE), wav)

            total = duration(wav)
            if total <= MAX_CHUNK + 1:
                parts = [wav]
            else:
                parts = []
                for i, (a, b) in enumerate(chunk_bounds(total, find_silences(wav))):
                    part = os.path.join(tmp, f"part{i}.wav")
                    ffmpeg("-i", wav, "-ss", str(a), "-to", str(b), part)
                    parts.append(part)

            texts = [self.transcribe_wave(read_wav(p)) for p in parts]
        return " ".join(t for t in texts if t).strip()
