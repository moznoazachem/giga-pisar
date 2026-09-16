#!/bin/zsh
# Образ .dmg для раздачи: открыл, перетащил значок в Программы, готово.
#   ./dmg.sh                       из build/Giga Pisar.app → build/GigaPisar.dmg
#   ./dmg.sh "путь/Giga Pisar.app" [выход.dmg]
# Имя файла нарочно без номера версии: на сайте кнопка ведёт на
# releases/latest/download/GigaPisar.dmg, и ссылка живёт вечно.
# Приложение должно быть уже подписано и нотаризовано (со stapler).
# Сам образ после сборки подписывается; нотаризовать его — отдельно:
#   xcrun notarytool submit build/GigaPisar.dmg --wait --keychain-profile giga-notary
#   xcrun stapler staple build/GigaPisar.dmg
set -e
cd "$(dirname "$0")"

APP="${1:-build/Giga Pisar.app}"
OUT="${2:-build/GigaPisar.dmg}"
VOL="Гига Писарь"
TMP="build/dmg-tmp"
RW="build/dmg-rw.dmg"

[ -d "$APP" ] || { echo "нет приложения: $APP"; exit 1; }

# Фон: dmg/bg.svg → dmg/bg.png (1320×800 при 144 dpi = 660×400 пунктов, чётко на ретине).
# Готовый png лежит в репозитории; перерисовываем, только если svg свежее.
if [ dmg/bg.svg -nt dmg/bg.png ] && command -v rsvg-convert >/dev/null; then
    rsvg-convert -w 1320 -h 800 dmg/bg.svg -o dmg/bg.png
    sips -s dpiWidth 144 -s dpiHeight 144 dmg/bg.png >/dev/null
fi

echo "── содержимое образа"
rm -rf "$TMP" "$RW"
mkdir -p "$TMP/.background"
ditto "$APP" "$TMP/Giga Pisar.app"
xattr -crs "$TMP/Giga Pisar.app"          # мусор ._* ломает подпись у чужих распаковщиков
ln -s /Applications "$TMP/Applications"
cp dmg/bg.png "$TMP/.background/bg.png"

echo "── временный образ"
hdiutil create -srcfolder "$TMP" -volname "$VOL" -fs HFS+ -format UDRW -size 300m -ov -quiet "$RW"
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -oE '/Volumes/.*$')
echo "   смонтирован: $MNT"

echo "── раскладка окна в Finder"
osascript - "$VOL" <<'APPLESCRIPT'
on run argv
  set vol to item 1 of argv
  tell application "Finder"
    tell disk vol
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 860, 520}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 128
      set text size of opts to 13
      set background picture of opts to file ".background:bg.png"
      set position of item "Giga Pisar.app" of container window to {165, 165}
      set position of item "Applications" of container window to {495, 165}
      close
      open
      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
APPLESCRIPT

# Значок тома. Только ПОСЛЕ раскладки: Finder при обновлении окна
# удаляет чужой .VolumeIcon.icns, а hdiutil -srcfolder его вообще не копирует.
# SetFile живёт в Xcode; без него флаг
# «свой значок» пишем руками в FinderInfo корня.
cp icon/Giga.icns "$MNT/.VolumeIcon.icns"
if SETFILE=$(xcrun --find SetFile 2>/dev/null); then
    "$SETFILE" -c icnC "$MNT/.VolumeIcon.icns"
    "$SETFILE" -a C "$MNT"
else
    xattr -wx com.apple.FinderInfo \
      "0000000000000000040000000000000000000000000000000000000000000000" "$MNT"
fi

sync
hdiutil detach "$MNT" -quiet
echo "── сжатие"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -quiet -o "$OUT"
rm -rf "$RW" "$TMP"

if security find-identity -p codesigning -v | grep -q "Developer ID Application"; then
    echo "── подпись образа"
    # метка времени ходит на сервер Apple; если он не ответил, пробуем ещё
    for i in 1 2 3; do
        codesign --force --sign "Developer ID Application" --timestamp "$OUT" && break
        sleep 5
    done
fi
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
