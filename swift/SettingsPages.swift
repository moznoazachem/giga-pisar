// Страницы настроек: что показывает каждый раздел. Сами настройки живут
// там же, где и раньше (App, Brain, UserDefaults) — здесь только вид.

import AppKit
import ServiceManagement
import SwiftUI

private func sys(_ c: NSColor) -> Color { Color(nsColor: c) }

// MARK: основные

struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let app = model.app
        VStack(spacing: 18) {
            SettingsCard {
                SettingsRow(icon: "globe", color: sys(.systemBlue),
                            title: L("Язык приложения", "App Language")) {
                    Picker("", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: "uiLang") ?? "auto" },
                        set: { id in model.act { app.selectLang(id) } })) {
                        Text(L("Как в системе", "Same as System")).tag("auto")
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                    }
                    .labelsHidden().fixedSize()
                }
            }

            SettingsCard {
                SettingsRow(icon: "power", color: sys(.systemGreen),
                            title: L("Запускать при входе в систему", "Open at Login")) {
                    Toggle("", isOn: Binding(get: { SMAppService.mainApp.status == .enabled },
                                             set: { _ in model.act { app.toggleLogin() } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }

            SettingsCard {
                SettingsRow(icon: "lock.shield.fill", color: sys(.systemTeal),
                            title: L("Доступы", "Permissions"),
                            subtitle: L("Микрофон и вставка текста", "Microphone and text insertion")) {
                    Button(L("Открыть…", "Open…")) { app.showPermissions() }
                }
            }
        }
    }
}

// MARK: диктовка

struct DictationPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let app = model.app
        VStack(spacing: 18) {
            // Сцена — отдельной карточкой без заголовка: она не настройка,
            // а картинка к ней.
            SettingsCard {
                // Поля внутри карточки держит сама камера, а не отступ:
                // сцена занимает её целиком, клавиатура в кадре — 88 pt
                // из 120, то есть по 16 сверху и снизу.
                KeyboardView(hotkeyId: currentHotkey().id)
                    .frame(height: 120)
            }

            SettingsGroup(L("Клавиша диктовки", "Dictation Key")) {
                KeyPicker(chosen: currentHotkey().id) { id in
                    model.act { app.selectHotkey(id) }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                if currentHotkey().id == "rctrl" {
                    // Клавиши нет ни на встроенной клавиатуре, ни на Magic
                    // Keyboard без блока цифр — на сцене её и не покажешь.
                    Text(L("Правый ⌃ есть только на широких клавиатурах Apple с блоком цифр.",
                           "A right ⌃ exists only on full-size Apple keyboards with a numeric keypad."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }

            SettingsCard {
                SettingsRow(icon: "textformat.size.smaller", color: sys(.systemBrown),
                            title: L("Упрощать синтаксис", "Simplify Punctuation"),
                            subtitle: L("Если надиктовано одно предложение — вставлять его со строчной буквы и без точки в конце, как реплику в переписке.",
                                        "When the take is a single sentence, insert it in lowercase and without the final period, like a line in a chat.")) {
                    Toggle("", isOn: Binding(get: { model.app.simpleSyntax },
                                             set: { _ in model.act { app.toggleSimpleSyntax() } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                RowDivider()
                SettingsRow(icon: "doc.on.clipboard", color: sys(.systemTeal),
                            title: L("Оставлять надиктованное в буфере", "Keep Dictation on the Clipboard"),
                            subtitle: L("Текст вставляется как обычно и остаётся в буфере обмена. Удобно для виртуальных машин и удалённых рабочих столов: вставить его там через ⌘V.",
                                        "The text is inserted as usual and stays on the clipboard. Handy for virtual machines and remote desktops: paste it there with ⌘V.")) {
                    Toggle("", isOn: Binding(get: { model.app.keepOnClipboard },
                                             set: { _ in model.act { app.toggleKeepOnClipboard() } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                RowDivider()
                SettingsRow(icon: "music.note.slash", color: sys(.systemRed),
                            title: L("Приглушать звук во время диктовки", "Mute Sound While Dictating"),
                            subtitle: L("Громкость вернётся сама, как только отпустишь клавишу.",
                                        "The volume comes back as soon as you release the key.")) {
                    Toggle("", isOn: Binding(get: { Sound.muteWhileDictating },
                                             set: { _ in model.act { app.toggleHush() } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
        }
    }
}

// MARK: волна голоса

struct WavePage: View {
    @ObservedObject var model: SettingsModel

    /// Куда вернуться, когда волну включают обратно.
    @AppStorage("waveLastChoice") private var lastChoice = "cursor"

    var body: some View {
        let app = model.app
        let on = app.waveChoice != "off"
        VStack(spacing: 18) {
            SettingsCard {
                SettingsRow(icon: "waveform", color: sys(.systemIndigo),
                            title: L("Волна голоса", "Voice Wave"),
                            subtitle: L("Полоска со столбиками скачет в такт голосу: видно, что Писарь слышит.",
                                        "A bar of columns jumps along with your voice, so you can see that Pisar hears you.")) {
                    Toggle("", isOn: Binding(get: { on }, set: { want in
                        guard want != on else { return }
                        model.act { app.selectWave(want ? lastChoice : "off") }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }

            if on {
                SettingsCard {
                    WavePicker(choice: app.waveChoice) { id in
                        lastChoice = id
                        model.act { app.selectWave(id) }
                    }
                    .padding(16)
                }

            }
        }
    }
}

// MARK: мозг

struct BrainPage: View {
    @ObservedObject var model: SettingsModel

    /// Куда вернуться, когда Мозг включают обратно.
    @AppStorage("brainLastChoice") private var lastChoice = "qwen"

    var body: some View {
        let app = model.app
        let b = Brain.shared
        let on = b.chosenId != nil
        VStack(spacing: 18) {
            SettingsCard {
                SettingsRow(icon: "brain.head.profile", color: sys(.systemPurple),
                            title: L("Мозг", "The Brain"),
                            subtitle: L("Нейросеть правит надиктованное по команде «Писарь, …». Без обращения текст вставляется сразу.",
                                        "An AI model edits the dictation on a “Pisar, …” command. Without the address the text goes in at once.")) {
                    Toggle("", isOn: Binding(get: { on }, set: { want in
                        // Свитч иногда пишет в привязку то же значение, что
                        // и читает; без этой проверки такой «пустой» вызов
                        // сбрасывал выбор на запомненный.
                        guard want != on else { return }
                        model.act { app.chooseBrain(want ? lastChoice : "off") }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }

            if on {
                SettingsGroup(L("Где думает", "Runs On")) {
                    Button(L("Как пользоваться…", "How to Use It…")) { app.showBrainHelp() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                } content: {
                    BrainPicker(chosen: b.chosenId ?? "") { id in
                        lastChoice = id
                        model.act { app.chooseBrain(id) }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    Divider().padding(.horizontal, 16)
                    Text(BrainAdvice.describe(b.chosenId ?? "off"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }

                if let m = b.chosenModel, !b.downloaded(m) {
                    let loading = b.downloadingId == m.id
                    SettingsCard {
                        SettingsRow(icon: "arrow.down.circle.fill", color: sys(.systemBlue),
                                    title: L("\(m.name) ещё не скачана", "\(m.name) is not downloaded yet"),
                                    subtitle: L("Весит \(m.sizeText). Пока её нет, Мозг не работает.",
                                                "It weighs \(m.sizeText). Until it is here the Brain does nothing.")) {
                            if loading {
                                Button(L("Стоп", "Stop")) { model.act { b.cancelDownload() } }
                            } else {
                                Button(L("Скачать", "Download")) { model.act { app.downloadBrain(m.id) } }
                            }
                        }
                        if loading {
                            RowDivider()
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: Double(b.downloadPercent), total: 100)
                                HStack {
                                    Text(progressText(b))
                                    Spacer(minLength: 12)
                                    Text("\(b.downloadPercent)%")
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            }
                            // Ровно под названием строки: 16 отступа
                            // карточки + значок 22 + просвет 11.
                            .padding(.leading, 49)
                            .padding(.trailing, 16)
                            .padding(.vertical, 10)
                        }
                    }
                }

                if b.usesServer {
                    CloudBrainView(state: model.cloud)
                }

                // Пока модели нет на диске (или облако не настроено),
                // этим настройкам нечем управлять — не показываем их
                // вовсе, вместо ряда серых строк.
                if b.ready {
                    SettingsCard {
                        SettingsRow(icon: "wand.and.stars", color: sys(.systemPink),
                                    title: L("Править на лету", "Edit on the Fly"),
                                    subtitle: L("Нейросеть причёсывает каждую диктовку сама, без команды «Писарь, …»",
                                                "The model tidies every take by itself, no “Pisar, …” needed")) {
                            Toggle("", isOn: Binding(get: { b.everyTake },
                                                     set: { _ in model.act { app.toggleEveryTake() } }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        RowDivider()
                        SettingsRow(icon: "text.cursor", color: sys(.systemOrange),
                                    title: L("Править выделенный текст", "Edit Selected Text"),
                                    subtitle: L("Выдели текст в любой программе, зажми клавишу и скажи, что с ним сделать: «сделай короче», «переведи на английский». ⌘Z вернёт как было.",
                                                "Select text in any app, hold the key and say what to do with it: “make it shorter”, “translate to English”. ⌘Z brings it back.")) {
                            Toggle("", isOn: Binding(get: { b.onSelection },
                                                     set: { _ in model.act { app.toggleEditSelection() } }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        RowDivider()
                        SettingsRow(icon: "ellipsis.bubble.fill", color: sys(.systemBlue),
                                    title: L("Команды", "Commands"),
                                    subtitle: L("Как просить правку: кнопками в менюшке, которая всплывает после вставки, или голосом — «…Писарь, исправь».",
                                                "How to ask for an edit: buttons in a menu that pops up after the paste, or by voice — “…Pisar, fix this”.")) {
                            Picker("", selection: Binding(get: { b.chipsEnabled },
                                                          set: { on in model.act { app.setChipsMenu(on) } })) {
                                Text(L("Менюшка у курсора", "A Menu at the Cursor")).tag(true)
                                Text(L("Только голосом", "Voice Only")).tag(false)
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
            }

            // Освободить место: модели весят гигабайтами, а удалить
            // скачанную больше негде. Секция внизу и не зависит от того,
            // включён ли Мозг: место занято в любом случае.
            let onDisk = BRAIN_MODELS.filter { b.downloaded($0) }
            if !onDisk.isEmpty {
                SettingsGroup(L("Место на диске", "Disk Space")) {
                    ForEach(Array(onDisk.enumerated()), id: \.element.id) { pair in
                        if pair.offset > 0 { RowDivider() }
                        SettingsRow(icon: "internaldrive.fill", color: sys(.systemGray),
                                    title: pair.element.name,
                                    subtitle: L("Занимает \(sizeText(b, pair.element)) на диске.",
                                                "Takes \(sizeText(b, pair.element)) on disk.")) {
                            Button(L("Удалить…", "Delete…")) {
                                model.act { app.deleteBrainModel(pair.element.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sizeText(_ b: Brain, _ m: BrainModel) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: b.fileSize(m))
    }

    /// «2,1 из 6,5 ГБ» — понятнее голых процентов.
    private func progressText(_ b: Brain) -> String {
        guard b.downloadTotalBytes > 0 else { return L("Считаю размер…", "Sizing it up…") }
        let f = ByteCountFormatter()
        f.countStyle = .file
        let done = f.string(fromByteCount: b.downloadedBytes)
        let total = f.string(fromByteCount: b.downloadTotalBytes)
        return L("\(done) из \(total)", "\(done) of \(total)")
    }
}

/// Где думает Мозг — картинками, как выбор клавиши: значки моделей
/// узнаются быстрее, чем их названия.
struct BrainPicker: View {
    let chosen: String
    let pick: (String) -> Void

    private static let places: [(id: String, asset: String, width: CGFloat, height: CGFloat)] = [
        ("gigachat", "brain-gigachat", 48, 48),
        ("qwen", "brain-qwen", 49, 48),
        (BrainServer.id, "brain-cloud", 63, 42),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Self.places, id: \.id) { place in
                let on = place.id == chosen
                VStack(spacing: 6) {
                    Image(place.asset)
                        .resizable()
                        .frame(width: place.width, height: place.height)
                        .frame(height: 48)
                    Image(systemName: on ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    Text(title(place.id))
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { pick(place.id) }
            }
        }
    }

    private func title(_ id: String) -> String {
        if id == BrainServer.id { return L("В облаке", "In the Cloud") }
        return BRAIN_MODELS.first { $0.id == id }?.name ?? id
    }
}

// MARK: о программе

struct AboutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let app = model.app
        VStack(spacing: 18) {
            SettingsCard {
                SettingsRow(icon: "app.badge.fill", color: sys(.systemBlue),
                            title: L("Гига Писарь \(APP_VERSION)", "Giga Pisar \(APP_VERSION)"),
                            subtitle: updateNote) {
                    if SelfUpdate.inProgress, let v = SelfUpdate.version {
                        Text(L("Качаю \(v)…", "Downloading \(v)…")).foregroundStyle(.secondary)
                    } else if let v = app.updateAvailable {
                        Button(L("Обновить до \(v)", "Update to \(v)")) { app.startSelfUpdate() }
                    } else {
                        Button(L("Проверить", "Check")) { app.checkUpdatesManual() }
                    }
                }
                RowDivider()
                SettingsRow(icon: "square.and.arrow.up.fill", color: sys(.systemGreen),
                            title: L("Рассказать другу", "Tell a Friend")) {
                    Button(L("Поделиться…", "Share…")) { app.shareApp() }
                }
            }

            SettingsCard {
                SettingsRow(icon: "safari.fill", color: sys(.systemBlue),
                            title: "gigapisar.github.io") {
                    Button(L("Открыть", "Open")) {
                        NSWorkspace.shared.open(URL(string: "https://gigapisar.github.io")!)
                    }
                }
                RowDivider()
                SettingsRow(icon: "chevron.left.forwardslash.chevron.right", color: sys(.systemGray),
                            title: L("Исходный код", "Source Code")) {
                    Button(L("Открыть", "Open")) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/moznoazachem/giga-pisar")!)
                    }
                }
            }
        }
    }

    private var updateNote: String {
        if let v = model.app.updateAvailable {
            return L("Доступна версия \(v)", "Version \(v) is available")
        }
        return L("Обновления проверяются сами раз в несколько часов",
                 "Updates are checked automatically every few hours")
    }
}


/// Где показывать волну — картинками, как выбор оформления в системных
/// настройках: словами это место на экране не объяснишь. Картинки идут
/// под названием во всю ширину карточки — так они крупнее и видно, что
/// на них нарисовано.
struct WavePicker: View {
    let choice: String
    let pick: (String) -> Void

    private static let options = [
        ("cursor", "wave-cursor"), ("bottom", "wave-bottom"),
    ]

    var body: some View {
        // Ширину делят поровну три колонки, картинка занимает свою целиком —
        // просветы между ними тянутся сами, под ширину окна.
        HStack(alignment: .top, spacing: 12) {
            ForEach(Self.options, id: \.0) { id, asset in
                let chosen = id == choice
                VStack(spacing: 6) {
                    // Свой размер, один к одному: картинки нарисованы
                    // под @2x (368×238 точек = 184×119 пунктов), и любое
                    // растягивание тут же видно мылом.
                    Image(asset)
                        .resizable()
                        .frame(width: 184, height: 119)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    // Выбор показывает радиокнопка под картинкой: обводка
                    // спорила бы с тем, что на картинке нарисовано.
                    Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                    Text(title(id))
                        .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Color.primary : Color.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { pick(id) }
            }
        }
        .padding(.top, 4)
    }

    private func title(_ id: String) -> String {
        id == "bottom" ? L("Внизу экрана", "Bottom of Screen") : L("У курсора", "Near Cursor")
    }
}


/// Какой клавишей диктовать — картинками самих клавиш: так видно, что
/// нажимать, не разбирая значки ⌘ и ⌥ в строке списка.
struct KeyPicker: View {
    let chosen: String
    let pick: (String) -> Void

    /// Ширина в пунктах у каждой: ⌘ шире остальных, как на клавиатуре.
    /// Fn крайняя слева — как и на самой клавиатуре.
    private static let keys: [(id: String, asset: String, width: CGFloat)] = [
        ("fn", "key-fn", 58), ("rcmd", "key-cmd", 75), ("ropt", "key-option", 58),
    ]
    private static let apart = (id: "rctrl", asset: "key-control", width: CGFloat(58))

    var body: some View {
        // Ряд читается как нижний ряд клавиатуры: Fn, пробел, правые
        // модификаторы — в том же порядке и с теми же просветами.
        HStack(alignment: .top, spacing: 8) {
            choice(Self.keys[0])
            // Пробел рисуем сами и тянем по остатку ширины: картинкой он
            // задавал ряду минимальную ширину, и раздел «Диктовка» из-за
            // этого был шире прочих. Выбрать пробел нельзя, он тут только
            // чтобы ряд читался как ряд клавиатуры.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                .frame(minWidth: 40, maxWidth: .infinity)
                .frame(height: 55)
            choice(Self.keys[1])
            choice(Self.keys[2])
            // Правого ⌃ на клавиатурах Apple нет — он тут для сторонних,
            // поэтому стоит за чертой, отдельно от остальных.
            Divider().frame(height: 57)
            choice(Self.apart)
        }
    }

    private func choice(_ key: (id: String, asset: String, width: CGFloat)) -> some View {
        let on = key.id == chosen
        return VStack(spacing: 6) {
            Image(key.asset)
                .resizable()
                .frame(width: key.width, height: 57)
            Image(systemName: on ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
            Text(title(key.id))
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: key.width)
        .contentShape(Rectangle())
        .onTapGesture { pick(key.id) }
    }

    /// Значок клавиши и так нарисован на картинке, поэтому в подписи
    /// оставляем только название: «Fn», а не «Fn (🌐)».
    private func title(_ id: String) -> String {
        let full = HOTKEYS.first { $0.id == id }?.title ?? id
        guard let bracket = full.firstIndex(of: "(") else { return full }
        return String(full[full.startIndex..<bracket]).trimmingCharacters(in: .whitespaces)
    }
}
