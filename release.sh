#!/bin/zsh
# Выпуск: сборка → zip → нотаризация → печать → zip заново → проверки →
# образ dmg → нотаризация образа → печать → стейпленная копия в Программы.
#   ./release.sh            версия берётся из Info.plist
# Дальше руками (или по подсказке в конце): тег, GitHub-релиз с zip, dmg
# и тарболом модели, GitFlic-релиз, update.json.
set -e
cd "$(dirname "$0")"

VER=$(defaults read "$PWD/Info.plist" CFBundleShortVersionString)
STAGE="build/stage"
APP="$STAGE/Giga Pisar.app"
ZIP="build/GigaPisar-$VER.zip"
PROFILE="giga-notary"   # xcrun notarytool store-credentials giga-notary

pack() {   # стейдж → zip без AppleDouble (иначе чужие распаковщики дают «damaged»)
    xattr -crs "$APP"                        # -s: у симлинков в Frameworks свой xattr
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    local junk; junk=$(unzip -l "$ZIP" | grep -c '/\._' || true)
    [ "$junk" = "0" ] || { echo "в zip мусор ._* ($junk)"; exit 1; }
}

echo "━━ 1/6 сборка $VER"
./build.sh
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "build/Giga Pisar.app" "$APP"

echo "━━ 2/6 нотаризация приложения"
pack
xcrun notarytool submit "$ZIP" --wait --keychain-profile "$PROFILE" | tail -3
xcrun stapler staple "$APP" | tail -1
pack                                          # уже с печатью внутри

echo "━━ 3/6 проверка враждебным распаковщиком"
rm -rf build/hostile; mkdir build/hostile
( cd build/hostile && unzip -q "../../$ZIP" )
spctl -a -vv "build/hostile/Giga Pisar.app" 2>&1 | head -2
rm -rf build/hostile

echo "━━ 4/6 образ dmg"
./dmg.sh "$APP" build/GigaPisar.dmg
xcrun notarytool submit build/GigaPisar.dmg --wait --keychain-profile "$PROFILE" | tail -2
xcrun stapler staple build/GigaPisar.dmg | tail -1
spctl -a -vv -t open --context context:primary-signature build/GigaPisar.dmg 2>&1 | head -1

echo "━━ 5/6 стейпленная копия в Программы"
osascript -e 'quit app "Giga Pisar"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/Giga Pisar.app"
ditto "$APP" "/Applications/Giga Pisar.app"
open "/Applications/Giga Pisar.app"

echo "━━ 6/6 готово"
ls -la "$ZIP" build/GigaPisar.dmg
cat <<TXT

Дальше:
  git tag v$VER && git push origin main --tags && git push gitflic main --tags && git push sourcecraft main --tags
  gh release create v$VER "$ZIP" build/GigaPisar.dmg <тарбол модели> --title "$VER" --notes-file <заметки>
  GitFlic: релиз через API, файл zip, ссылку в update.json (version, downloads), коммит и пуш в три remote.
TXT
