#!/bin/bash
# Кладёт файлы модели в ~/.giga/model. Больше ничего не нужно:
# распознавание живёт внутри самого приложения — ни питона, ни ffmpeg.
set -e

# Не мак? Значит, человек пришёл по старой ссылке из README консольной версии
# (репозиторий переименован в giga-pisar-cli). Отправляем его к правильному
# установщику, а не кладём ему маковскую модель.
if [ "$(uname -s)" != "Darwin" ]; then
    echo "Это установщик для macOS. Консольная версия для Linux теперь здесь:"
    echo "  https://github.com/moznoazachem/giga-pisar-cli"
    exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/moznoazachem/giga-pisar-cli/main/install.sh)"
fi

MODEL_URL="https://github.com/moznoazachem/giga-pisar-cli/releases/download/v1.0/gigaam-v3-onnx-int8.tar.gz"
DEST=~/.giga/model

echo "== Giga Pisar: модель распознавания =="

if [ -f "$DEST/v3_e2e_rnnt.yaml" ]; then
    echo "Модель уже на месте: $DEST"
else
    echo "Качаю модель (204 МБ архив, 309 МБ на диске)..."
    mkdir -p "$DEST"
    curl -fL --progress-bar "$MODEL_URL" | tar xz -C "$DEST" --strip-components=1
fi

echo ""
echo "✓ Готово. Теперь:"
echo "  1. Перетащи «Giga Pisar.app» в Программы и открой его"
echo "     (если система ругается: System Settings → Privacy & Security → Open Anyway)"
echo "  2. Разреши три доступа, которые он попросит (клавиатура, микрофон, вставка текста)"
echo "  3. Зажми правый ⌘ и говори"
