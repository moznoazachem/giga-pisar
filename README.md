# Giga Pisar

*[English](#english) · [Русский](#русский)*

---

## English

Voice dictation for macOS powered by [GigaAM v3](https://github.com/salute-developers/GigaAM) —
Sber's open SOTA model for Russian speech recognition. More accurate than Whisper on Russian,
adds punctuation and capitalization on its own, and runs **fully on-device** — audio never
leaves your Mac.

**Hold a key → speak → release → punctuated text appears wherever your cursor is.**
In any application.

### What's inside

Recognition runs **inside the app itself**. No Python, no ffmpeg, no Homebrew,
no companion server.

- `main.swift` — the menu bar app: push-to-talk key capture, microphone recording, text insertion
- `swift/` — the recognition core in Swift:
  `Features.swift` (audio → features), `Ort.swift` (model inference),
  `Recognizer.swift` (RNN-T decoding), `Tokenizer.swift` (text assembly),
  `Audio.swift` (wav reading, splitting on pauses)
- `swift/Brain.swift` — the optional brain: a local LLM (bundled llama.cpp)
  polishes dictated text on voice commands like "Писарь, исправь"
- `swift/Chips.swift` — the pop-up menu at the cursor: compose / shorten /
  translate, replaces text in place, with "put it back"
- `vendor/` — onnxruntime and the llama.cpp engine, downloaded by the build script (not in the repo)
- `install.sh` — puts the model files into `~/.giga/model`

The core is a Swift port of `giga_core.py` from
[Giga Pisar for Linux](https://github.com/moznoazachem/giga-pisar-cli).
Both are run on the same recordings by `scripts/сверка-swift.py` and must
produce identical text.

Menu labels follow the system language: Russian system — Russian labels,
anything else — English. Overridable in the menu: Auto / Русский / English.

### Performance

Measured on Apple Silicon:

| What | Time |
|---|---|
| 6-second recording | **0.08 s** |
| 30-second recording (split on pauses) | 0.47 s |
| model load at startup | 0.22 s |

The app weighs 97 MB: 71 is the onnxruntime library (universal, Apple
Silicon and Intel in one file), another 25 is the bundled llama.cpp engine
for the optional brain. The recognition model adds 309 MB. About 450 MB
resident in memory — plus the LLM, but only while it is actually loaded.

### Install

```bash
git clone <this-repo>
cd giga-app
./install.sh          # model into ~/.giga/model (204 MB download)
./build.sh            # builds and installs "Giga Pisar.app" into Applications
open "/Applications/Giga Pisar.app"
```

Building needs Xcode or Command Line Tools. Nothing else.

Or grab the ready-made app from [Releases](../../releases): download, drag to
Applications, open — on first launch it offers to download the speech model
itself (204 MB, once; it survives every update in ~/.giga/model).

You can also build a self-contained app with the model embedded:

```bash
./build.sh --with-model     # ~390 MB, no install.sh needed
```

The app is signed with a Developer ID certificate and **notarized by Apple**
(since 3.3): download, drag to Applications, open. No security warnings,
no extra steps.

### First run

A welcome window walks you through the **two** permissions, with live
checkmarks (also available later via "Permissions…" in the menu):

1. **Microphone** — to record your voice
2. **Accessibility** — to insert text (pressing ⌘V for you)

Enable the "Giga Pisar" toggle in the settings pane that opens — **via the
system prompt, not the "+" button**.

The push-to-talk key needs **no permission at all**: macOS guards the
*content* of what you type, and modifier keys (⌘/⌥/⌃/Fn) aren't content.
The app tracks only those — it cannot see your keystrokes even in principle.
(Versions up to 2.1 asked for Input Monitoring for this; if you granted it
back then, you can safely remove that entry in System Settings.)

If a toggle is on but nothing works, the permissions database has a stale
entry. Reset it:

```bash
tccutil reset Accessibility ru.panda.giga
```

(same for `Microphone`), then let the app request access again.

### Usage

- **Hold right ⌘** (configurable in the menu) → speak → release → text is inserted
- Menu bar icon: waveform — ready; red dancing — recording; dots — transcribing
- Click the icon for: key selection, menu language, launch at login, the brain
- **Wave near cursor** — a small floating pill with an equalizer animation
  appears next to the text caret while you dictate (falls back to the active
  window, then to the mouse pointer, when the app won't reveal its caret).
  Drag it anywhere — it remembers the spot; or toggle it off entirely
- Long dictations are split on pauses between phrases and stitched back together
- The last dictation always stays on the clipboard — paste it again anywhere with ⌘V

### The brain (optional)

Dictation is instant and raw by default. Pick a local LLM in the menu
("Pisar's brain") and it will polish dictated text on demand — strictly
on-device, like everything else:

- **By voice**: end the dictation with a plain-language command —
  *"Писарь, исправь"* (clean it up), *"Писарь, переведи на английский"*,
  *"Гига Писарь, причеши"* — and the processed text is inserted
  instead of the raw one
- **Over selected text**: select any text in any app, hold the dictation
  key and say what to do with it — *"translate to English"*, *"fix the
  typos"*, *"make it shorter"*. The result replaces the selection right
  in place; ⌘Z brings the original back. Not in terminals (there is no
  editable selection there)
- **By menu** (off by default, switch on in the Giga menu): after a raw
  paste a small menu pops up at the cursor
  (1 tidy up · 2 shorten · 3 translate) — pick with a digit,
  arrows or the mouse; the text is replaced right in the field, with
  "put it back" one keypress away. In terminals the menu wears a terminal
  skin and replaces text via backspaces (no ⌘Z there)
- Models download right from the menu: **GigaChat 3.1 Lightning** by Sber
  (6.5 GB, native Russian, Macs with 16 GB RAM) or **Qwen3 4B** (2.5 GB, light)
- The engine is a bundled llama.cpp, Apple Silicon only. The model loads on
  the first command (~10 s, with a status pill at the cursor: "Starting the
  brain…") and unloads after 15 idle minutes — it never hogs RAM for nothing
- If the brain stalls or fails, the raw text is inserted anyway — dictation
  never breaks because of it

### Updates

The menu shows the current version and a "Check for updates…" item. The app
asks GitHub/GitFlic every few hours whether a newer release exists — only the
version number travels over the network. When one is out, click "Update":
the app downloads it (percent in the menu bar), verifies the signature,
replaces itself and relaunches. Nothing is ever installed without the click.

### Limitations

- Built for Russian — **including English words sprinkled into Russian speech**:
  tech terms and brand names come out fine, often in Latin script ("проверь
  pull request на GitHub"). Dictating *entirely* in English doesn't work well:
  you get Latin letters but phonetic spelling ("Hower you today") — use
  Whisper for full English dictation
- Internet is needed once, to download the model; offline after that

### Credits

- [GigaAM](https://github.com/salute-developers/GigaAM) — the recognition model, SberDevices (MIT)
- [Vitaliy Kuzmenko](https://github.com/vitkuzmenko) — the live voice wave (real loudness metering)

### License

MIT

---

## Русский

Диктовка голосом для macOS на модели [GigaAM v3](https://github.com/salute-developers/GigaAM)
от Сбера — открытой SOTA-модели распознавания русской речи. Точнее Whisper на русском,
сама расставляет пунктуацию и заглавные, работает **полностью локально** — звук
не покидает твой компьютер.

**Зажал клавишу → говоришь → отпустил → текст с пунктуацией появился там, где курсор.**
В любом приложении.

### Что внутри

Распознавание работает **внутри самого приложения**. Ни питона, ни ffmpeg,
ни Homebrew, ни какого-либо сервера рядом.

- `main.swift` — приложение в строке меню: перехват клавиши-рации,
  запись с микрофона, вставка текста
- `swift/` — ядро распознавания на Swift:
  `Features.swift` (звук → признаки), `Ort.swift` (запуск модели),
  `Recognizer.swift` (декодирование RNN-T), `Tokenizer.swift` (сборка текста),
  `Audio.swift` (чтение wav, нарезка по паузам)
- `swift/Brain.swift` — мозг по желанию: локальная нейронка (вложенный
  llama.cpp) причёсывает надиктованное по командам вроде «Писарь, исправь»
- `swift/Chips.swift` — менюшка у курсора: собрать мысль / сократить /
  перевести, подмена текста на месте и «вернуть как было»
- `vendor/` — onnxruntime и движок llama.cpp, качаются сборкой сами (в репозиторий не входят)
- `install.sh` — кладёт файлы модели в `~/.giga/model`

Ядро — перенос на Swift питоновского `giga_core.py` из
[Гига Писаря для Linux](https://github.com/moznoazachem/giga-pisar-cli).
Оба гоняются на одних записях скриптом `scripts/сверка-swift.py` и должны
выдавать один и тот же текст.

Надписи в меню подстраиваются под язык системы: русская система — русские,
любая другая — английские. В меню можно и принудительно: Авто / Русский / English.

### Сколько работает

Замеры на Apple Silicon:

| Что | Время |
|---|---|
| запись 6 секунд | **0,08 с** |
| запись 30 секунд (режется по паузам) | 0,47 с |
| загрузка модели при запуске | 0,22 с |

Приложение весит 97 МБ: 71 — библиотека onnxruntime (универсальная, Apple
Silicon и Intel в одном файле), ещё 25 — вложенный движок llama.cpp для
мозга. Модель распознавания — ещё 309 МБ. В памяти держит около 450 МБ,
плюс нейронка мозга — но только пока она реально загружена.

### Установка

```bash
git clone <этот-репозиторий>
cd giga-app
./install.sh          # модель в ~/.giga/model (204 МБ качается)
./build.sh            # собирает и ставит «Giga Pisar.app» в Программы
open "/Applications/Giga Pisar.app"
```

Для сборки нужен Xcode или Command Line Tools. Больше ничего ставить не надо.

Либо возьми готовое приложение из [Releases](../../releases): скачал,
перетащил в Программы, открыл — модель распознавания оно предложит скачать
само (204 МБ, один раз; дальше она живёт в ~/.giga/model и переживает
все обновления).

Можно собрать самодостаточное приложение, с моделью внутри:

```bash
./build.sh --with-model     # получится около 390 МБ, install.sh не нужен
```

Приложение подписано сертификатом Developer ID и **нотаризовано Apple**
(начиная с 3.3): скачал, перетащил в Программы, открыл. Никаких
предупреждений безопасности и лишних шагов.

### Первый запуск

Окно первого запуска проведёт по **двум** разрешениям, с живыми галочками
(потом открывается через «Доступы…» в меню):

1. **Микрофон** — записывать голос
2. **Универсальный доступ** — вставлять текст (нажимать ⌘V за тебя)

Включай тумблер «Giga Pisar» в открывшихся настройках — **через системный запрос,
а не через «+»**.

Клавиша-рация **не требует разрешений вовсе**: macOS охраняет *содержимое*
набора, а модификаторы (⌘/⌥/⌃/Fn) содержимым не считаются. Приложение следит
только за ними — твои нажатия букв оно не видит даже в принципе.
(Версии до 2.1 просили для этого «Мониторинг ввода»; если выдавал его тогда —
можешь спокойно убрать эту строчку в настройках.)

Если тумблер включён, а не работает — в базе разрешений битая запись. Лечится так:

```bash
tccutil reset Accessibility ru.panda.giga
```

(и то же для `Microphone`), после чего дать приложению запросить доступ заново.

### Использование

- **Зажми правый ⌘** (клавиша меняется в меню) → говори → отпусти → текст вставится
- Иконка в строке меню: волна — готова; красная пляшет — запись; точки — распознаёт
- Меню по клику: выбор клавиши, язык меню, автозапуск при входе, мозг
- **Волна у курсора** — во время диктовки рядом с текстовой кареткой появляется
  плашка с анимацией-эквалайзером (если приложение не отдаёт каретку — плашка
  встаёт у низа активного окна, а на крайний случай у мыши). Её можно
  перетащить — место запомнится; а можно выключить совсем
- Длинные диктовки режутся по паузам между фразами и склеиваются
- Последняя диктовка всегда остаётся в буфере обмена — вставляй её ещё раз
  где угодно через ⌘V

### Мозг Писаря (по желанию)

По умолчанию диктовка мгновенная и сырая. Но можно выбрать в меню локальную
нейронку («Мозг Писаря») — и она будет причёсывать надиктованное по твоей
команде. Полностью локально, как и всё остальное:

- **Голосом**: закончи диктовку командой обычными словами —
  *«Писарь, исправь»*, *«Писарь, переведи на английский»*,
  *«Гига Писарь, причеши»* — и вставится уже обработанный
  текст вместо сырого
- **Над выделенным текстом**: выдели любой текст в любом приложении, зажми
  клавишу диктовки и скажи, что с ним сделать: *«переведи на английский»*,
  *«исправь ошибки»*, *«сделай короче»*. Результат встанет на место
  выделенного, ⌘Z вернёт как было. В терминалах не работает (там нет
  редактируемого выделения)
- **Менюшкой** (по умолчанию выключена, включается в меню Гиги): после
  вставки у курсора всплывает меню
  (1 причесать · 2 сократить · 3 перевести) — выбирай цифрой, стрелками
  или мышью; текст подменяется прямо в поле, рядом «вернуть как было».
  В терминалах меню одевается в терминальный костюм, а подмена идёт
  через Backspace (⌘Z там не живёт)
- Модели качаются прямо из меню: **GigaChat 3.1 Lightning** от Сбера
  (6,5 ГБ, родной русский, маки от 16 ГБ памяти) или **Qwen3 4B**
  (2,5 ГБ, лёгкая)
- Движок — вложенный llama.cpp, только Apple Silicon. Нейронка грузится
  при первой команде (~10 с, у курсора статус «Запускаю нейронку…»)
  и выгружается после 15 минут простоя — зря память не ест
- Если мозг завис или упал — вставится сырой текст: диктовка не имеет
  права сломаться из-за него

### Обновления

В меню видна текущая версия и пункт «Проверить обновления…». Раз в несколько
часов приложение спрашивает GitHub/GitFlic, не вышла ли новая версия — по
сети уходит только номер версии. Вышла — жми «Обновить»: скачает (проценты
в строке меню), проверит подпись, подменит себя и перезапустится. Без клика
само ничего не ставит.

### Ограничения

- Заточено под русский — **включая английские слова внутри русской речи**:
  термины и названия распознаются нормально, часто латиницей («проверь
  pull request на GitHub»). А вот диктовать *целиком* по-английски не выйдет:
  буквы будут латинские, но написание фонетическое («Hower you today») —
  для полностью английской диктовки нужен Whisper
- Интернет нужен один раз — скачать модель, дальше офлайн

### Благодарности

- [GigaAM](https://github.com/salute-developers/GigaAM) — модель распознавания, SberDevices (MIT)
- [Виталий Кузьменко](https://github.com/vitkuzmenko) — живая волна от настоящей громкости голоса

### Лицензия

MIT
