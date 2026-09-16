// Гига Писарь — диктовка через GigaAM для macOS.
// Зажми правый ⌘ — говори — отпусти — текст вставится в активное окно.
// Распознавание идёт внутри самого приложения (Recognizer.swift): ни питона,
// ни ffmpeg, ни какого-либо сервера рядом не нужно.

import AVFoundation
import AppKit
import ServiceManagement

// Язык интерфейса берём у системы: русская система — русские надписи,
// любая другая — английские. Имя приложения (Giga Pisar) не переводится.
/// Язык интерфейса: «auto» — как у системы, «ru» / «en» — принудительно.
/// Многие держат мак на английском, а диктуют по-русски — им рычаг.
var uiIsRussian: Bool {
    switch UserDefaults.standard.string(forKey: "uiLang") ?? "auto" {
    case "ru": return true
    case "en": return false
    default: return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru")
    }
}

/// Выбирает надпись по языку системы: L(<по-русски>, <по-английски>).
func L(_ ru: String, _ en: String) -> String { uiIsRussian ? ru : en }

// Где искать файлы модели. Сначала внутри самого приложения — так его можно
// отдать человеку одним куском; потом обычные места на диске.
func findModelDir() -> String? {
    var places: [String] = []
    if let res = Bundle.main.resourcePath { places.append(res + "/model") }
    places.append("\(NSHomeDirectory())/.giga/model")
    for dir in places
    where FileManager.default.fileExists(atPath: "\(dir)/\(Recognizer.modelName).yaml") {
        return dir
    }
    return nil
}
let APP_VERSION = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
let WAV_PATH = NSTemporaryDirectory() + "giga_rec.wav"
let MIN_SECONDS = 0.4

// Клавиши-рации на выбор (модификаторы: у них события flagsChanged)
struct Hotkey {
    let id: String
    let title: String
    let keycode: UInt16
    let flag: NSEvent.ModifierFlags
}

// Вычисляется при каждом обращении: названия следуют за языком меню.
var HOTKEYS: [Hotkey] { [
    Hotkey(id: "rcmd", title: L("Правый ⌘", "Right ⌘"), keycode: 54, flag: .command),
    Hotkey(id: "ropt", title: L("Правый ⌥", "Right ⌥"), keycode: 61, flag: .option),
    Hotkey(id: "rctrl", title: L("Правый ⌃", "Right ⌃"), keycode: 62, flag: .control),
    Hotkey(id: "fn", title: "Fn (🌐)", keycode: 63, flag: .function),
] }

func currentHotkey() -> Hotkey {
    let id = UserDefaults.standard.string(forKey: "hotkey") ?? "rcmd"
    return HOTKEYS.first { $0.id == id } ?? HOTKEYS[0]
}

// MARK: - Иконки (рисуем векторно, template → ЧБ под тему строки меню)

/// Столбики в строке меню. Цвет не задан — шаблонная иконка покоя,
/// чёрно-белая под тему строки меню. Задан — состояние: красный «пишу»,
/// синий «думаю», те же цвета, что у плашки возле курсора.
func barsImage(_ heights: [CGFloat], color: NSColor? = nil) -> NSImage {
    let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
        (color ?? NSColor.black).setFill()
        for (i, h) in heights.enumerated() {
            let r = NSRect(x: 1 + CGFloat(i) * 4.2, y: 9 - h / 2, width: 2.8, height: h)
            NSBezierPath(roundedRect: r, xRadius: 1.3, yRadius: 1.3).fill()
        }
        return true
    }
    img.isTemplate = (color == nil)
    return img
}

/// Красный — идёт запись, синий — Писарь думает. Те же два цвета
/// у столбиков в плашке возле курсора: строка меню и плашка всегда
/// говорят об одном и том же.
let recColor = NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
let busyColor = NSColor.systemBlue

/// Доля высоты у столбиков, пока идёт распознавание, — ровный ряд.
/// Такой же ряд в это время стоит и в плашке.
let BUSY_BAR: CGFloat = 0.35

// MARK: - Приложение

final class App: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let mic = Mic()
    var recStart: Date?
    var rightCmdDown = false
    var cancelled = false
    var animTimer: Timer?

    /// Окно с разрешениями (первый запуск и пункт меню).
    let onboarding = Onboarding()

    /// Модель. Грузится один раз в фоне; recognizer трогаем только из recognizerQueue.
    var recognizer: Recognizer?
    let recognizerQueue = DispatchQueue(label: "ru.panda.giga.recognizer")

    /// Плашка с волной у места набора (выключается в меню).
    let wave = WavePanel.shared
    var waveEnabled: Bool { UserDefaults.standard.object(forKey: "wavePanel") as? Bool ?? true }

    /// Номер свежей версии с зеркал, если она новее нашей, и её ссылки.
    var updateAvailable: String?
    let updateWindow = UpdateWindow()
    weak var updMenuItem: NSMenuItem?   // «Качаю версию…» с живыми процентами
    var updateDownloads: [URL] = []

    /// Последняя удачная диктовка — страховка на случай «курсор был не в поле».
    var lastText: String?

    /// Что лежало в буфере до диктовки. Вставлять можно только через буфер
    /// (иначе ⌘V не нажать), но забирать его насовсем — невежливо: как только
    /// текст встал в поле, возвращаем человеку то, что он копировал сам.
    private var clipboardBefore: [NSPasteboardItem]?

    /// Счётчик изменений буфера сразу после того, как мы положили туда своё.
    /// По нему видно, не копировал ли человек что-то ещё, пока шла вставка.
    private var clipboardMark = 0

    /// Сколько ждать перед возвратом буфера. Приложение читает буфер, разбирая
    /// наше ⌘V, и если вернуть прежнее слишком рано, вставится оно.
    static let clipboardHold: TimeInterval = 0.5

    /// Запомнить буфер перед тем, как класть в него диктовку. Второй раз
    /// за заход не перезапоминаем: беречь надо самое первое, пользовательское.
    func stashClipboard() {
        guard clipboardBefore == nil else { return }
        clipboardBefore = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    /// Вернуть буфер как был — но только если в нём всё ещё наша диктовка:
    /// человек мог за эти полсекунды скопировать что-то своё.
    func restoreClipboard() {
        guard let items = clipboardBefore else { return }
        clipboardBefore = nil
        let pb = NSPasteboard.general
        guard pb.changeCount == clipboardMark else { return }
        pb.clearContents()
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Вставить не вышло — диктовка остаётся в буфере, прежнее забываем.
    func keepClipboard() { clipboardBefore = nil }
    /// Текст, который был выделен в момент нажатия рации. Если он есть и
    /// мозг включён, речь считается командой над ним, а не диктовкой.
    var selectionAtStart: String?
    /// Пока мы сами жмём клавиши (⌘C за пользователя), монитор keyDown
    /// не должен принимать их за «шорткат, отменяем запись».
    var syntheticKeyUntil = Date.distantPast
    /// Шторка «Поделиться» живёт, пока открыта: иначе её отпустит ARC.
    var sharePicker: NSSharingServicePicker?



    func applicationWillTerminate(_ n: Notification) {
        Brain.shared.stopServer()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setState(.idle)
        offerMoveToApplications()
        // после самообновления — подтвердить словами, что всё получилось
        let prevRun = UserDefaults.standard.string(forKey: "lastRunVersion")
        UserDefaults.standard.set(APP_VERSION, forKey: "lastRunVersion")
        if let prevRun, prevRun != APP_VERSION {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Toast.shared.show(L("Гига Писарь обновился до \(APP_VERSION)",
                                    "Giga Pisar updated to \(APP_VERSION)"))
            }
        }
        // В 2.3 волна из-за гонки записывала СВОЁ ЖЕ появление как
        // перетаскивание и намертво прирастала к месту первого показа.
        // Сохранённое место у всех ложное — забываем его один раз.
        if !UserDefaults.standard.bool(forKey: "wavePinBugFixed2") {
            UserDefaults.standard.set(true, forKey: "wavePinBugFixed2")
            WavePanel.pinned = nil
        }
        Brain.shared.onChange = { [weak self] in
            guard let self else { return }
            if let id = Brain.shared.downloadingId,
               let m = BRAIN_MODELS.first(where: { $0.id == id }),
               let item = self.dlMenuItem {
                item.attributedTitle = self.menuAttrTitle(
                    L("\(m.name) — качаю \(Brain.shared.downloadPercent)%",
                      "\(m.name) — Downloading \(Brain.shared.downloadPercent)%"),
                    sub: L("нажми, чтобы отменить", "click to cancel"))
            } else {
                self.buildMenu()
            }
        }
        buildMenu()
        loadModel()
        startKeyMonitors()
        if !Onboarding.allGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.onboarding.show()
            }
        }
        // обновления: раз при запуске (чуть погодя) и дальше каждые 6 часов
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.checkUpdates(silent: true)
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkUpdates(silent: true)
        }
    }

    enum State { case idle, rec, busy }
    var state: State = .idle

    func setState(_ s: State) {
        state = s
        animTimer?.invalidate()
        animTimer = nil
        switch s {
        case .idle:
            statusItem.button?.image = barsImage([5, 9, 13, 9, 5])
            wave.hide()
        case .rec:
            // Столбики показывают настоящую громкость с микрофона: молчишь —
            // лежат, говоришь — пляшут. Волну у курсора и иконку в строке меню
            // кормит один таймер одними и теми же числами, поэтому они всегда
            // об одном и том же звуке.
            statusItem.button?.image = barsImage([3, 3, 3, 3, 3], color: recColor)
            var tick = 0
            // 60 кадров в секунду: микрофон приносит громкость раз в ~85 мс,
            // промежуточные кадры доводят столбики до неё плавно. На 20
            // кадрах движение читалось рывками — «низкий fps».
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.wave.tick(level: CGFloat(self.mic.level))
                tick += 1
                // Иконке в строке меню хватает и 20 кадров: она размером
                // с ноготь, а каждый кадр там — новая картинка.
                // столбики 0…1 → высоты иконки: 3 пункта в тишине, 14 на голосе
                if tick % 3 == 0 {
                    self.statusItem.button?.image = barsImage(self.wave.bars.map { 3 + 11 * $0 },
                                                              color: recColor)
                }
                // окно с кареткой могли передвинуть прямо во время диктовки —
                // раз в полсекунды спрашиваем место заново и едем за ним
                if tick % 30 == 0, self.waveEnabled { self.wave.follow(typingAnchorIfKnown()) }
            }
            // В общих режимах: иначе открытое меню или перетаскивание
            // плашки останавливает волну до конца жеста.
            RunLoop.main.add(t, forMode: .common)
            animTimer = t
        case .busy:
            wave.busy() // плашка на месте, столбики синие: «услышал, распознаю»
            // Иконка говорит ровно то же и тем же цветом: раньше тут бежали
            // точки, и строка меню с плашкой рассказывали разными словами
            // об одном состоянии.
            statusItem.button?.image = barsImage(
                [CGFloat](repeating: 3 + 11 * BUSY_BAR, count: 5), color: busyColor)
        }
    }

    /// Значок для пункта меню: сперва системный символ, а если такого нет —
    /// свой из каталога ассетов (`icon/Assets.xcassets`, build.sh собирает
    /// его в Assets.car). Свои экспортированы из SF Symbols и ведут себя
    /// как системные: шаблонные, тех же весов, с тем же оптическим размером.
    func menuIcon(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(named: name)
        return img?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    }

    /// Компактный пункт меню: иконка, короткое название и, если надо,
    /// пояснение мелким серым текстом второй строкой.
    func mkItem(_ title: String, sub: String? = nil, icon: String? = nil,
                action: Selector? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        if let icon, let img = menuIcon(icon) {
            img.isTemplate = true
            it.image = img
        }
        // все пункты через attributedTitle: так шрифт мельче системного
        it.attributedTitle = menuAttrTitle(title, sub: sub)
        return it
    }

    func menuAttrTitle(_ title: String, sub: String?) -> NSAttributedString {
        let t = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 12),
                         .foregroundColor: NSColor.labelColor])
        if let sub {
            t.append(NSAttributedString(
                string: "\n" + sub,
                attributes: [.font: NSFont.menuFont(ofSize: 10),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return t
    }

    /// Заголовок раздела — своя отрисовка: обычный отключённый пункт мак
    /// рисует полупрозрачным, как «сломанную опцию», а свой вью не трогает.
    func mkHeader(_ title: String, sub: String? = nil) -> NSMenuItem {
        let it = NSMenuItem()
        it.isEnabled = false
        let w: CGFloat = 250
        let t = NSTextField(labelWithString: title)
        t.font = .boldSystemFont(ofSize: 12)
        t.textColor = .labelColor
        t.sizeToFit()
        let v = NSView()
        var h: CGFloat
        if let sub {
            let sv = NSTextField(labelWithString: sub)
            sv.font = .menuFont(ofSize: 10)
            sv.textColor = .secondaryLabelColor
            sv.sizeToFit()
            sv.setFrameOrigin(NSPoint(x: 14, y: 3))
            v.addSubview(sv)
            t.setFrameOrigin(NSPoint(x: 14, y: 4 + sv.frame.height))
            h = t.frame.height + sv.frame.height + 9
        } else {
            t.setFrameOrigin(NSPoint(x: 14, y: 4))
            h = t.frame.height + 8
        }
        v.frame = NSRect(x: 0, y: 0, width: w, height: h)
        v.addSubview(t)
        it.view = v
        return it
    }

    /// Строка «качаю N%» в меню: открытое меню целиком не перестроить,
    /// а заголовок существующего пункта оно перерисовывает вживую.
    weak var dlMenuItem: NSMenuItem?

    func buildMenu() {
        dlMenuItem = nil
        let menu = NSMenu()
        // включённостью пунктов управляем сами: серые должны быть серыми,
        // даже если у них есть подменю
        menu.autoenablesItems = false

        menu.addItem(mkHeader(L("Гига Писарь", "Giga Pisar"),
                              sub: L("зажми \(currentHotkey().title) и говори",
                                     "hold \(currentHotkey().title) and speak")))
        menu.addItem(NSMenuItem.separator())

        // выбор клавиши диктовки
        let keyItem = mkItem(L("Клавиша диктовки", "Dictation Key"), icon: "keyboard")
        let keyMenu = NSMenu()
        for hk in HOTKEYS {
            let item = mkItem(hk.title, action: #selector(pickHotkey(_:)))
            item.representedObject = hk.id
            item.state = (hk.id == currentHotkey().id) ? .on : .off
            keyMenu.addItem(item)
        }
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)

        // плашка с волной: выключена, у места набора или внизу экрана
        let waveItem = mkItem(L("Волна голоса", "Voice Wave"), icon: "waveform")
        let waveMenu = NSMenu()
        let picked = waveEnabled ? WavePanel.place.rawValue : "off"
        for (id, name) in [("off", L("Выключена", "Off")),
                           ("cursor", L("У курсора", "Near Cursor")),
                           ("bottom", L("Внизу экрана", "Bottom of Screen"))] {
            let it = mkItem(name, action: #selector(pickWave(_:)))
            it.representedObject = id
            it.state = picked == id ? .on : .off
            waveMenu.addItem(it)
        }
        waveItem.submenu = waveMenu
        menu.addItem(waveItem)

        // автозапуск при входе
        let login = mkItem(L("Запускать при входе", "Open at Login"),
                           icon: "power", action: #selector(toggleLogin))
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        // язык интерфейса: авто / русский / английский
        let langItem = mkItem(L("Язык меню", "Menu Language"), icon: "globe")
        let langMenu = NSMenu()
        let curLang = UserDefaults.standard.string(forKey: "uiLang") ?? "auto"
        for (code, name) in [("auto", L("Авто (как система)", "Auto (Match System)")),
                             ("ru", "Русский"), ("en", "English")] {
            let it = mkItem(name, action: #selector(pickLang(_:)))
            it.representedObject = code
            it.state = curLang == code ? .on : .off
            langMenu.addItem(it)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // Мозг: локальная нейронка правит текст по команде «Писарь, …»
        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkHeader(L("Мозг Писаря", "Pisar's Brain"),
                              sub: L("причёсывает надиктованный текст", "polishes dictated text")))
        if Brain.shared.engineAvailable {
            let off = mkItem(L("Выключен", "Off"), icon: "circle.slash",
                             action: #selector(pickBrain(_:)))
            off.representedObject = "off"
            off.state = Brain.shared.chosenId == nil ? .on : .off
            menu.addItem(off)
            for m in BRAIN_MODELS {
                let it: NSMenuItem
                if Brain.shared.downloadingId == m.id {
                    it = mkItem(L("\(m.name) — качаю \(Brain.shared.downloadPercent)%",
                                  "\(m.name) — Downloading \(Brain.shared.downloadPercent)%"),
                                sub: L("нажми, чтобы отменить", "click to cancel"),
                                icon: m.icon, action: #selector(pickBrain(_:)))
                    dlMenuItem = it
                } else if !Brain.shared.downloaded(m) {
                    it = mkItem(L("\(m.name) — скачать \(m.sizeText)",
                                  "\(m.name) — Download \(m.sizeText)"),
                                sub: m.details, icon: m.icon,
                                action: #selector(pickBrain(_:)))
                } else {
                    it = mkItem(m.name, sub: m.details, icon: m.icon,
                                action: #selector(pickBrain(_:)))
                    it.state = Brain.shared.chosenId == m.id ? .on : .off
                }
                it.representedObject = m.id
                menu.addItem(it)
            }
            // как звать Писаря: менюшка у курсора или только голосом
            menu.addItem(NSMenuItem.separator())
            let menuMode = mkItem(L("Менюшка после вставки", "Menu After Pasting"),
                                  sub: L("у курсора: 1 причесать · 2 сократить · 3 перевести",
                                         "at the cursor: 1 tidy up · 2 shorten · 3 translate"),
                                  icon: "filemenu.and.selection",
                                  action: #selector(pickChipsMode(_:)))
            menuMode.representedObject = "menu"
            menuMode.state = Brain.shared.chipsEnabled ? .on : .off
            menuMode.isEnabled = Brain.shared.chosenId != nil
            menu.addItem(menuMode)
            let voiceMode = mkItem(L("Только голосом", "Voice Only"),
                                   sub: L("скажи в конце: «Писарь, исправь / переведи…»",
                                          "end with: \u{201C}Pisar, fix this / translate\u{2026}\u{201D}"),
                                   icon: "person.wave.2",
                                   action: #selector(pickChipsMode(_:)))
            voiceMode.representedObject = "voice"
            voiceMode.state = Brain.shared.chipsEnabled ? .off : .on
            voiceMode.isEnabled = Brain.shared.chosenId != nil
            menu.addItem(voiceMode)
        } else {
            let no = mkItem(L("Нужен мак с M-чипом", "Requires Apple Silicon"))
            no.isEnabled = false
            menu.addItem(no)
        }
        menu.addItem(NSMenuItem.separator())

        menu.addItem(mkItem(L("Доступы…", "Permissions…"), icon: "lock.shield",
                            action: #selector(showOnboarding)))
        menu.addItem(NSMenuItem.separator())

        // версия и обновления — одним компактным пунктом
        if SelfUpdate.inProgress, let upd = SelfUpdate.version {
            let item = mkItem(L("Качаю версию \(upd)…", "Downloading version \(upd)…"),
                              sub: L("нажми, чтобы посмотреть ход дела", "click to see progress"),
                              icon: "arrow.down.circle", action: #selector(startSelfUpdate))
            menu.addItem(item)
            updMenuItem = item
        } else if let upd = updateAvailable {
            menu.addItem(mkItem(L("Доступна версия \(upd) — обновить",
                                  "Version \(upd) Available — Update"),
                                icon: "arrow.down.circle", action: #selector(startSelfUpdate)))
        }
        menu.addItem(mkItem(L("Проверить обновления…", "Check for Updates…"),
                            sub: L("сейчас стоит \(APP_VERSION)", "installed: \(APP_VERSION)"),
                            icon: "arrow.triangle.2.circlepath",
                            action: #selector(checkUpdatesManual)))
        menu.addItem(mkItem(L("Рассказать другу…", "Tell a Friend…"),
                            sub: L("ссылка на сайт: Сообщения, Почта, Telegram, AirDrop",
                                   "site link via Messages, Mail, Telegram, AirDrop"),
                            icon: "square.and.arrow.up", action: #selector(shareApp)))

        menu.addItem(NSMenuItem.separator())
        let quit = mkItem(L("Выйти", "Quit"))
        quit.action = #selector(NSApplication.terminate(_:))
        quit.target = nil
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func pickHotkey(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "hotkey")
        buildMenu() // обновить галочки и заголовок
    }

    @objc func showOnboarding() { onboarding.show() }

    /// «Рассказать другу»: родная шторка «Поделиться» с готовым текстом и
    /// ссылкой на сайт. Сайт не меняется от версии к версии, там оба зеркала.
    static let siteURL = URL(string: "https://gigapisar.github.io")!
    @objc func shareApp() {
        let text = L("Гига Писарь: диктовка на маке по правому ⌘, русский распознаёт на ура, всё локально, бесплатно. Скачать: gigapisar.github.io",
                     "Giga Pisar: hold right ⌘ and dictate on your Mac. Russian and English, fully offline, free. Download: gigapisar.github.io")
        let picker = NSSharingServicePicker(items: [text, App.siteURL])
        sharePicker = picker
        NSApp.activate(ignoringOtherApps: true)
        // меню ещё закрывается — даём ему секунду-другую кадров
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc func pickWave(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id != "off", forKey: "wavePanel")
        if let p = WavePanel.Place(rawValue: id) { WavePanel.place = p }
        if !waveEnabled {
            wave.hide()
        } else if state == .rec {
            // выбрали прямо во время диктовки — плашка переезжает сразу
            wave.show(near: typingAnchor())
        }
        buildMenu()
    }

    /// Само: скачает выпуск, проверит подпись, подменит себя и перезапустится.
    @objc func startSelfUpdate() {
        // уже идёт — не запускаем второе, а показываем, как идёт первое
        if SelfUpdate.inProgress, let ver = SelfUpdate.version {
            updateWindow.show(version: ver)
            return
        }
        guard !updateDownloads.isEmpty, let ver = updateAvailable else {
            openReleases() // выпуск без архива — только руками
            return
        }
        updateWindow.onCancel = { [weak self] in
            SelfUpdate.cancel()
            self?.statusItem.button?.title = ""
            self?.buildMenu()
        }
        updateWindow.show(version: ver)
        updateWindow.downloading(percent: 0)
        buildMenu() // пункт «Доступна версия…» превращается в «Качаю…»
        SelfUpdate.run(zips: updateDownloads, version: ver, report: { [weak self] stage in
            guard let self else { return }
            switch stage {
            case .downloading(let p):
                self.updateWindow.downloading(percent: p)
                // и рядом со значком в строке меню, где чёлки нет
                self.statusItem.button?.imagePosition = .imageLeft
                self.statusItem.button?.title = " ↓ \(p)%"
                self.updMenuItem?.attributedTitle = self.menuAttrTitle(
                    L("Качаю версию \(ver)… \(p)%", "Downloading version \(ver)… \(p)%"),
                    sub: L("нажми, чтобы посмотреть ход дела", "click to see progress"))
            case .verifying:
                self.updateWindow.onCancel = nil // дальше отменять нечего
                self.updateWindow.busy(L("Проверяю подпись…", "Verifying the signature…"))
                self.statusItem.button?.title = " " + L("проверяю…", "verifying…")
            }
        }, ready: { [weak self] in
            self?.updateWindow.busy(L("Перезапускаюсь…", "Relaunching…"))
            self?.quitForUpdateWhenIdle()
        }, fail: { [weak self] reason in
            self?.statusItem.button?.title = ""
            self?.updateWindow.hide()
            self?.buildMenu()
            let a = NSAlert()
            a.messageText = L("Обновиться само не получилось", "Self-update didn't work")
            a.informativeText = L("Причина: \(reason).\nМожно скачать вручную со страницы выпуска — это просто замена приложения.",
                                  "Reason: \(reason).\nYou can download it manually from the releases page — it's just replacing the app.")
            a.addButton(withTitle: L("Открыть страницу", "Open the page"))
            a.addButton(withTitle: L("Позже", "Later"))
            if a.runModal() == .alertFirstButtonReturn { self?.openReleases() }
        })
    }

    /// Обновление скачано и проверено; выходим на подмену, но вежливо:
    /// посреди диктовки или распознавания не дёргаемся — ждём покоя.
    func quitForUpdateWhenIdle() {
        guard state == .idle else {
            updateWindow.busy(L("Дождусь конца диктовки и перезапущусь…",
                                "Waiting for the dictation to finish, then relaunching…"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.quitForUpdateWhenIdle()
            }
            return
        }
        NSApp.terminate(nil)
    }

    @objc func openReleases() {
        if let url = URL(string: RELEASES_PAGE) { NSWorkspace.shared.open(url) }
    }

    @objc func checkUpdatesManual() { checkUpdates(silent: false) }

    /// silent — фоновая проверка: молчит, если новостей нет, и об одной и той
    /// же версии напоминает окном только один раз (дальше — пункт в меню).
    func checkUpdates(silent: Bool) {
        // Обновление уже качается: предлагать его ещё раз бессмысленно,
        // вместо этого показываем, как оно идёт.
        if SelfUpdate.inProgress, let ver = SelfUpdate.version {
            if !silent { updateWindow.show(version: ver) }
            return
        }
        fetchLatestRelease { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateDownloads = info?.downloads ?? []
                let latest = info?.version
                guard let latest else {
                    if !silent {
                        let a = NSAlert()
                        a.messageText = L("Не удалось проверить", "Couldn't check")
                        a.informativeText = L("GitHub не ответил. Попробуй позже.",
                                              "GitHub didn't respond. Try again later.")
                        a.runModal()
                    }
                    return
                }
                guard isNewerVersion(latest, than: APP_VERSION) else {
                    if self.updateAvailable != nil {
                        self.updateAvailable = nil
                        self.buildMenu() // убрать устаревшее «доступна версия…»
                    }
                    if !silent {
                        let a = NSAlert()
                        a.messageText = L("У тебя последняя версия", "You're up to date")
                        a.informativeText = L("Версия \(APP_VERSION), новее нет.",
                                              "Version \(APP_VERSION) is the latest.")
                        a.accessoryView = whatsNewView(version: APP_VERSION, notes: WHATS_NEW)
                        a.runModal()
                    }
                    return
                }
                self.updateAvailable = latest
                self.buildMenu()
                let seen = UserDefaults.standard.string(forKey: "lastUpdateNotified")
                if !silent || seen != latest {
                    UserDefaults.standard.set(latest, forKey: "lastUpdateNotified")
                    let a = NSAlert()
                    a.messageText = L("Вышла версия \(latest)", "Version \(latest) is out")
                    a.informativeText = L("У тебя \(APP_VERSION). Приложение скачает выпуск, проверит подпись, поставит и перезапустится само.",
                                          "You have \(APP_VERSION). The app will download the release, verify its signature, install it and relaunch itself.")
                    a.accessoryView = whatsNewView(version: latest, notes: info?.notes ?? [])
                    a.addButton(withTitle: L("Обновить", "Update"))
                    a.addButton(withTitle: L("Позже", "Later"))
                    if a.runModal() == .alertFirstButtonReturn { self.startSelfUpdate() }
                }
            }
        }
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = L("Не получилось изменить автозапуск", "Couldn't change the login setting")
            a.informativeText = L("Добавь вручную: System Settings → General → Login Items. (\(error.localizedDescription))",
                                  "Add it manually: System Settings → General → Login Items. (\(error.localizedDescription))")
            a.runModal()
        }
        buildMenu()
    }

    // MARK: сервер

    func loadModel() {
        guard let dir = findModelDir() else {
            DispatchQueue.main.async { [weak self] in self?.complainNoModel() }
            return
        }
        recognizerQueue.async { [weak self] in
            do {
                self?.recognizer = try Recognizer(modelDir: dir)
            } catch {
                NSLog("Гига Писарь: модель не загрузилась — \(error)")
                DispatchQueue.main.async { self?.complainNoModel() }
            }
        }
    }

    /// Модели нет ни в бандле, ни в ~/.giga/model: так бывает у тонкого
    /// выпуска на свежем маке. Никаких «запусти скрипт» — качаем сами.
    /// Один раз: дальше модель живёт в ~/.giga/model и переживает
    /// любые обновления (swap.sh её ещё и подстраховывает).
    func complainNoModel() {
        let a = NSAlert()
        a.messageText = L("Остался один шаг — модель распознавания",
                          "One last piece — the speech model")
        a.informativeText = L("Это «уши» Писаря: 204 МБ, качается один раз и переживает все обновления. Ход дела будет виден в строке меню.",
                              "Pisar's ears: a one-time 204 MB download that survives every update. Progress shows in the menu bar.")
        a.addButton(withTitle: L("Скачать", "Download"))
        a.addButton(withTitle: L("Позже", "Later"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        downloadSpeechModel()
    }

    var modelDL: Downloader?

    func downloadSpeechModel() {
        guard modelDL == nil else { return }
        let url = URL(string: "https://github.com/moznoazachem/giga-pisar-cli/releases/download/v1.0/gigaam-v3-onnx-int8.tar.gz")!
        statusItem.button?.imagePosition = .imageLeft
        modelDL = Downloader(onPercent: { [weak self] p in
            self?.statusItem.button?.title = " ↓\(p)%"
        }, onDone: { [weak self] file, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.modelDL = nil
                self.statusItem.button?.title = ""
                guard let file else {
                    Toast.shared.show(L("Модель не скачалась (\(error ?? "сеть")) — попробуй позже, окно появится снова при запуске",
                                        "Model download failed (\(error ?? "network")) — try again later, the prompt returns on launch"))
                    return
                }
                self.unpackSpeechModel(file)
            }
        })
        modelDL?.download(url)
    }

    private func unpackSpeechModel(_ file: URL) {
        statusItem.button?.title = " …"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dest = NSHomeDirectory() + "/.giga/model"
            try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["xzf", file.path, "-C", dest, "--strip-components=1"]
            var ok = false
            do {
                try tar.run()
                tar.waitUntilExit()
                ok = tar.terminationStatus == 0 && findModelDir() != nil
            } catch {}
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusItem.button?.title = ""
                if ok {
                    self.loadModel()
                    Toast.shared.show(L("Модель на месте — зажимай \(currentHotkey().title) и диктуй!",
                                        "Model is in — hold \(currentHotkey().title) and dictate!"))
                } else {
                    Toast.shared.show(L("Архив модели не распаковался — попробуй ещё раз",
                                        "Couldn't unpack the model — try again"))
                }
            }
        }
    }

    // MARK: запуск не из «Программ»
    //
    // Приложение, открытое прямо из «Загрузок» или архива, macOS подменяет
    // временной карантинной копией (App Translocation): путь каждый раз
    // другой, и разрешения прилипают не к той копии. Человек видит
    // «тумблер включён, а всё равно ругается». Лечение одно — жить
    // в «Программах», поэтому предлагаем переехать сразу, до онбординга.

    func offerMoveToApplications() {
        let path = Bundle.main.bundlePath
        let dest = "/Applications/Giga Pisar.app"
        guard path != dest else { return }

        let translocated = path.contains("/AppTranslocation/")
        let a = NSAlert()
        a.messageText = L("Перенести Гига Писарь в «Программы»?", "Move Giga Pisar to Applications?")
        a.informativeText = L(
            translocated
                ? "Приложение открыто из временной карантинной копии — так бывает при запуске прямо из «Загрузок». Разрешения macOS прилипают к месту на диске, поэтому будут слетать при каждом запуске. Я перенесу себя в «Программы» и перезапущусь оттуда."
                : "Приложение запущено из «\(path)». Чтобы разрешения не слетали, ему лучше жить в «Программах». Я перенесу себя туда и перезапущусь.",
            translocated
                ? "The app is running from a temporary quarantine copy — that happens when it's launched straight from Downloads. macOS ties permissions to the location on disk, so they'd break on every launch. I'll move myself to Applications and relaunch from there."
                : "The app is running from “\(path)”. To keep permissions stable it should live in Applications. I'll move myself there and relaunch.")
        a.addButton(withTitle: L("Перенести и перезапустить", "Move and relaunch"))
        a.addButton(withTitle: L("Позже", "Later"))
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        try? fm.removeItem(atPath: dest)
        do {
            try fm.copyItem(atPath: path, toPath: dest)
        } catch {
            let b = NSAlert()
            b.messageText = L("Не получилось перенести", "Couldn't move the app")
            b.informativeText = L("Перетащи Giga Pisar.app в папку «Программы» Финдером и запусти оттуда. (\(error.localizedDescription))",
                                  "Drag Giga Pisar.app into the Applications folder in Finder and launch it from there. (\(error.localizedDescription))")
            b.runModal()
            return
        }
        // снять карантин с новой копии, чтобы система не подменяла её снова
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", dest]
        try? x.run()
        x.waitUntilExit()
        // запустить копию из «Программ» после нашего выхода
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c",
            "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.3; done; /usr/bin/open \"\(dest)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: перехват правого ⌘ — без разрешения «Мониторинг ввода»
    //
    // macOS охраняет СОДЕРЖИМОЕ набора: следить за обычными клавишами без
    // Input Monitoring нельзя. А состояние модификаторов (⌘/⌥/⌃/Fn)
    // содержимым не считается — NSEvent отдаёт его любому приложению.
    // Наши клавиши-рации все модификаторы, так что перехватчик всей
    // клавиатуры был избыточен; проверено опытом: flagsChanged приходит
    // без разрешений, keyDown — нет.

    @objc func pickLang(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "uiLang")
        buildMenu()
    }

    @objc func pickChipsMode(_ sender: NSMenuItem) {
        Brain.shared.chipsEnabled = (sender.representedObject as? String) == "menu"
        buildMenu()
    }

    @objc func pickBrain(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id == "off" {
            Brain.shared.chosenId = nil
            Brain.shared.stopServer()
            buildMenu()
            return
        }
        guard let m = BRAIN_MODELS.first(where: { $0.id == id }) else { return }
        if Brain.shared.downloadingId == m.id {
            Brain.shared.cancelDownload()
            return
        }
        guard Brain.shared.downloaded(m) else {
            // Честно предупредить, если памяти впритык.
            let ramGB = ProcessInfo.processInfo.physicalMemory / (1 << 30)
            if ramGB < m.minRAMGB {
                let a = NSAlert()
                a.messageText = L("Может быть тесно", "Might be a tight fit")
                a.informativeText = L("У этого мака \(ramGB) ГБ памяти, а \(m.name) просит от \(m.minRAMGB) ГБ. Заработает, но медленно и прожорливо. Всё равно скачать?",
                                      "This Mac has \(ramGB) GB of RAM and \(m.name) wants \(m.minRAMGB)+. It will run, but slowly. Download anyway?")
                a.addButton(withTitle: L("Скачать", "Download"))
                a.addButton(withTitle: L("Отмена", "Cancel"))
                guard a.runModal() == .alertFirstButtonReturn else { return }
            }
            Brain.shared.startDownload(m)
            return
        }
        Brain.shared.chosenId = id
        buildMenu()
    }

    func startKeyMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
        }
        // когда активны мы сами (открыто наше меню) — события идут локально
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
            return e
        }
        // Буква, нажатая при зажатой рации, значит «это шорткат, не диктовка» —
        // тогда запись отменяется. Такие события система отдаёт только
        // с разрешением «Универсальный доступ» (оно и так нужно для вставки);
        // пока его нет, просто не работает эта мелочь, а диктовка работает.
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            guard let self, self.rightCmdDown, Date() > self.syntheticKeyUntil else { return }
            self.stopRecording(abort: true)
        }
    }

    func handleFlags(_ e: NSEvent) {
        let hk = currentHotkey()
        guard e.keyCode == hk.keycode else { return }
        let pressed = e.modifierFlags.contains(hk.flag)
        if pressed, !rightCmdDown {
            rightCmdDown = true
            startRecording()
        } else if !pressed, rightCmdDown {
            rightCmdDown = false
            stopRecording(abort: false)
        }
    }

    // MARK: запись (родной AVAudioRecorder, 16 кГц моно wav)

    func startRecording() {
        guard !mic.isRecording else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    let a = NSAlert()
                    a.messageText = L("Гига Писарю нужен доступ к микрофону", "Giga Pisar needs microphone access")
                    a.informativeText = L("Системные настройки → Конфиденциальность и безопасность → Микрофон → включи «Giga Pisar».",
                                  "System Settings → Privacy & Security → Microphone → turn on “Giga Pisar”.")
                    a.runModal()
                    return
                }
                self?.beginRecording()
            }
        }
    }

    func beginRecording() {
        guard !mic.isRecording else { return }
        do {
            try mic.start()
        } catch {
            // Устройство не завелось (частый случай на виртуалках).
            // Раньше мы в этом положении молча показывали волну — человек
            // диктовал в пустоту. Теперь говорим сразу и словами.
            NSLog("Гига Писарь: микрофон не завёлся — \(error)")
            setState(.idle)
            Toast.shared.show(L("Микрофон не завёлся — звук не идёт. Проверь микрофон в настройках системы.",
                                "The microphone didn't start — no audio. Check the microphone in System Settings."))
            return
        }
        recStart = Date()
        cancelled = false
        setState(.rec)
        if waveEnabled { wave.show(near: typingAnchor()) }
        captureSelection()
    }

    /// Что выделено в момент нажатия рации. Только при включённом мозге
    /// и не в терминале (там выделения через Accessibility нет).
    func captureSelection() {
        selectionAtStart = nil
        guard !frontIsTerminal, Brain.shared.ready, Brain.shared.engineAvailable else { return }
        let (text, length) = selectedTextViaAX()
        if let text {
            selectionAtStart = text
            NSLog("Гига выделение: AX, \(text.count) знаков")
            hintSelection(text.count)
            return
        }
        // Диапазон выделен, а сам текст приложение не отдаёт (Chrome,
        // Electron). Берём через ⌘C за пользователя, буфер возвращаем
        // как был: момент наш, никакой гонки с чужой вставкой тут нет.
        guard length > 0, AXIsProcessTrusted() else { return }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let snapshot: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        syntheticKeyUntil = Date().addingTimeInterval(0.4)
        pressKey(8, .maskCommand) // ⌘C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            guard pb.changeCount != before else {
                NSLog("Гига выделение: ⌘C ничего не дал")
                return
            }
            if let s = pb.string(forType: .string),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.selectionAtStart = s
                NSLog("Гига выделение: через ⌘C, \(s.count) знаков")
                self.hintSelection(s.count)
            }
            pb.clearContents()
            if !snapshot.isEmpty { pb.writeObjects(snapshot) }
        }
    }

    func hintSelection(_ n: Int) {
        Toast.shared.show(L("Выделено \(n) знаков. Скажи, что с ними сделать",
                            "\(n) characters selected. Say what to do with them"), seconds: 2.5)
    }

    /// Речь как команда над выделенным текстом: результат встаёт поверх
    /// выделения, редактор сам его заменяет. Возвращает false, если это
    /// обычная диктовка.
    func runSelectionCommand(_ speech: String) -> Bool {
        guard let sel = selectionAtStart else { return false }
        selectionAtStart = nil
        let cmd = Brain.stripAddress(speech)
        guard !cmd.isEmpty, Brain.shared.ready, Brain.shared.engineAvailable else { return false }
        NSLog("Гига выделение: команда «\(cmd)» над \(sel.count) знаками")
        Brain.shared.transform(sel, command: cmd, mode: .selection) { [weak self] out in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setState(.idle)
                guard let out else {
                    Toast.shared.show(L("Писарь не справился. Выделенное не тронул",
                                        "Pisar could not do it. The selection is untouched"))
                    return
                }
                self.paste(out, spacing: false) // встаёт вместо выделенного, пробел лишний
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if Brain.shared.chipsEnabled {
                        let p = typingAnchorIfKnown() ?? NSEvent.mouseLocation
                        Chips.shared.showRevert(near: p, terminal: false) { [weak self] in
                            // ⌘Z откатывает вставку, редактор сам возвращает выделенное
                            self?.undoInsert(chars: out.count)
                        }
                    } else {
                        Toast.shared.show(L("Готово. Вернуть как было: ⌘Z", "Done. Undo with ⌘Z"))
                    }
                }
            }
        }
        return true
    }

    func stopRecording(abort: Bool) {
        guard mic.isRecording else { return }
        cancelled = abort
        let samples = mic.stop()
        let dur = Date().timeIntervalSince(recStart ?? Date())
        if cancelled || dur < MIN_SECONDS {
            setState(.idle)
            return
        }
        // Запись шла, а звука в ней нет — так отдают тишину сломанные
        // и виртуальные драйверы. Красное мигание иконки легко пропустить,
        // поэтому говорим словами, той же плашкой, что про курсор.
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.0015 else {
            setState(.idle)
            Toast.shared.show(L("Микрофон отдал тишину — звук до записи не дошёл",
                                "The microphone delivered silence — no audio reached the recording"))
            return
        }
        Audio.writeWav(samples, rate: 16000, to: WAV_PATH) // след для разбора полётов
        transcribe(samples)
    }

    // MARK: распознавание и вставка

    func transcribe(_ samples: [Float]) {
        setState(.busy)
        recognizerQueue.async { [weak self] in
            guard let r = self?.recognizer else {
                // Модель не нашлась вовсе (про это уже было окно при запуске).
                // Если она ещё грузилась, мы сюда не попадём: загрузка стоит
                // в этой же очереди первой, и работа дождалась её сама.
                DispatchQueue.main.async {
                    self?.setState(.idle)
                    self?.flashError()
                }
                return
            }
            let text: String
            do {
                text = try r.transcribe(samples: samples, rate: 16000)
            } catch {
                NSLog("Гига Писарь: не распознал — \(error)")
                DispatchQueue.main.async {
                    self?.setState(.idle)
                    self?.flashError()
                }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if text.isEmpty {
                    self.setState(.idle)
                    self.flashError()
                    return
                }
                // Было выделение при нажатии рации? Тогда это команда над ним.
                if self.runSelectionCommand(text) { return }
                // Сразу в буфер: что бы дальше ни случилось (мозг завис,
                // вставка не прошла, приложение перезапустили) — наговоренное
                // уже не потеряется, его можно вставить самому через ⌘V.
                let pb = NSPasteboard.general
                self.stashClipboard()
                pb.clearContents()
                pb.setString(text, forType: .string)
                self.clipboardMark = pb.changeCount
                // Обращение «Писарь, …» в конце? Сперва текст идёт в мозг.
                if let (body, cmd) = Brain.parseCommand(text) {
                    guard Brain.shared.ready, Brain.shared.engineAvailable else {
                        self.setState(.idle)
                        self.paste(text)
                        if Brain.shared.chosenId == nil, Brain.shared.engineAvailable {
                            Toast.shared.show(L("Похоже на команду Писарю — включи мозг в меню Гиги",
                                                "Sounded like a Pisar command — pick a brain in the Giga menu"))
                        }
                        return
                    }
                    // остаёмся в .busy: точки в строке меню, серая волна — «думаю»
                    Brain.shared.transform(body, command: cmd) { out in
                        DispatchQueue.main.async {
                            self.setState(.idle)
                            if let out {
                                self.paste(out)
                            } else {
                                self.paste(text)
                                Toast.shared.show(L("Писарь не справился — вставил как есть",
                                                    "Pisar could not do it — pasted as is"))
                            }
                        }
                    }
                    return
                }
                self.setState(.idle)
                self.paste(text, offerChips: true)
            }
        }
    }

    func flashError() {
        // короткая красная вспышка иконки вместо алерта
        statusItem.button?.image = barsImage([13, 4, 13, 4, 13], color: recColor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            // за эти секунды могла начаться новая запись — её не сбиваем
            guard let self, self.state == .idle else { return }
            self.setState(.idle)
        }
    }

    /// Терминалы: ⌘Z там не откатывает текст, поэтому подмена другая —
    /// стираем вставленное побуквенно (см. undoInsert), а меню Писаря
    /// одевается в терминальный костюм.
    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.mitchellh.ghostty",
    ]
    var frontIsTerminal: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return false }
        return App.terminalApps.contains(id)
    }

    /// Нажать клавишу с модификаторами за пользователя (⌘V, ⌘Z…).
    func pressKey(_ vk: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Убрать только что вставленный текст перед подменой. В обычных
    /// полях — откат ⌘Z. В терминале отката нет, а ⌃U работает не везде
    /// (в поле ввода Claude Code — нет), поэтому надёжнее стереть
    /// вставленное побуквенно: Backspace ровно столько раз, сколько
    /// символов вставили. Курсор после вставки стоит в конце — попадаем.
    func undoInsert(chars: Int) {
        if frontIsTerminal {
            for i in 0..<min(chars, 4000) {
                pressKey(51, []) // Backspace
                if i % 25 == 24 { usleep(8000) } // терминалу нужен вдох
            }
        } else {
            pressKey(6, .maskCommand) // ⌘Z
        }
    }

    /// Меню Писаря у точки набора. В терминале — в терминальном костюме.
    func showChipsMenu() {
        let p = typingAnchorIfKnown() ?? NSEvent.mouseLocation
        Chips.shared.show(near: p, terminal: frontIsTerminal) { [weak self] cmd in
            self?.applyChip(cmd)
        }
    }

    /// Клик по кнопочке: прогнать вставленное через мозг и подменить
    /// (откатываем свою вставку через ⌘Z и вставляем причёсанное).
    func applyChip(_ command: String) {
        guard let text = lastText else { return }
        setState(.busy)
        Brain.shared.transform(text, command: command) { [weak self] out in
            DispatchQueue.main.async {
                guard let self else { return }
                self.setState(.idle)
                guard let out else {
                    Toast.shared.show(L("Писарь не справился — оставил как было",
                                        "Pisar could not do it — left it as is"))
                    return
                }
                let original = text
                self.undoInsert(chars: text.count)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.paste(out)
                    // рядом повисает «Вернуть как было» — вдруг не понравилось
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let p = typingAnchorIfKnown() ?? NSEvent.mouseLocation
                        Chips.shared.showRevert(near: p, terminal: self.frontIsTerminal) { [weak self] in
                            guard let self else { return }
                            // считаем по вставленному, а не по ответу мозга:
                            // paste мог дописать пробел, и в терминале мы
                            // стираем ровно столько символов, сколько вставили
                            self.undoInsert(chars: self.lastText?.count ?? out.count)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                self.paste(original)
                                // вернули — и снова предлагаем команды:
                                // меню живёт до Enter или крестика
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    self.showChipsMenu()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// spacing — дописать пробел в конец. Так следующая фраза не слипается
    /// с предыдущей, если диктовать подряд. Выключаем там, где текст встаёт
    /// не в конец, а на место выделенного куска.
    func paste(_ text: String, offerChips: Bool = false, spacing: Bool = true) {
        var text = text
        if spacing, let last = text.last, !last.isWhitespace { text += " " }
        lastText = text

        // Вставляем через буфер (быстро и надёжно), но берём его взаймы:
        // прежнее содержимое запоминаем и вернём, как только текст встанет
        // в поле. Если вставить не выйдет — диктовка в буфере и останется,
        // чтобы её можно было вставить самому.
        let pb = NSPasteboard.general
        stashClipboard()
        pb.clearContents()
        pb.setString(text, forType: .string)
        clipboardMark = pb.changeCount

        // Есть ли куда вставлять? Спрашиваем про сам фокус в текстовом поле,
        // а не про координаты каретки: терминалы и Electron часто скрывают,
        // ГДЕ каретка, но поле-то у них есть и ⌘V сработает. Если поля нет —
        // ⌘V всё равно нажмём, но буфер НЕ затираем и подсказываем.
        // Молчание Accessibility — не отказ: в Electron дерево может быть
        // ещё не построено, а ⌘V там прекрасно работает. Ругаемся, только
        // когда точно знаем, что фокус не в тексте.
        let inField = textFocus() != .notField
        // Нажать ⌘V за пользователя можно только с разрешением Accessibility.
        let trusted = AXIsProcessTrusted() || CGPreflightPostEventAccess()
        guard trusted else {
            // Системный промпт «Giga Pisar would like to control this computer…»
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            let a = NSAlert()
            a.messageText = L("Ещё одно разрешение — и всё", "One more permission and you're set")
            a.informativeText = L("Текст уже в буфере — вставь его сам через ⌘V.\nВ появившемся системном окне нажми «Open System Settings» и включи «Giga Pisar» в списке Accessibility.",
                                  "The text is already on the clipboard — paste it with ⌘V.\nIn the system dialog, click “Open System Settings” and turn on “Giga Pisar” under Accessibility.")
            a.runModal()
            keepClipboard() // вставить нечем — диктовка остаётся в буфере
            return
        }
        pressKey(9, .maskCommand) // ⌘V
        if inField {
            // Буфер возвращаем человеку. Проверять, дошла ли вставка на самом
            // деле, мы пробовали — по каретке и числу символов в поле, — и от
            // этого пришлось отказаться: Electron (VS Code и плагины в нём)
            // отвечает Accessibility как попало, и проверка объявляла неудачу
            // поверх удавшейся вставки.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardHold) { [weak self] in
                self?.restoreClipboard()
            }
            // Менюшка: сырой текст вставлен, предложить причесать.
            if offerChips, Brain.shared.ready, Brain.shared.chipsEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.showChipsMenu()
                }
            }
        } else {
            keepClipboard() // поля не было — диктовка нужна в буфере
            Toast.shared.show(L("Курсор был не в тексте — диктовка в буфере, нажми ⌘V",
                                "The cursor wasn't in a text field — your dictation is on the clipboard, press ⌘V"))
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory) // без иконки в доке
app.run()
