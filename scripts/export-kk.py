#!/usr/bin/env python
"""Экспорт казахской модели для Гига Писаря: GigaAM multilingual_ctc → ONNX int8.

    pip install gigaam torch onnx onnxruntime pyyaml   # torch ≥ 2.6, CPU хватает
    python scripts/export-kk.py multilingual_ctc.ckpt  [папка-результата]

Чекпоинт: https://cdn.chatwm.opensmodel.sberdevices.ru/GigaAM/multilingual_ctc.ckpt
(883 МБ, md5 5379d887c53ccd9cb95981e2a1832720).

Веса грузятся через mmap, а энкодер строится на meta-устройстве, поэтому
экспорт укладывается в ~3 ГБ памяти. Результат: папка с тремя файлами
и архив для релиза — приложение распаковывает его в ~/.giga/model-kk.
"""
import hashlib
import json
import os
import sys
import tarfile
import warnings

import hydra
import torch
import torch.nn as nn
import yaml
from gigaam.model import GigaAMASR
from omegaconf import OmegaConf
from onnxruntime.quantization import QuantType, quantize_dynamic

NAME = "multilingual_ctc"
MD5 = "5379d887c53ccd9cb95981e2a1832720"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    ckpt = sys.argv[1]
    out = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else "gigaam-multilingual-ctc-onnx-int8")
    warnings.simplefilter("ignore")

    h = hashlib.md5()
    with open(ckpt, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    if h.hexdigest() != MD5:
        sys.exit(f"контрольная сумма не та ({h.hexdigest()}): файл недокачан?")

    ck = torch.load(ckpt, map_location="cpu", weights_only=False, mmap=True)
    cfg = ck["cfg"]
    cfg.encoder.flash_attn = False
    m = GigaAMASR.__new__(GigaAMASR)
    nn.Module.__init__(m)
    m.cfg = cfg
    m.preprocessor = hydra.utils.instantiate(cfg.preprocessor)
    with torch.device("meta"):
        m.encoder = hydra.utils.instantiate(cfg.encoder)
        m.head = hydra.utils.instantiate(cfg.head)
    m.decoding = hydra.utils.instantiate(cfg.decoding)
    m.load_state_dict(ck["state_dict"], strict=True, assign=True)
    m.eval()

    fp32 = out + "-fp32"
    os.makedirs(fp32, exist_ok=True)
    os.makedirs(out, exist_ok=True)
    print("── ONNX fp32")
    with m.encoder.onnx_export_mode():
        m._to_onnx(fp32, dtype=torch.float32)
    print("── int8")
    quantize_dynamic(f"{fp32}/{NAME}.onnx", f"{out}/{NAME}.onnx",
                     weight_type=QuantType.QInt8, op_types_to_quantize=["MatMul"])

    vocab = list(cfg.decoding.vocabulary)
    with open(f"{out}/{NAME}_vocab.json", "w", encoding="utf-8") as f:
        json.dump(vocab, f, ensure_ascii=False)
    small = {"model_name": NAME, "sample_rate": 16000,
             "preprocessor": OmegaConf.to_container(cfg.preprocessor),
             "decoding": {"blank_id": len(vocab)}}
    with open(f"{out}/{NAME}.yaml", "w", encoding="utf-8") as f:
        yaml.safe_dump(small, f, allow_unicode=True, sort_keys=False)

    tar = out + ".tar.gz"
    with tarfile.open(tar, "w:gz") as t:
        t.add(out, arcname=os.path.basename(out))
    print(f"✓ {out}\n✓ {tar} ({os.path.getsize(tar) / 2**20:.0f} МБ)")


if __name__ == "__main__":
    main()
