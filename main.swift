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

/// The key name inside a sentence: "right ⌘", not "Right ⌘".
func hotkeyInText() -> String {
    let t = currentHotkey().title
    return t.prefix(1).lowercased() + t.dropFirst()
}

func currentHotkey() -> Hotkey {
    let id = UserDefaults.standard.string(forKey: "hotkey") ?? "rcmd"
    return HOTKEYS.first { $0.id == id } ?? HOTKEYS[0]
}

// MARK: - Иконки (рисуем векторно, template → ЧБ под тему строки меню)

/// Столбики в строке меню. Цвет не задан — шаблонная иконка покоя,
/// чёрно-белая под тему строки меню. Задан — состояние: красный «пишу»,
/// синий «думаю», те же цвета, что у плашки возле курсора.
func barsImage(_ heights: [CGFloat], color: NSColor? = nil, badge: Bool = false) -> NSImage {
    let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
        // С красной точкой значок уже не шаблонный, и macOS его не
        // перекрашивает: столбики красим сами цветом текста строки меню,
        // он сам становится чёрным или белым под её тему.
        (color ?? (badge ? NSColor.labelColor : NSColor.black)).setFill()
        for (i, h) in heights.enumerated() {
            let r = NSRect(x: 1 + CGFloat(i) * 4.2, y: 9 - h / 2, width: 2.8, height: h)
            NSBezierPath(roundedRect: r, xRadius: 1.3, yRadius: 1.3).fill()
        }
        // Точка «вышло обновление» в правом нижнем углу. Сначала вырезаем
        // под ней просвет — вместе со столбиками, что под неё попали, —
        // и только потом рисуем саму точку: так она читается на любой
        // строке меню, не сливаясь со столбиками.
        if badge {
            let c = NSPoint(x: 18.6, y: 3.2)
            let dot: CGFloat = 2.7, gap: CGFloat = 1.4
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: c.x - dot - gap, y: c.y - dot - gap,
                                        width: (dot + gap) * 2, height: (dot + gap) * 2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            // Красная, чтобы бросалась в глаза: окно о новой версии больше
            // не выскакивает, и кроме точки о ней ничто не напомнит.
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot,
                                        width: dot * 2, height: dot * 2)).fill()
        }
        return true
    }
    img.isTemplate = (color == nil && !badge)
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

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    let mic = Mic()
    var recStart: Date?
    var rightCmdDown = false
    let recordingStart = RecordingStart()
    var cancelled = false
    var animTimer: Timer?

    /// Окно с разрешениями (первый запуск и пункт меню).
    let onboarding = Onboarding()

    /// Модель. Грузится один раз в фоне; recognizer трогаем только из recognizerQueue.
    var recognizer: Recognizer?
    let recognizerQueue = DispatchQueue(label: "ru.panda.giga.recognizer")
    private var pendingOperations = 0 // main queue; includes older takes and Brain

    /// Приглушили ли мы звук сами — тогда нам его и возвращать.
    private var soundHushed = false

    /// Плашка с волной у места набора (выключается в меню).
    let wave = WavePanel.shared
    var waveEnabled: Bool { UserDefaults.standard.object(forKey: "wavePanel") as? Bool ?? true }

    /// Номер свежей версии с зеркал, если она новее нашей, и её ссылки.
    var updateAvailable: String?
    let updateWindow = UpdateWindow()
    let modelWindow = UpdateWindow()    // загрузка модели распознавания
    weak var updMenuItem: NSMenuItem?   // «Качаю версию…» с живыми процентами
    var updateDownloads: [URL] = []

    /// Последняя удачная диктовка — страховка на случай «курсор был не в поле».
    var lastText: String?
    private var recoveredTakes: [Int: [String]] = [:] // memory only; never logged
    private func saveDictation(_ text: String, take current: Int) {
        guard !text.isEmpty else { return }
        var versions = recoveredTakes[current] ?? []
        if !versions.contains(text) { versions.append(text) }
        // Keep the raw text even after many Brain transformations.
        if versions.count > 10 { versions.remove(at: 1) }
        recoveredTakes[current] = versions
        for key in recoveredTakes.keys.sorted().dropLast(20) { recoveredTakes.removeValue(forKey: key) }
    }
    private var recoveryWindow: NSWindow?
    private let clipboard = DictationClipboard.shared
    private var take = 0
    private var takeTarget: pid_t = 0
    private var takeFocus: AXUIElement?

    @objc func showLastDictation() {
        if recoveryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = L("Последние диктовки", "Recent dictations")
            window.isReleasedWhenClosed = false
            window.delegate = self
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = window.contentView!.bounds
            scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let text = scroll.documentView as! NSTextView
            text.isEditable = false; text.isSelectable = true
            text.autoresizingMask = [.width]; text.isVerticallyResizable = true
            window.contentView = scroll
            recoveryWindow = window; window.center()
        }
        ((recoveryWindow?.contentView as? NSScrollView)?.documentView as? NSTextView)?.string =
            recoveredTakes.keys.sorted().reversed().flatMap { recoveredTakes[$0] ?? [] }.joined(separator: "\n\n———\n\n")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        recoveryWindow?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === recoveryWindow { NSApp.setActivationPolicy(.regular) }
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === recoveryWindow,
           !NSApp.windows.contains(where: { $0 !== recoveryWindow && $0.isVisible && $0.canBecomeKey }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    /// Текст, который был выделен в момент нажатия рации. Если он есть и
    /// мозг включён, речь считается командой над ним, а не диктовкой.
    var selectionAtStart: String?
    private var selectionPending = false
    private var selectionFailed = false
    private var selectionReady: (() -> Void)?
    /// Пока мы сами жмём клавиши (⌘C за пользователя), монитор keyDown
    /// не должен принимать их за «шорткат, отменяем запись».
    var syntheticKeyUntil = Date.distantPast
    /// Шторка «Поделиться» живёт, пока открыта: иначе её отпустит ARC.
    var sharePicker: NSSharingServicePicker?



    func applicationWillTerminate(_ n: Notification) {
        Brain.shared.stopServer()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setState(.idle)
        offerMoveToApplications()
        enableLoginByDefault()
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
        var brainWasDownloading = false
        Brain.shared.onChange = { [weak self] in
            guard let self else { return }
            let downloading = Brain.shared.downloadingId != nil
            if brainWasDownloading, !downloading, Brain.shared.chosenModel.map(Brain.shared.downloaded) == true,
               !UserDefaults.standard.bool(forKey: "brainHelpShown") {
                UserDefaults.standard.set(true, forKey: "brainHelpShown")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showBrainHelp() }
            }
            brainWasDownloading = downloading
            if let id = Brain.shared.downloadingId,
               let m = BRAIN_MODELS.first(where: { $0.id == id }),
               let item = self.dlMenuItem {
                item.attributedTitle = self.menuAttrTitle(L("Мозг", "Brain"),
                    sub: L("качаю \(m.name), \(Brain.shared.downloadPercent)%", "downloading \(m.name), \(Brain.shared.downloadPercent)%"))
                self.settings.updateDownload()
            } else {
                self.settingsChanged()
            }
        }
        buildMenu()
        loadModel()
        startKeyMonitors()
        if !Onboarding.allGranted || Onboarding.demo != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.onboarding.show()
            }
        }
        // Переехали в Программы ради обновления — не ждём 15 секунд, обновляемся
        if UserDefaults.standard.bool(forKey: "updateAfterMove") {
            UserDefaults.standard.removeObject(forKey: "updateAfterMove")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.checkUpdates(silent: false, autoInstall: true)
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
        // An older transcription finishing must not hide a newer recording.
        if mic.isRecording && s != .rec { return }
        state = s
        animTimer?.invalidate()
        animTimer = nil
        switch s {
        case .idle:
            statusItem.button?.image = barsImage([5, 9, 13, 9, 5], badge: updateAvailable != nil)
            wave.hide()
        case .rec:
            // Столбики показывают настоящую громкость с микрофона: молчишь —
            // лежат, говоришь — пляшут. Волну у курсора и иконку в строке меню
            // кормит один таймер одними и теми же числами, поэтому они всегда
            // об одном и том же звуке.
            statusItem.button?.image = barsImage([3, 3, 3, 3, 3], color: recColor, badge: updateAvailable != nil)
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
                                                              color: recColor,
                                                              badge: self.updateAvailable != nil)
                }
                // окно с кареткой могли передвинуть прямо во время диктовки —
                // раз в полсекунды спрашиваем место заново и едем за ним
                if tick % 30 == 0, self.waveEnabled, WavePanel.place == .cursor {
                    self.wave.follow(typingAnchorIfKnown())
                }
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
                [CGFloat](repeating: 3 + 11 * BUSY_BAR, count: 5), color: busyColor,
                badge: updateAvailable != nil)
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
        let recovery = NSMenuItem(title: L("Последние диктовки…", "Recent dictations…"),
                                  action: #selector(showLastDictation), keyEquivalent: "")
        recovery.target = self
        menu.addItem(recovery)

        menu.addItem(mkHeader(L("Гига Писарь \(APP_VERSION)", "Giga Pisar \(APP_VERSION)"),
                              sub: L("зажми \(hotkeyInText()) и говори",
                                     "hold \(hotkeyInText()) and speak")))
        menu.addItem(NSMenuItem.separator())

        // Only quick switches, each with one grey line saying what it is; everything else is in Settings.
        let b = Brain.shared
        let brainSub: String
        if let id = b.downloadingId, let m = BRAIN_MODELS.first(where: { $0.id == id }) {
            brainSub = L("качаю \(m.name), \(b.downloadPercent)%", "downloading \(m.name), \(b.downloadPercent)%")
        } else if b.chosenId != nil, !b.ready {
            brainSub = L("не настроен, нажми, чтобы настроить", "not set up, click to set it up")
        } else if b.usesServer {
            brainSub = L("правит по команде «Писарь, …» · в облаке", "edits on “Pisar, …” · in the cloud")
        } else if let m = b.chosenModel {
            brainSub = L("правит по команде «Писарь, …» · \(m.name)", "edits on “Pisar, …” · \(m.name)")
        } else {
            brainSub = L("нейросеть правит текст по команде «Писарь, …»", "an AI model edits text on “Pisar, …”")
        }
        let brainItem = mkItem(L("Мозг", "Brain"), sub: brainSub, icon: "brain", action: #selector(toggleBrain))
        brainItem.state = b.chosenId != nil ? .on : .off
        if b.downloadingId != nil { dlMenuItem = brainItem }
        menu.addItem(brainItem)

        let fly = mkItem(L("Править на лету", "Edit on the Fly"),
                         sub: L("причёсывает каждую диктовку сама", "tidies every take by itself"),
                         icon: "text.badge.checkmark", action: #selector(toggleEveryTake))
        fly.state = b.everyTake ? .on : .off
        fly.isEnabled = b.ready
        menu.addItem(fly)

        let editSel = mkItem(L("Править выделенный текст", "Edit Selected Text"),
                             sub: L("выдели, зажми \(hotkeyInText()) и скажи, что сделать",
                                    "select, hold \(hotkeyInText()), say what to do"),
                             icon: "character.cursor.ibeam", action: #selector(toggleEditSelection))
        editSel.state = b.onSelection ? .on : .off
        editSel.isEnabled = b.ready
        menu.addItem(editSel)
        menu.addItem(NSMenuItem.separator())

        if SelfUpdate.inProgress, let upd = SelfUpdate.version {
            let item = mkItem(L("Качаю версию \(upd)…", "Downloading version \(upd)…"),
                              sub: L("нажми, чтобы посмотреть ход дела", "click to see progress"),
                              icon: "arrow.down.circle", action: #selector(startSelfUpdate))
            menu.addItem(item)
            updMenuItem = item
        } else if let upd = updateAvailable {
            menu.addItem(mkItem(L("Доступна версия \(upd), обновить", "Version \(upd) Available, Update"),
                                icon: "arrow.down.circle", action: #selector(startSelfUpdate)))
        }
        let prefs = mkItem(L("Настройки…", "Settings…"), sub: L("клавиша, звук, облако и всё остальное", "key, sound, cloud and everything else"),
                           icon: "gearshape", action: #selector(openSettings))
        prefs.keyEquivalent = ","
        menu.addItem(prefs)
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
        selectHotkey(id)
    }

    func selectHotkey(_ id: String) {
        UserDefaults.standard.set(id, forKey: "hotkey")
        settingsChanged()
    }

    /// Menu and Settings show the same state: after any change both are redrawn.
    func settingsChanged() {
        buildMenu()
        settings.refresh()
    }

    lazy var settings = SettingsWindow(app: self)

    @objc func openSettings() { settings.show() }
    @objc func openBrainSettings() { settings.show(tab: .brain) }

    /// The menu switch: off, or back to what was chosen last. Never set up: open the Brain tab.
    @objc func toggleBrain() {
        let b = Brain.shared
        if b.chosenId != nil, !b.ready, b.downloadingId == nil {
            settings.show(tab: .brain)   // chosen but not set up: the grey line promised to open settings
            return
        }
        if let id = b.chosenId {
            UserDefaults.standard.set(id, forKey: "brainLast")
            selectBrain("off")
            return
        }
        let last = UserDefaults.standard.string(forKey: "brainLast")
        let usable: (String) -> Bool = { id in
            id == BrainServer.id ? BrainServer.configured : (BRAIN_MODELS.first { $0.id == id }.map(b.downloaded) ?? false) && b.engineAvailable
        }
        if let last, usable(last) { selectBrain(last); return }
        if let m = BRAIN_MODELS.first(where: { b.engineAvailable && b.downloaded($0) }) { selectBrain(m.id); return }
        if BrainServer.configured { selectBrain(BrainServer.id); return }
        settings.show(tab: .brain)
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

    /// Приглушить звук на время диктовки, если это выбрано в меню.
    private func hushSound() {
        // Уже тихо — значит человек приглушил звук сам, и возвращать его
        // после диктовки не наше дело. Не глушим, не запоминаем.
        guard Sound.muteWhileDictating, !Sound.isSilent else { return }
        Sound.setMuted(true)
        soundHushed = true
    }

    /// Вернуть звук. Возвращаем только если глушили сами: если человек
    /// приглушил динамики до диктовки, включать их обратно не наше дело.
    private func restoreSound() {
        guard soundHushed else { return }
        Sound.setMuted(false)
        soundHushed = false
    }

    @objc func toggleHush() {
        Sound.muteWhileDictating.toggle()
        settingsChanged()
    }

    var waveChoice: String { waveEnabled ? WavePanel.place.rawValue : "off" }

    func selectWave(_ id: String) {
        UserDefaults.standard.set(id != "off", forKey: "wavePanel")
        if let p = WavePanel.Place(rawValue: id) { WavePanel.place = p }
        if !waveEnabled {
            wave.hide()
        } else if state == .rec {
            // выбрали прямо во время диктовки — плашка переезжает сразу
            wave.show(near: typingAnchor())
        }
        settingsChanged()
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
        // Запущено прямо из архива или «Загрузок»: macOS держит приложение
        // во временной копии, подменить её нельзя. Раньше тут вылетало
        // «нет прав заменить /private/var/…AppTranslocation…» и кнопка на
        // страницу со списком файлов. Правильный выход один: переехать в
        // Программы и обновиться уже оттуда.
        if !canUpdateInPlace {
            let a = NSAlert()
            a.messageText = L("Сначала перенесу в Программы", "Moving to Applications first")
            a.informativeText = L("Приложение запущено прямо из архива или «Загрузок», и macOS не даёт обновить его на месте. Я перенесу себя в Программы, перезапущусь оттуда и сразу обновлюсь до \(ver).",
                                  "The app is running straight from the archive or Downloads, and macOS won't let it update in place. I'll move to Applications, relaunch from there and update to \(ver) right away.")
            a.addButton(withTitle: L("Перенести и обновиться", "Move and update"))
            a.addButton(withTitle: L("Позже", "Later"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: "updateAfterMove")
            moveToApplicationsAndRelaunch()
            return
        }
        updateWindow.onCancel = { [weak self] in
            SelfUpdate.cancel()
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
                self.updMenuItem?.attributedTitle = self.menuAttrTitle(
                    L("Качаю версию \(ver)… \(p)%", "Downloading version \(ver)… \(p)%"),
                    sub: L("нажми, чтобы посмотреть ход дела", "click to see progress"))
            case .verifying:
                self.updateWindow.onCancel = nil // дальше отменять нечего
                self.updateWindow.busy(L("Проверяю подпись…", "Verifying the signature…"))
            }
        }, ready: { [weak self] in
            self?.updateWindow.busy(L("Перезапускаюсь…", "Relaunching…"))
            self?.quitForUpdateWhenIdle()
        }, fail: { [weak self] reason in
            self?.updateWindow.hide()
            self?.buildMenu()
            let a = NSAlert()
            a.messageText = L("Обновиться само не получилось", "Self-update didn't work")
            a.informativeText = L("Причина: \(reason).\nМожно переустановить вручную: скачать образ, открыть его и перетащить Гига Писаря в Программы поверх старого.",
                                  "Reason: \(reason).\nYou can reinstall by hand: download the image, open it and drag Giga Pisar into Applications over the old one.")
            a.addButton(withTitle: L("Скачать образ", "Download the image"))
            a.addButton(withTitle: L("Позже", "Later"))
            if a.runModal() == .alertFirstButtonReturn { self?.openDmg() }
        })
    }

    /// Обновление скачано и проверено; выходим на подмену, но вежливо:
    /// посреди диктовки или распознавания не дёргаемся — ждём покоя.
    func quitForUpdateWhenIdle() {
        guard state == .idle, !mic.isRecording, !rightCmdDown, !clipboard.isBusy,
              pendingOperations == 0 else {
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

    /// Браузер сразу качает образ последнего выпуска.
    func openDmg() {
        if let url = URL(string: DMG_URL) { NSWorkspace.shared.open(url) }
    }

    /// Можно ли подменить работающее приложение на месте: не временная
    /// карантинная копия и папка доступна на запись.
    var canUpdateInPlace: Bool {
        let path = Bundle.main.bundlePath
        let fm = FileManager.default
        return !path.contains("/AppTranslocation/")
            && fm.isWritableFile(atPath: path)
            && fm.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    @objc func checkUpdatesManual() { checkUpdates(silent: false) }

    /// silent — фоновая проверка: молчит, если новостей нет, и об одной и той
    /// же версии напоминает окном только один раз (дальше — пункт в меню).
    func checkUpdates(silent: Bool, autoInstall: Bool = false) {
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
                        self.setState(self.state)   // и точку со значка
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
                // Точка на значке вместо окна: проверка идёт сама по себе,
                // и выскакивать поверх чужой работы ей незачем.
                self.setState(self.state)
                if autoInstall { self.startSelfUpdate(); return } // человек уже сказал «обновиться»
                if !silent {
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

    /// Автозапуск при входе включён по умолчанию (с 3.9.1): диктовка нужна
    /// сразу после включения мака, а не после того, как вспомнил открыть Писаря.
    /// Включаем один раз и только из «Программ» (иначе macOS запомнит копию
    /// из «Загрузок»). Выключил сам — больше не трогаем.
    func enableLoginByDefault() {
        guard !UserDefaults.standard.bool(forKey: "loginItemDecided"),
              Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemDecided")
        let svc = SMAppService.mainApp
        guard svc.status != .enabled else { return }
        do {
            try svc.register()
            NSLog("Гига Писарь: автозапуск при входе включён по умолчанию")
        } catch {
            NSLog("Гига Писарь: автозапуск не включился — \(error)")
        }
    }

    @objc func toggleLogin() {
        UserDefaults.standard.set(true, forKey: "loginItemDecided")   // решение человека важнее умолчания
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
        settingsChanged()
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
        a.informativeText = L("Это «уши» Писаря: 204 МБ, качается один раз и переживает все обновления. Ход дела будет виден в отдельном окне.",
                              "Pisar's ears: a one-time 204 MB download that survives every update. Progress shows in its own window.")
        a.addButton(withTitle: L("Скачать", "Download"))
        a.addButton(withTitle: L("Позже", "Later"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        downloadSpeechModel()
    }

    var modelDL: Downloader?

    func downloadSpeechModel() {
        guard modelDL == nil else { return }
        let url = URL(string: "https://github.com/moznoazachem/giga-pisar-cli/releases/download/v1.0/gigaam-v3-onnx-int8.tar.gz")!
        // Раньше проценты дописывались к значку в строке меню, значок
        // раздувался и на маках с чёлкой прятался за ней: «поставил, а
        // значка нет». Теперь окно с полоской, значок не трогаем.
        modelWindow.onCancel = { [weak self] in
            self?.modelDL?.cancel()
            self?.modelDL = nil
        }
        modelWindow.show(title: L("Модель распознавания", "Speech model"))
        modelWindow.downloading(percent: 0)
        modelDL = Downloader(onPercent: { [weak self] p in
            self?.modelWindow.downloading(percent: p)
        }, onDone: { [weak self] file, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.modelDL = nil
                guard let file else {
                    self.modelWindow.hide()
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
        modelWindow.onCancel = nil
        modelWindow.busy(L("Распаковываю…", "Unpacking…"))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dest = NSHomeDirectory() + "/.giga/model"
            // The same tarball as on GitHub (its own digest says so); anything else is not unpacked.
            guard sha256Hex(ofFile: file.path) == "e5a75ab56ab6d3f3a70ab17dd1ce858fe8180597963839dc806014447483224c" else {
                try? FileManager.default.removeItem(at: file)
                DispatchQueue.main.async {
                    self?.modelWindow.hide()
                    Toast.shared.show(L("Модель скачалась повреждённой, попробуй ещё раз",
                                        "The model arrived damaged, try again"))
                }
                return
            }
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
                self.modelWindow.hide()
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

        // Откуда запущено, по-человечески: не путь, а место.
        let from: String
        if path.contains("/AppTranslocation/") {
            from = L("прямо из архива или «Загрузок»", "straight from the archive or Downloads")
        } else if path.hasPrefix("/Volumes/") {
            from = L("из образа диска", "from the disk image")
        } else {
            let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            from = L("из папки «\(folder)»", "from the “\(folder)” folder")
        }
        let a = NSAlert()
        a.messageText = L("Перенести Гига Писаря в Программы?", "Move Giga Pisar to Applications?")
        a.informativeText = L(
            "Приложение запущено \(from). Из Программ оно работает надёжнее: macOS привязывает разрешения к месту на диске. Перенесу и перезапущусь, это секунда.",
            "The app was launched \(from). It runs more reliably from Applications: macOS ties permissions to the location on disk. I'll move over and relaunch, it takes a second.")
        a.addButton(withTitle: L("Перенести", "Move"))
        a.addButton(withTitle: L("Не сейчас", "Not now"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        moveToApplicationsAndRelaunch()
    }

    /// Скопировать себя в Программы, снять карантин и перезапуститься оттуда.
    func moveToApplicationsAndRelaunch() {
        let path = Bundle.main.bundlePath
        let dest = "/Applications/Giga Pisar.app"
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
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.3; done; /usr/bin/open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), dest]
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

    func selectLang(_ code: String) {
        UserDefaults.standard.set(code, forKey: "uiLang")
        settingsChanged()
    }

    func setChipsMenu(_ on: Bool) {
        Brain.shared.chipsEnabled = on
        settingsChanged()
    }

    /// Инструкция к Мозгу: по пункту меню и один раз сама, когда модель
    /// докачалась, потому что именно в этот момент человек не знает, что дальше.
    @objc func showBrainHelp() {
        let a = NSAlert()
        a.messageText = L("Мозг Писаря", "Pisar's Brain")
        a.informativeText = L("Нейронка причёсывает, сокращает и переводит текст по твоей команде. GigaChat и Qwen работают на этом маке, в интернет ничего не уходит. Можно подключить и свой сервер или облако по ключу.",
                              "A neural net that tidies, shortens and translates text on your command. GigaChat and Qwen run on this Mac, nothing goes online. You can also plug in your own server or a cloud model with a key.")
        a.accessoryView = bulletsView(header: L("Как пользоваться", "How to use it"), lines: uiIsRussian ? [
            "Голосом: в конце диктовки скажи «Писарь, исправь», «Писарь, сократи» или «Писарь, переведи на английский»",
            "Менюшкой: после вставки у курсора появляются 1 причесать · 2 сократить · 3 перевести, жми цифру. Включается в настройках, вкладка «Мозг»",
            "На лету: включи «Править на лету» в меню, и нейросеть будет причёсывать каждую диктовку сама",
            "Над готовым текстом: выдели его, зажми \(currentHotkey().title) и скажи, что сделать («сделай короче», «переведи»). Результат встанет вместо выделенного, ⌘Z вернёт как было",
            "GigaChat: родной русский, 6,5 ГБ, маки от 16 ГБ. Qwen: лёгкая, 2,5 ГБ, русский неродной, но аккуратная",
            "Первый ответ ждёт секунд десять: нейронка поднимается с диска, дальше быстро",
            "В облаке: DeepSeek, OpenRouter, OpenAI или свой LM Studio, по ключу. Быстрее и умнее, работает и на маках с Intel, но текст уходит на сервер (звук нет)",
        ] : [
            "By voice: end your dictation with “Pisar, fix this”, “Pisar, make it shorter” or “Pisar, translate to English”",
            "By menu: after pasting, 1 tidy up · 2 shorten · 3 translate appear at the cursor, press the digit. Turned on in Settings, Brain tab",
            "On the fly: turn on “Edit on the Fly” in the menu and the model tidies every take by itself",
            "On existing text: select it, hold \(currentHotkey().title) and say what to do (“make it shorter”, “translate”). The result replaces the selection, ⌘Z brings it back",
            "GigaChat: native Russian, 6.5 GB, Macs with 16 GB+. Qwen: light, 2.5 GB, non-native Russian but tidy",
            "The first reply takes about ten seconds while the model loads from disk, then it's fast",
            "In the cloud: DeepSeek, OpenRouter, OpenAI or your LM Studio, with a key. Faster and smarter, works on Intel Macs too, but the text goes to the server (audio does not)",
        ], width: 360)
        a.runModal()
    }

    @objc func toggleEditSelection() {
        Brain.shared.onSelection.toggle()
        settingsChanged()
    }

    @objc func toggleEveryTake() {
        Brain.shared.everyTake.toggle()
        settingsChanged()
    }

    /// The cloud Brain is set up right on the Brain tab of Settings.
    @objc func showBrainServer() { settings.show(tab: .brain) }

    @objc func pickBrain(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectBrain(id)
    }

    /// Off, a local model (downloading it first, with a memory warning) or the cloud.
    /// Выбрать, где думать, ничего не скачивая: в настройках выбор и
    /// загрузка теперь разведены — сначала выбираешь, потом отдельной
    /// кнопкой качаешь.
    func chooseBrain(_ id: String) {
        if id == "off" { selectBrain("off"); return }
        if id == BrainServer.id {
            Brain.shared.chosenId = id
            Brain.shared.stopServer()
            settingsChanged()
            return
        }
        guard BRAIN_MODELS.contains(where: { $0.id == id }) else { return }
        Brain.shared.chosenId = id
        settingsChanged()
    }

    /// Качать по кнопке. Если памяти впритык — честно предупреждаем.
    func downloadBrain(_ id: String) {
        guard let m = BRAIN_MODELS.first(where: { $0.id == id }) else { return }
        guard !Brain.shared.downloaded(m) else { return }
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
    }

    /// Удалить скачанную модель: место на диске освобождается сразу,
    /// выбор остаётся — появится кнопка «Скачать».
    func deleteBrainModel(_ id: String) {
        guard let m = BRAIN_MODELS.first(where: { $0.id == id }) else { return }
        let size = Memory.gb(UInt64(max(0, Brain.shared.fileSize(m))))
        let a = NSAlert()
        a.messageText = L("Удалить \(m.name)?", "Delete \(m.name)?")
        a.informativeText = L("Освободится \(size) ГБ. Скачать заново можно в любой момент.",
                              "This frees \(size) GB. You can download it again at any time.")
        a.addButton(withTitle: L("Удалить", "Delete"))
        a.addButton(withTitle: L("Отмена", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Brain.shared.deleteFile(m)
        settingsChanged()
    }

    func selectBrain(_ id: String) {
        if id == "off" {
            Brain.shared.chosenId = nil
            Brain.shared.stopServer()
            settingsChanged()
            return
        }
        if id == BrainServer.id {
            Brain.shared.chosenId = id
            Brain.shared.stopServer()
            settingsChanged()
            if !BrainServer.configured { settings.show(tab: .brain) }   // service and key are filled in there
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
        settingsChanged()
    }

    /// Строка меню для наших окон. Писарь живёт в статус-баре и обычно
    /// это «аксессуар» без иконки в доке — а у аксессуара нет строки меню,
    /// и поля ввода остаются без ⌘V, ⌘C и ⌘Z: печатать можно, вставить
    /// нельзя. Меню собираем сразу, а показываем его вместе с окном
    /// настроек, переключая политику (см. SettingsWindow).
    func installEditMenu() {
        let app = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L("Скрыть Гига Писарь", "Hide Giga Pisar"),
                                   action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Выйти", "Quit"),
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let edit = NSMenu(title: L("Правка", "Edit"))
        let items: [(String, String, Selector)] = [
            (L("Отменить", "Undo"), "z", Selector(("undo:"))),
            (L("Повторить", "Redo"), "Z", Selector(("redo:"))),
            (L("Вырезать", "Cut"), "x", #selector(NSText.cut(_:))),
            (L("Скопировать", "Copy"), "c", #selector(NSText.copy(_:))),
            (L("Вставить", "Paste"), "v", #selector(NSText.paste(_:))),
            (L("Выделить всё", "Select All"), "a", #selector(NSText.selectAll(_:))),
        ]
        for (title, key, action) in items {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit

        app.addItem(appItem)
        app.addItem(editItem)
        NSApp.mainMenu = app
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
        switch RecordingStart.edge(hotkey: currentHotkey().keycode, eventKey: e.keyCode,
                                   flags: e.modifierFlags.rawValue, isDown: rightCmdDown) {
        case .press:
            rightCmdDown = true
            startRecording()
        case .release:
            rightCmdDown = false
            recordingStart.cancel()
            stopRecording(abort: false)
        case .none:
            break
        }
    }

    // MARK: запись (родной AVAudioRecorder, 16 кГц моно wav)

    func startRecording() {
        guard !mic.isRecording else { return }
        let start = recordingStart.schedule { [weak self] in
            guard let self, self.rightCmdDown else { return }
            self.beginRecording()
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    Toast.shared.show(L("Разреши Giga Pisar микрофон в настройках конфиденциальности.",
                                        "Allow Giga Pisar microphone access in Privacy settings."))
                    return
                }
                DispatchQueue.main.async(execute: start)
            }
        }
    }

    func beginRecording() {
        guard !mic.isRecording else { return }
        take += 1
        Chips.shared.hide()
        takeTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        takeFocus = dictationFocus()
        let current = take
        selectionAtStart = nil
        if selectionReady != nil { notifySavedDictation() }
        selectionPending = false; selectionFailed = false; selectionReady = nil
        recStart = Date()
        mic.start { [weak self] error in
            guard let self, self.take == current else { return }
            if let error {
                NSLog("Гига Писарь: микрофон не завёлся — \(error)")
                self.setState(.idle)
                Toast.shared.show(L("Микрофон не завёлся — звук не идёт. Проверь микрофон в настройках системы.",
                                    "The microphone didn't start — no audio. Check the microphone in System Settings."))
                return
            }
            guard self.mic.isRecording else { return }
            guard self.rightCmdDown else { self.stopRecording(abort: true); return }
            self.cancelled = false
            self.hushSound()
            self.setState(.rec)
            if self.waveEnabled {
                self.wave.show(near: WavePanel.place == .cursor ? typingAnchor() : NSEvent.mouseLocation)
            }
        }
        captureSelection()
    }

    /// Что выделено в момент нажатия рации. Только при включённом мозге
    /// и не в терминале (там выделения через Accessibility нет).
    func captureSelection() {
        selectionAtStart = nil
        guard !frontIsTerminal, Brain.shared.ready, Brain.shared.onSelection else { return }
        let (text, length, silent) = selectedTextViaAX()
        if let text {
            selectionAtStart = text
            NSLog("Гига выделение: AX, \(text.count) знаков")
            hintSelection(text.count)
            return
        }
        // Диапазон выделен, а сам текст приложение не отдаёт (Chrome,
        // Electron). Берём через ⌘C за пользователя, буфер возвращаем
        // как был: момент наш, никакой гонки с чужой вставкой тут нет.
        // Pages, Keynote и Numbers не отдают даже диапазон. У них о выделении
        // говорит пункт «Скопировать» в меню: включён, значит есть что брать.
        guard AXIsProcessTrusted(),
              length > 0 || (silent && frontMenuShortcutEnabled("C")) else { return }
        let current = take
        selectionPending = true
        clipboard.selection(allowed: { [weak self] in
            guard let self else { return false }
            return self.take == current
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == self.takeTarget
        }, copy: { [weak self] in self?.pressKey(8, .maskCommand) }) { [weak self] s in
            guard let self, self.take == current else { return }
            self.selectionPending = false
            if case .text(let s) = s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.selectionAtStart = s
                if self.mic.isRecording { self.hintSelection(s.count) }
            } else { self.selectionFailed = s != .noChange || length > 0 }
            let ready = self.selectionReady; self.selectionReady = nil
            ready?()
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
        guard !cmd.isEmpty, Brain.shared.ready else {
            setState(.idle); notifySavedDictation(); return true
        }
        NSLog("Гига выделение: команда (\(cmd.count) знаков) над \(sel.count) знаками")
        let current = take
        pendingOperations += 1
        Brain.shared.transform(sel, command: cmd, mode: .selection) { [weak self] out in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.pendingOperations -= 1 }
                if let out { self.saveDictation(out, take: current) }
                guard self.take == current else { if out != nil { self.notifySavedDictation() }; return }
                self.setState(.idle)
                guard let out else {
                    Toast.shared.show(Brain.shared.failureText(
                        L("Писарь не справился. Выделенное не тронул",
                          "Pisar could not do it. The selection is untouched")))
                    return
                }
                self.paste(out, spacing: false) {
                    guard self.take == current else { return }
                    if Brain.shared.chipsEnabled {
                        let p = typingAnchorIfKnown() ?? NSEvent.mouseLocation
                        Chips.shared.showRevert(near: p, terminal: false) { [weak self] in
                            guard let self, self.take == current,
                                  NSWorkspace.shared.frontmostApplication?.processIdentifier == self.takeTarget,
                                  matchesDictationFocus(self.takeFocus) else { return }
                            // ⌘Z откатывает вставку, редактор сам возвращает выделенное
                            self.undoInsert(chars: out.count)
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
        recordingStart.cancel()
        guard mic.isRecording else { return }
        restoreSound()
        cancelled = abort
        let dur = Date().timeIntervalSince(recStart ?? Date())
        let current = take
        mic.stop { [weak self] samples in
            guard let self else { return }
            guard let samples, !abort, dur >= MIN_SECONDS else {
                if self.take == current { self.setState(.idle) }
                return
            }
            self.prepareTranscription(samples, take: current)
        }
        setState(.busy)
    }

    private func prepareTranscription(_ samples: [Float], take current: Int) {
        pendingOperations += 1
        recognizerQueue.async { [weak self] in
            // Conversion, silence detection and WAV I/O never run on the UI queue.
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            guard peak > 0.0015 else {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingOperations -= 1
                    guard self.take == current else { return }
                    self.setState(.idle)
                    Toast.shared.show(L("Микрофон отдал тишину — звук до записи не дошёл",
                                        "The microphone delivered silence — no audio reached the recording"))
                }
                return
            }
            Audio.writeWav(samples, rate: 16000, to: WAV_PATH)
            DispatchQueue.main.async {
                self?.transcribe(samples, take: current)
            }
        }
    }

    // MARK: распознавание и вставка

    func transcribe(_ samples: [Float], take current: Int) {
        if take == current { setState(.busy) }
        recognizerQueue.async { [weak self] in
            guard let r = self?.recognizer else {
                // Модель не нашлась вовсе (про это уже было окно при запуске).
                // Если она ещё грузилась, мы сюда не попадём: загрузка стоит
                // в этой же очереди первой, и работа дождалась её сама.
                DispatchQueue.main.async {
                    self?.pendingOperations -= 1
                    guard self?.take == current else { return }
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
                    self?.pendingOperations -= 1
                    guard self?.take == current else { return }
                    self?.setState(.idle)
                    self?.flashError()
                }
                return
            }
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.pendingOperations -= 1 }
                self.saveDictation(text, take: current)
                self.deliverTranscription(text, take: current)
            }
        }
    }

    private func deliverTranscription(_ text: String, take current: Int) {
                guard self.take == current else { if !text.isEmpty { self.notifySavedDictation() }; return }
                guard !text.isEmpty else { setState(.idle); flashError(); return }
                if selectionPending {
                    selectionReady = { [weak self] in self?.deliverTranscription(text, take: current) }
                    return
                }
                guard !selectionFailed else { setState(.idle); notifySavedDictation(); return }
                // Было выделение при нажатии рации? Тогда это команда над ним.
                if self.runSelectionCommand(text) { return }
                // Keep raw text available in the menu even if Brain/clipboard stalls.
                // Обращение «Писарь, …» в конце? Сперва текст идёт в мозг.
                if let (body, cmd) = Brain.parseCommand(text) {
                    guard Brain.shared.ready else {
                        self.setState(.idle)
                        self.paste(text, simplify: true)
                        if Brain.shared.chosenId == nil {
                            Toast.shared.show(L("Похоже на команду Писарю. Включи Мозг: меню Гиги, пункт «Мозг»",
                                                "Sounded like a Pisar command. Turn on the Brain: Giga menu, Brain"))
                        }
                        return
                    }
                    // остаёмся в .busy: точки в строке меню, серая волна — «думаю»
                    self.pendingOperations += 1
                    Brain.shared.transform(body, command: cmd) { out in
                        DispatchQueue.main.async {
                            defer { self.pendingOperations -= 1 }
                            self.saveDictation(out ?? text, take: current)
                            guard self.take == current else { self.notifySavedDictation(); return }
                            self.setState(.idle)
                            if let out {
                                self.paste(out)
                            } else {
                                self.paste(text)
                                Toast.shared.show(Brain.shared.failureText(
                                    L("Писарь не справился — вставил как есть",
                                      "Pisar could not do it — pasted as is")))
                            }
                        }
                    }
                    return
                }
                // "Edit every take": no address needed, the whole take goes through the Brain.
                if Brain.shared.everyTake, Brain.shared.ready {
                    self.pendingOperations += 1
                    Brain.shared.transform(text, command: "исправь") { out in
                        DispatchQueue.main.async {
                            defer { self.pendingOperations -= 1 }
                            self.saveDictation(out ?? text, take: current)
                            guard self.take == current else { self.notifySavedDictation(); return }
                            self.setState(.idle)
                            self.paste(out ?? text, simplify: true)
                            if out == nil {
                                Toast.shared.show(Brain.shared.failureText(
                                    L("Писарь не справился, вставил как есть",
                                      "Pisar could not do it, pasted as is")))
                            }
                        }
                    }
                    return
                }
                self.setState(.idle)
                self.paste(text, offerChips: true, simplify: true)
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

    private func notifySavedDictation() {
        Toast.shared.show(L("Текст готов: меню → Последние диктовки. Автоматически не вставлял.",
                            "Text ready: menu → Recent dictations. Not pasted automatically."))
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
        syntheticKeyUntil = Date().addingTimeInterval(0.4)
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
    func undoInsert(chars: Int, done: @escaping (Bool) -> Void = { _ in }) {
        let current = take, target = takeTarget
        var deletionStarted = false
        func interrupted() {
            Toast.shared.show(deletionStarted
                ? L("Откат прерван: прежний текст мог быть стёрт частично. Диктовки — в меню → Последние диктовки.",
                    "Undo interrupted: previous text may be partly removed. Dictations: menu → Recent dictations.")
                : L("Откат отменён до удаления. Диктовки — в меню → Последние диктовки.",
                    "Undo canceled before deletion. Dictations: menu → Recent dictations."))
            done(false)
        }
        if frontIsTerminal {
            guard chars <= 4000 else { interrupted(); return }
            var remaining = max(0, chars)
            func batch() {
                guard self.take == current, !self.mic.isRecording, !self.rightCmdDown,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
                      matchesDictationFocus(self.takeFocus) else { interrupted(); return }
                if remaining > 0 { deletionStarted = true }
                for _ in 0..<min(25, remaining) { self.pressKey(51, []) }
                remaining -= min(25, remaining)
                if remaining > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.008, execute: batch) }
                else { done(true) }
            }
            batch()
        } else {
            guard !mic.isRecording, NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
                  matchesDictationFocus(takeFocus) else { interrupted(); return }
            pressKey(6, .maskCommand) // ⌘Z
            deletionStarted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard self.take == current, !self.mic.isRecording,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
                      matchesDictationFocus(self.takeFocus) else { interrupted(); return }
                done(true)
            }
        }
    }

    /// Меню Писаря у точки набора. В терминале — в терминальном костюме.
    func showChipsMenu() {
        let current = take
        let p = typingAnchorIfKnown() ?? NSEvent.mouseLocation
        Chips.shared.show(near: p, terminal: frontIsTerminal) { [weak self] cmd in
            guard self?.take == current else { return }
            self?.applyChip(cmd)
        }
    }

    /// Клик по кнопочке: прогнать вставленное через мозг и подменить
    /// (откатываем свою вставку через ⌘Z и вставляем причёсанное).
    func applyChip(_ command: String) {
        guard let text = lastText else { return }
        let current = take, target = takeTarget
        setState(.busy)
        pendingOperations += 1
        Brain.shared.transform(text, command: command) { [weak self] out in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.pendingOperations -= 1 }
                if let out { self.saveDictation(out, take: current) }
                guard self.take == current else {
                    if out != nil { self.notifySavedDictation() }; return
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else {
                    self.setState(.idle)
                    if out != nil { self.notifySavedDictation() }; return
                }
                self.setState(.idle)
                guard let out else {
                    Toast.shared.show(Brain.shared.failureText(
                        L("Писарь не справился — оставил как было",
                          "Pisar could not do it — left it as is")))
                    return
                }
                let original = text
                self.paste(out, replacing: text.count) {
                    // рядом повисает «Вернуть как было» — вдруг не понравилось
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let p = typingAnchorIfKnown() ?? NSEvent.mouseLocation
                        guard self.take == current else { return }
                        Chips.shared.showRevert(near: p, terminal: self.frontIsTerminal) { [weak self] in
                            guard let self, self.take == current else { return }
                            // считаем по вставленному, а не по ответу мозга:
                            // paste мог дописать пробел, и в терминале мы
                            // стираем ровно столько символов, сколько вставили
                            self.paste(original, replacing: self.lastText?.count ?? out.count) {
                                // вернули — и снова предлагаем команды:
                                // меню живёт до Enter или крестика
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    guard self.take == current else { return }
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
    /// Упрощённый синтаксис: одно предложение вставляется как реплика в
    /// переписке — со строчной буквы и без точки в конце. По умолчанию
    /// выключено: в письмах и документах точка нужна.
    var simpleSyntax: Bool {
        get { UserDefaults.standard.bool(forKey: "simpleSyntax") }
        set { UserDefaults.standard.set(newValue, forKey: "simpleSyntax") }
    }

    @objc func toggleSimpleSyntax() {
        simpleSyntax.toggle()
        settingsChanged()
    }

    /// Одно ли это предложение. Знак конца внутри текста (а не в самом
    /// конце) значит, что предложений несколько: тогда не трогаем ничего.
    /// Сокращения вроде «т.д.» тоже попадают под это правило — и хорошо,
    /// угадывать за человека не берёмся.
    func simplified(_ text: String) -> String {
        guard simpleSyntax else { return text }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return text }
        let ends: Set<Character> = [".", "!", "?", "…", ";"]
        guard !t.dropLast().contains(where: { ends.contains($0) }) else { return text }

        var out = t
        // Вопрос и восклицание несут смысл — убираем только точку.
        if out.hasSuffix(".") { out.removeLast() }
        // Аббревиатуру и имя не трогаем: строчной делаем только там, где
        // заглавная стоит просто как начало предложения.
        let firstWord = out.split(separator: " ").first.map(String.init) ?? out
        let allCaps = firstWord.count > 1 && firstWord == firstWord.uppercased()
        if !allCaps, let first = out.first, String(first) != String(first).lowercased() {
            out = String(first).lowercased() + out.dropFirst()
        }
        return out
    }

    /// simplify: only plain dictation goes through «Упрощать синтаксис»; Brain answers,
    /// edits of a selection and «Вернуть как было» are put in exactly as they are.
    func paste(_ text: String, offerChips: Bool = false, spacing: Bool = true, simplify: Bool = false,
               replacing: Int? = nil, completion: (() -> Void)? = nil) {
        var text = simplify ? simplified(text) : text
        if spacing, let last = text.last, !last.isWhitespace { text += " " }
        saveDictation(text, take: take)

        // Вставляем через буфер (быстро и надёжно), но берём его взаймы:
        // прежнее содержимое запоминаем и вернём, как только текст встанет
        // в поле. Если вставить не выйдет — диктовка в буфере и останется,
        // чтобы её можно было вставить самому.
        let current = take
        let target = takeTarget
        let focus = takeFocus
        clipboard.paste(text, allowed: { [weak self] in
            guard let self else { return false }
            return self.take == current && !self.mic.isRecording
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == target
                && matchesDictationFocus(focus)
        }, action: { [weak self] isOurs, done in
            guard let self else { done(false); return }
            let insert = {
                guard self.take == current, !self.mic.isRecording,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
                      matchesDictationFocus(focus) else {
                    if replacing != nil {
                        Toast.shared.show(L("Старый текст мог быть удалён; вставка остановлена. Новый текст — в меню → Последние диктовки.",
                                            "Previous text may be removed; paste stopped. New text: menu → Recent dictations."))
                    } else { self.notifySavedDictation() }
                    done(true); return
                }
                guard isOurs() else {
                    Toast.shared.show(L("Буфер изменился, вставка остановлена. Прежний текст мог быть удалён при замене; диктовка — в меню → Последние диктовки.",
                                        "Clipboard changed; paste stopped. Previous text may have been removed during replacement; dictation: menu → Recent dictations."))
                    done(false); return
                }
                let result = self.finishPaste(offerChips: offerChips, isOurs: isOurs)
                if result { self.lastText = text; completion?() }
                done(result)
            }
            if let replacing, AXIsProcessTrusted() || CGPreflightPostEventAccess() {
                self.undoInsert(chars: replacing) { success in
                    if success { insert() } else { done(true) }
                }
            } else { insert() }
        }, failed: {
            Toast.shared.show(L("Вставка недоступна. Текст сохранён: меню → Последние диктовки.",
                                "Paste unavailable. Text saved: menu → Recent dictations."))
        })
    }

    private func finishPaste(offerChips: Bool, isOurs: () -> Bool) -> Bool {
        let current = take

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
            Toast.shared.show(L("Текст в буфере. Для вставки разреши Giga Pisar Универсальный доступ.",
                                "Text is on the clipboard. Allow Giga Pisar Accessibility access to paste."))
            return false
        }
        guard isOurs() else {
            Toast.shared.show(L("Буфер изменился: вставка остановлена. После замены проверь прежний текст; диктовка сохранена в меню.",
                                "Clipboard changed: paste stopped. Check previous text after replacement; dictation is saved in the menu."))
            return false
        }
        pressKey(9, .maskCommand) // ⌘V
        if inField {
            // Буфер возвращаем человеку. Проверять, дошла ли вставка на самом
            // деле, мы пробовали — по каретке и числу символов в поле, — и от
            // этого пришлось отказаться: Electron (VS Code и плагины в нём)
            // отвечает Accessibility как попало, и проверка объявляла неудачу
            // поверх удавшейся вставки.
            // Менюшка: сырой текст вставлен, предложить причесать.
            if offerChips, Brain.shared.ready, Brain.shared.chipsEnabled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard self?.take == current else { return }
                    self?.showChipsMenu()
                }
            }
        } else {
            Toast.shared.show(L("Курсор был не в тексте — диктовка в буфере, нажми ⌘V",
                                "The cursor wasn't in a text field — your dictation is on the clipboard, press ⌘V"))
        }
        return inField
    }
}

// Diagnostics: `Giga --brain-test in.txt` runs the saved Brain settings on the text
// ("… Писарь, <command>" or plain text as "исправь") and prints the answer.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--brain-test" {
    let input = ((try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty, Brain.shared.ready else {
        print("brain-test: empty input or the Brain is not set up (choice: \(Brain.shared.chosenId ?? "off"))")
        exit(2)
    }
    let parsed = Brain.parseCommand(input)
    let started = Date()
    var result: String?
    var finished = false
    Brain.shared.transform(parsed?.body ?? input, command: parsed?.command ?? "исправь") { out in
        result = out
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    print("brain=\(Brain.shared.chosenId ?? "off") command=\(parsed?.command ?? "(every take)") ms=\(ms)")
    print(result ?? "FAILED: \(Brain.shared.failureText("no answer"))")
    Brain.shared.stopServer()
    exit(result == nil ? 1 : 0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory) // без иконки в доке
app.run()
