#!/bin/zsh
# Собирает build/kktest — проверочную утилиту казахского ядра.
# Нужен onnxruntime, который качает ./build.sh (vendor/…).
set -e
cd "$(dirname "$0")/.."
ORT_DIR=$(ls -d vendor/onnxruntime-osx-universal2-* | head -1)
[ -d "$ORT_DIR" ] || { echo "нет vendor/onnxruntime — сначала ./build.sh"; exit 1; }
mkdir -p build
swiftc -O -import-objc-header swift/bridge.h \
    -I "$ORT_DIR/include" -L "$ORT_DIR/lib" -lonnxruntime \
    -Xlinker -rpath -Xlinker "$PWD/$ORT_DIR/lib" \
    -o build/kktest \
    scripts/kktest/main.swift swift/Ort.swift swift/Features.swift swift/Tokenizer.swift \
    swift/Recognizer.swift swift/CTC.swift swift/KazakhPunct.swift swift/Audio.swift
echo "✓ build/kktest"
