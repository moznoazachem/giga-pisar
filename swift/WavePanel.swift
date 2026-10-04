// Плашка с волной голоса рядом с местом набора текста.
//
// Волна в строке меню наверху видна плохо, когда экран большой и смотришь
// на курсор. Эта плашка появляется у текстовой каретки (спрашиваем через
// Accessibility, разрешение и так есть), а если каретку не отдали —
// у указателя мыши. Столбики показывают настоящую громкость с микрофона
// (среднеквадратичную, в децибелах): молчишь — лежат, говоришь — пляшут.
// Инерцию, из-за которой честная волна раньше выглядела вялой, снимает
// разная скорость вверх и вниз — см. tick(level:).

import AppKit

// Bound the WHOLE synchronous query, not each of hundreds of menu attributes.
// An unresponsive target falls back to the mouse/unknown focus, with a cooldown.
enum AXBudget {
    static var depth = 0
    static var deadline: TimeInterval = 0
    static var retryAfter: [pid_t: TimeInterval] = [:]
    static var sawCannotComplete = false
    static func enter() {
        precondition(Thread.isMainThread)
        if depth == 0 {
            deadline = ProcessInfo.processInfo.systemUptime + 0.12
            sawCannotComplete = false
        }
        depth += 1
    }
    static func leave() { depth -= 1 }
    static func call(_ element: AXUIElement, _ body: () -> AXError) -> AXError {
        let now = ProcessInfo.processInfo.systemUptime
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        let remaining = deadline - now
        guard now >= (retryAfter[pid] ?? 0), remaining >= 0.03 else {
            sawCannotComplete = true; return .cannotComplete
        }
        AXUIElementSetMessagingTimeout(element, Float(remaining))
        let result = body()
        if result == .cannotComplete {
            sawCannotComplete = true
            if remaining >= 0.1, ProcessInfo.processInfo.systemUptime - now >= remaining * 0.8 {
                retryAfter[pid] = ProcessInfo.processInfo.systemUptime + 2
            }
        }
        return result
    }
}

private func axCopy(_ element: AXUIElement, _ name: CFString,
                    _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    AXBudget.call(element) { AXUIElementCopyAttributeValue(element, name, value) }
}

private func axParameterized(_ element: AXUIElement, _ name: CFString,
                             _ parameter: CFTypeRef, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    AXBudget.call(element) { AXUIElementCopyParameterizedAttributeValue(element, name, parameter, value) }
}

/// Где сейчас набирается текст. По убыванию точности:
/// каретка активного поля → низ самого поля → низ активного окна →
/// указатель мыши. На виртуальных машинах Accessibility часто молчит
/// и про каретку, и про поле — раньше плашка сваливалась к мыши,
/// которая лежит где попало, и «появлялась в разных концах экрана».
func typingAnchor() -> NSPoint {
    if let p = typingAnchorIfKnown(log: true) { return p }
    NSLog("Гига якорь: мышь \(NSEvent.mouseLocation)")
    return NSEvent.mouseLocation
}

/// Якорь без запасного варианта «мышь» — для слежения во время записи:
/// за окном с кареткой плашка ходить должна, а за мышью — нет.
func typingAnchorIfKnown(log: Bool = false) -> NSPoint? {
    AXBudget.enter(); defer { AXBudget.leave() }
    let field = focusedFieldFrame()
    if let p = caretPoint() {
        // Каретка обязана лежать в своём поле. Точка вне поля — враньё
        // (виртуалки и терминалы любят так отвечать), не верим ей.
        if field == nil || field!.insetBy(dx: -40, dy: -40).contains(p) {
            if log { NSLog("Гига якорь: каретка \(p)") }
            return p
        }
        if log { NSLog("Гига якорь: каретка \(p) вне поля \(field!) — мусор") }
    }
    if let f = field {
        if log { NSLog("Гига якорь: поле \(f)") }
        return NSPoint(x: f.midX, y: f.minY + 30)
    }
    if let w = focusedWindowFrame() {
        if log { NSLog("Гига якорь: окно \(w)") }
        return NSPoint(x: w.midX, y: w.minY + 60)
    }
    return nil
}

// MARK: - разговор с Accessibility

func dictationFocus() -> AXUIElement? {
    AXBudget.enter(); defer { AXBudget.leave() }
    return axFocusedElement()
}

func matchesDictationFocus(_ original: AXUIElement?, current read: () -> AXUIElement? = dictationFocus) -> Bool {
    // Some terminal/Chromium targets expose no stable AX field; PID remains
    // the fallback there. Never pretend it proves identity of a document.
    guard let original else { return true }
    guard let current = read() else { return false }
    return CFEqual(original, current)
}

/// Элемент, в котором сейчас клавиатурный фокус.
private func axFocusedElement() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    var ref: CFTypeRef?
    guard axCopy(AXUIElementCreateApplication(app.processIdentifier),
                                        "AXFocusedUIElement" as CFString,
                                        &ref) == .success,
          let f = ref, CFGetTypeID(f) == AXUIElementGetTypeID()
    else { return nil }
    return (f as! AXUIElement)
}

/// Положение курсора набора (выделения) в фокусном элементе.
private func axSelectedRange(_ el: AXUIElement) -> CFRange? {
    var ref: CFTypeRef?
    guard axCopy(el, "AXSelectedTextRange" as CFString,
                                        &ref) == .success,
          let v = ref, CFGetTypeID(v) == AXValueGetTypeID()
    else { return nil }
    var r = CFRange()
    guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
    return r
}

/// AX отдаёт координаты от левого ВЕРХНЕГО угла главного экрана,
/// кокоа считает от левого нижнего — переворачиваем.
private func axFlip(_ rect: CGRect) -> NSRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height,
                  width: rect.width, height: rect.height)
}

/// Мусор или настоящее место? Настоящее лежит на каком-то из экранов.
private func axOnScreen(_ r: NSRect) -> Bool {
    NSScreen.screens.contains { $0.frame.insetBy(dx: -2, dy: -2).intersects(r) }
}

/// Границы куска текста, если приложение их честно отдало.
private func axBounds(_ el: AXUIElement, _ range: CFRange) -> NSRect? {
    var r = range
    guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
    var ref: CFTypeRef?
    guard axParameterized(
        el, "AXBoundsForRange" as CFString, rv, &ref) == .success,
          let b = ref, CFGetTypeID(b) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(b as! AXValue, .cgRect, &rect) else { return nil }
    // Настоящая каретка — коробочка высотой со строку текста. Нулевые
    // и небоскрёбные прямоугольники — ложь (терминалы любят отдать
    // нулевую точку в углу экрана, и плашка уезжала туда за ней).
    guard rect.height >= 4, rect.height <= 300 else { return nil }
    let out = axFlip(rect)
    guard axOnScreen(out) else { return nil }
    return out
}

/// Текст, выделенный в фокусном поле. nil — выделения нет (или приложение
/// его не отдаёт: Chrome и Electron через раз, терминалы никогда).
/// Сначала спрашиваем сам текст (AXSelectedText); если его нет, но диапазон
/// выделения непустой, вызывающий может добыть текст через ⌘C.
/// silent — приложение про выделение не говорит вообще ничего: Pages,
/// Keynote и Numbers рисуют текст на своём холсте, в фокусе у них
/// AXScrollArea без единого текстового атрибута. Тогда о выделении судим
/// по пункту «Скопировать» в меню (frontMenuShortcutEnabled).
func selectedTextViaAX() -> (text: String?, length: Int, silent: Bool) {
    AXBudget.enter(); defer { AXBudget.leave() }
    guard let el = axFocusedElement(), let sel = axSelectedRange(el)
    else { return (nil, 0, true) }
    guard sel.length > 0 else { return (nil, 0, false) }
    var ref: CFTypeRef?
    if axCopy(el, "AXSelectedText" as CFString, &ref) == .success,
       let s = ref as? String,
       !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return (s, Int(sel.length), false)
    }
    return (nil, Int(sel.length), false)
}

/// Включён ли в меню активного приложения пункт с сочетанием ⌘+буква без
/// других модификаторов. «Скопировать» включён, только когда что-то
/// выделено, «Вставить» — когда есть куда вставлять: так узнаём то, о чём
/// приложение молчит в Accessibility. Обход меню занимает десятки
/// миллисекунд, поэтому зовём его только для молчунов.
func frontMenuShortcutEnabled(_ char: String) -> Bool {
    AXBudget.enter(); defer { AXBudget.leave() }
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return axCopy(e, n as CFString, &v) == .success ? v : nil
    }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    guard let bar = attr(ax, "AXMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID()
    else { return false }
    for top in (attr(bar as! AXUIElement, "AXChildren") as? [AXUIElement] ?? []) {
        for menu in (attr(top, "AXChildren") as? [AXUIElement] ?? []) {
            for item in (attr(menu, "AXChildren") as? [AXUIElement] ?? []) {
                guard (attr(item, "AXMenuItemCmdChar") as? String) == char,
                      (attr(item, "AXMenuItemCmdModifiers") as? Int) == 0 else { continue }
                return (attr(item, "AXEnabled") as? Bool) ?? false
            }
        }
    }
    return false
}

/// Что известно про фокус: поле есть, поля нет — или приложение молчит.
/// Молчание не значит «нет»: Chromium и всё, что на нём (Electron, Cursor,
/// VS Code), строит дерево доступности лениво и до первого запроса не отдаёт
/// даже фокусный элемент. Принимать это за «курсор не в тексте» — значит
/// ругаться на удавшуюся вставку.
enum TextFocus { case field, notField, unknown }

/// Роли, в которые ⌘V попадёт. Одного диапазона выделения мало: Finder,
/// когда курсор нигде не стоит, отдаёт AXGroup, и диапазон у него тоже есть —
/// по нему мы принимали рабочий стол за текстовое поле.
private let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox",
                                      "AXSecureTextField", "AXSearchField"]

func textFocus() -> TextFocus {
    AXBudget.enter(); defer { AXBudget.leave() }
    guard let el = axFocusedElement() else {
        // Молчит. Первое молчание от этого приложения — повод разбудить
        // дерево и поверить на слово: скорее всего это Chromium, который
        // ещё не проснулся. Молчит и после побудки — значит фокуса
        // действительно нет.
        let incomplete = AXBudget.sawCannotComplete
        let woke = wakeAccessibility()
        return incomplete || AXBudget.sawCannotComplete || woke ? .unknown : .notField
    }
    // Pages и родня диапазона не отдают, но вставка у них работает:
    // спрашиваем про пункт «Вставить» в меню.
    guard axSelectedRange(el) != nil else {
        let enabled = frontMenuShortcutEnabled("V")
        return AXBudget.sawCannotComplete ? .unknown : (enabled ? .field : .notField)
    }
    var ref: CFTypeRef?
    let role = (axCopy(el, "AXRole" as CFString, &ref) == .success
                ? ref as? String : nil) ?? ""
    return AXBudget.sawCannotComplete ? .unknown : (textRoles.contains(role) ? .field : .notField)
}

/// Просьба к Chromium построить дерево доступности. Ключа два, оба
/// исторические: на AXManualAccessibility отзывается Electron,
/// на AXEnhancedUserInterface — сам Chromium и часть старых приложений.
/// Дерево появляется не сразу, поэтому первая диктовка в такое окно
/// всё равно пройдёт вслепую.
/// Возвращает true, если это приложение мы будим впервые: тогда его
/// молчанию даётся один заход форы.
private var wokenApps = Set<String>()

@discardableResult
private func wakeAccessibility() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    let id = String(app.processIdentifier)
    guard !wokenApps.contains(id) else { return false }
    let el = AXUIElementCreateApplication(app.processIdentifier)
    let first = AXBudget.call(el) { AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
    let second = AXBudget.call(el) { AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    if first != .cannotComplete, second != .cannotComplete { wokenApps.insert(id) }
    return true
}

/// Есть ли сейчас фокус в текстовом поле (даже если оно скрывает,
/// ГДЕ каретка): по этому решаем, вставится ли ⌘V.
func hasTextFocus() -> Bool { textFocus() == .field }

/// Точка текстовой каретки (низ) в кокоа-координатах, если приложение
/// отдаёт её честно. Пустое выделение часто отдаёт мусорные границы —
/// тогда спрашиваем про соседний символ и берём его КРАЙ, обращённый
/// к курсору. Ответы шире 60 пунктов — враньё (терминалы любят отдать
/// коробку во всю строку, и плашка вставала в её середину, а не у курсора).
func caretPoint() -> NSPoint? {
    AXBudget.enter(); defer { AXBudget.leave() }
    guard let el = axFocusedElement(), let sel = axSelectedRange(el) else { return nil }
    // сам пустой курсор — узкая коробочка
    if let r = axBounds(el, sel), r.width <= 60 {
        return NSPoint(x: r.midX, y: r.minY)
    }
    // символ ПЕРЕД кареткой: курсор у его правого края
    if sel.location > 0,
       let r = axBounds(el, CFRange(location: sel.location - 1, length: 1)), r.width <= 60 {
        return NSPoint(x: r.maxX, y: r.minY)
    }
    // символ ПОСЛЕ каретки: курсор у его левого края
    if let r = axBounds(el, CFRange(location: sel.location, length: 1)), r.width <= 60 {
        return NSPoint(x: r.minX, y: r.minY)
    }
    return nil
}

/// Рамка активного окна — предпоследний якорь. Окно система знает
/// всегда, даже когда про каретку и поле отмалчивается (виртуалки).
func focusedWindowFrame() -> NSRect? {
    AXBudget.enter(); defer { AXBudget.leave() }
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let a = AXUIElementCreateApplication(app.processIdentifier)
    var winRef: CFTypeRef?
    guard axCopy(a,
                                        "AXFocusedWindow" as CFString,
                                        &winRef) == .success,
          let w = winRef, CFGetTypeID(w) == AXUIElementGetTypeID()
    else { return nil }
    let win = w as! AXUIElement
    var posRef: CFTypeRef?, sizeRef: CFTypeRef?
    guard axCopy(win, "AXPosition" as CFString, &posRef) == .success,
          axCopy(win, "AXSize" as CFString, &sizeRef) == .success,
          let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID(),
          let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID()
    else { return nil }
    var pos = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &pos),
          AXValueGetValue(sv as! AXValue, .cgSize, &size),
          size.height > 0
    else { return nil }
    let out = axFlip(CGRect(origin: pos, size: size))
    guard axOnScreen(out) else { return nil }
    return out
}

/// Рамка фокусного поля — запасной якорь, когда каретку скрывают.
func focusedFieldFrame() -> NSRect? {
    AXBudget.enter(); defer { AXBudget.leave() }
    guard let el = axFocusedElement() else { return nil }
    var ref: CFTypeRef?
    guard axCopy(el, "AXFrame" as CFString, &ref) == .success,
          let v = ref, CFGetTypeID(v) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
    let out = axFlip(rect)
    guard axOnScreen(out) else { return nil }
    return out
}

final class WaveView: NSView {
    var busy = false

    /// Текст вместо столбиков. nil — обычная волна. Одна плашка на оба
    /// состояния: раньше сообщения показывало отдельное окно, и оно
    /// налезало на волну, когда оба оказывались нужны разом.
    var text: String? {
        didSet { if text != oldValue { needsDisplay = true } }
    }

    static let textFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// Пока мозг работает, по надписи бежит блик: сообщение висит
    /// секундами, и неподвижная строка выглядит зависшей.
    var shimmer = false { didSet { if shimmer != oldValue { needsDisplay = true } } }
    var phase: CGFloat = 0   // 0…1, положение блика

    /// Буквы в виде картинки — ею вырезаем блик, чтобы он ложился
    /// на текст, а не на плашку. Пересобирается при смене надписи.
    private var maskCache: NSImage?
    private var maskText = ""
    private var maskSize = NSSize.zero

    /// Сколько столбиков в плашке.
    static let bars = 13

    /// Высоты столбиков, 0…1. Наружу отданы затем, что этими же числами
    /// кормится иконка в строке меню: две волны об одном и том же звуке
    /// и обязаны идти в такт.
    private(set) var heights = [CGFloat](repeating: 0, count: WaveView.bars)

    /// Сглаженная громкость 0…1 — показываем её, а не сырую: сырая
    /// дёргается покадрово и читается как рябь.
    private var level: CGFloat = 0

    /// Своя доля громкости у каждого столбика и своё опоздание в кадрах.
    /// Перебрасываются РАЗ НА ВСПЛЕСК, а не каждый кадр: покадровый
    /// рандом читается как дрожь, а разовый — как живой голос, от
    /// которого столбики дёрнулись вразнобой и снова замерли.
    private var gain = [CGFloat](repeating: 1, count: WaveView.bars)
    private var lag = [Int](repeating: 0, count: WaveView.bars)

    /// Кадров с начала всплеска; nil — столбики просто стоят на громкости.
    private var burst: Int?

    /// Насколько громче должно стать, чтобы это считалось всплеском,
    /// и на сколько кадров столбики могут разъехаться внутри него
    /// (9 кадров — это 150 мс).
    private static let burstTrigger: CGFloat = 0.1
    private static let burstSpread = 9

    // Кадр — 1/60 секунды, и все доли ниже посчитаны под него. Если
    // менять частоту таймера в main.swift — пересчитывать и их:
    // доля за кадр = 1 − (1 − прежняя доля)^(прежняя частота / новая).
    private static let riseRate: CGFloat = 0.75      // подъём, ~30 мс до цели
    private static let fallRate: CGFloat = 0.13      // спад на тихой речи, ~120 мс
    private static let fallLoud: CGFloat = 0.45      // добавка к спаду на полной громкости

    /// Кадров с прошлой пересыпки — по нему громкий голос гонит
    /// столбики дальше, не дожидаясь нового всплеска.
    private var sinceRoll = 0

    /// Масштаб появления, 1 — плашка в полный рост.
    var scale: CGFloat = 1

    /// Откуда растёт плашка. У курсора — из левого верхнего угла: там
    /// каретка, и плашка будто выпрыгивает из-под неё. Внизу экрана
    /// каретки рядом нет, привязываться не к чему — растём из середины.
    var popFromCenter = false

    /// С какой громкости плашка начинает частить.
    private static let livelyFrom: CGFloat = 0.35

    /// Горка: середина выше краёв, чтобы плашка читалась волной,
    /// а не забором. Считаем от места столбика в ряду.
    private static func shape(_ i: Int) -> CGFloat {
        0.72 + 0.28 * sin(CGFloat.pi * (CGFloat(i) + 0.5) / CGFloat(bars))
    }

    // Перетаскивание ведём сами, без isMovableByWindowBackground:
    // так «пользователь перетащил» — это буквально нажатие мышью
    // по плашке с движением, и спутать его с программным переездом
    // (чем страдали 2.3 и первая 2.4) невозможно по построению.
    private var dragMouse: NSPoint?
    private var dragOrigin: NSPoint?
    private var dragged = false
    var dragging: Bool { dragMouse != nil }

    override func mouseDown(with e: NSEvent) {
        dragMouse = NSEvent.mouseLocation
        dragOrigin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let m0 = dragMouse, let o0 = dragOrigin, let w = window else { return }
        let m = NSEvent.mouseLocation
        if abs(m.x - m0.x) + abs(m.y - m0.y) > 3 { dragged = true }
        w.setFrameOrigin(NSPoint(x: o0.x + m.x - m0.x, y: o0.y + m.y - m0.y))
    }

    override func mouseUp(with e: NSEvent) {
        // Прибиваем только плашку у курсора: у нижней место задано выбором
        // в меню, и запомненный перетаскиванием угол спорил бы с ним.
        if dragged, WavePanel.place == .cursor, let w = window {
            WavePanel.pinned = w.frame.origin
            NSLog("Гига волна: перетащена и прибита к \(w.frame.origin)")
        }
        dragMouse = nil; dragOrigin = nil; dragged = false
    }

    /// Кадр волны по свежей громкости с микрофона. Вверх — почти рывком
    /// (голос должен попадать в столбик в тот же кадр, иначе волна
    /// плетётся за речью), вниз — медленнее, иначе столбики рушатся
    /// в паузах между слогами и волна начинает мигать.
    /// Новая раскладка столбиков. Чем громче голос, тем шире разброс
    /// высот и тем теснее столбики по времени: на крике они должны
    /// разлетаться, на тихой речи — вести себя смирно.
    private func roll() {
        let low = 0.75 - 0.55 * level
        let spread = max(3, Self.burstSpread - Int(6 * level))
        for i in 0..<Self.bars {
            gain[i] = CGFloat.random(in: low...1.0)
            lag[i] = Int.random(in: 0...spread)
        }
        burst = 0
        sinceRoll = 0
    }

    func tick(level target: CGFloat) {
        let rise = target - level
        level += rise * (rise > 0 ? Self.riseRate : Self.fallRate)
        sinceRoll += 1

        // Голос прибавил — всплеск: каждый столбик берёт себе новую долю
        // громкости и новое опоздание. Пока прошлый всплеск не отыграл,
        // новый не начинаем, иначе доли перебрасывались бы каждый кадр
        // и вернулась бы дрожь.
        if rise > Self.burstTrigger, burst == nil {
            roll()
        } else if level > Self.livelyFrom, sinceRoll >= max(4, Int(18 - 15 * level)) {
            // А пока голос громкий, столбики пересыпаются и сами, без
            // нового всплеска: на полной громкости раз в 100 мс, у порога
            // — втрое реже. Честной громкости в этом уже нет, это
            // украшение: на крике плашка должна выглядеть так же бойко,
            // как звучит голос, а громкость к тому времени упёрлась
            // в потолок и сама по себе перестала что-либо показывать.
            roll()
        }

        for i in 0..<heights.count {
            // столбик, чья очередь ещё не подошла, стоит как стоял —
            // от этого всплеск и выглядит разнобоем, а не общим прыжком
            if let age = burst, age < lag[i] { continue }
            let target = level * Self.shape(i) * gain[i]
            // Вверх столбик идёт всегда рывком, вниз — тем резче, чем
            // громче голос: на тихой речи оседает плавно, на громкой
            // рушится почти мгновенно. Отсюда и размах: на крике столбики
            // не покачиваются около одной высоты, а рушатся и взлетают.
            let speed = target > heights[i] ? Self.riseRate
                                             : Self.fallRate + Self.fallLoud * level
            heights[i] += (target - heights[i]) * speed
        }

        if let age = burst { burst = age < Self.burstSpread ? age + 1 : nil }
        needsDisplay = true
    }

    /// Полоса света, бегущая по буквам. Рисуем градиент во всю плашку
    /// и вырезаем его буквами: залить сам текст градиентом иначе нельзя —
    /// заливка легла бы и на плашку под ним.
    private func shine(_ text: String, at point: NSPoint) {
        let band: CGFloat = 70
        let x = -band + phase * (bounds.width + band * 2)
        // Не «прозрачный → цвет → прозрачный», а с полкой в середине:
        // на голом остром пике цвет успевал показаться только краем
        // и на тёмных буквах выглядел блёклым. Полка даёт буквам
        // побыть полностью цветными.
        // Ядро полосы — цвет плашки вполсилы: буквы под ним не пропадают,
        // а светлеют примерно наполовину, будто волна их смывает. Само ядро
        // узкое, шестнадцатая часть полосы; всё остальное — длинные скаты,
        // иначе смыв читался бы как дыра в надписи, а не как блик.
        guard let g = NSGradient(colors: [Self.shineColor.withAlphaComponent(0),
                                          Self.shineColor.withAlphaComponent(0.34),
                                          Self.shineColor.withAlphaComponent(0.5),
                                          Self.shineColor.withAlphaComponent(0.5),
                                          Self.shineColor.withAlphaComponent(0.34),
                                          Self.shineColor.withAlphaComponent(0)],
                                 atLocations: [0, 0.30, 0.47, 0.53, 0.70, 1],
                                 colorSpace: .sRGB)
        else { return }
        let overlay = NSImage(size: bounds.size)
        overlay.lockFocus()
        g.draw(in: NSRect(x: x, y: 0, width: band, height: bounds.height), angle: 0)
        mask(text, at: point).draw(in: NSRect(origin: .zero, size: bounds.size),
                                    from: .zero, operation: .destinationIn, fraction: 1)
        overlay.unlockFocus()
        // Один проход: плотность задаёт сам градиент. Раньше слой рисовался
        // дважды — это было нужно цветному блику, чтобы он не смешивался
        // с чёрным в грязь, но белому лишняя плотность ни к чему.
        overlay.draw(in: bounds)
    }

    /// Цвет блика — цвет самой плашки: волна не красит буквы, а смывает их.
    static let shineColor = NSColor.white

    /// Буквы непрозрачным чёрным — от маски нужна только форма. Рисовать
    /// её тем же светло-серым нельзя: сквозь бледную маску и блик вышел бы
    /// бледным, а он должен идти в полную силу.
    private func mask(_ text: String, at point: NSPoint) -> NSImage {
        if let m = maskCache, maskText == text, maskSize == bounds.size { return m }
        let s = NSAttributedString(string: text,
                                   attributes: [.font: Self.textFont,
                                                .foregroundColor: NSColor.black])
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        s.draw(at: point)
        img.unlockFocus()
        maskCache = img
        maskText = text
        maskSize = bounds.size
        return img
    }

    override func draw(_ dirtyRect: NSRect) {
        let growing = scale != 1
        if growing {
            NSGraphicsContext.saveGraphicsState()
            let anchor = popFromCenter ? NSPoint(x: bounds.midX, y: bounds.midY)
                                      : NSPoint(x: 0, y: bounds.height)
            let t = NSAffineTransform()
            t.translateX(by: anchor.x, yBy: anchor.y)
            t.scaleX(by: scale, yBy: scale)
            t.translateX(by: -anchor.x, yBy: -anchor.y)
            t.concat()
        }
        defer { if growing { NSGraphicsContext.restoreGraphicsState() } }

        // светлая плашка: белая, с тонкой окантовкой, чтобы читалась
        // и на белом фоне, и на тёмном
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.white.withAlphaComponent(0.96).setFill()
        pill.fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        if let text {
            let s = NSAttributedString(
                string: text,
                attributes: [.font: Self.textFont,
                             .foregroundColor: NSColor.black.withAlphaComponent(0.85)])
            let sz = s.size()
            let point = NSPoint(x: (bounds.width - sz.width) / 2,
                                y: (bounds.height - sz.height) / 2)
            s.draw(at: point)
            if shimmer { shine(text, at: point) }
            return
        }

        let bars = heights.count
        // 13 столбиков: 2,5 пункта ширины с зазором 1,5, поля по краям
        // почти по девять. Шире ряд делать некуда — крайний столбик
        // полез бы за скруглённый торец плашки.
        let barW: CGFloat = 2.5
        let gap: CGFloat = 1.5
        let totalW = CGFloat(bars) * barW + CGFloat(bars - 1) * gap
        let x0 = (bounds.width - totalW) / 2
        // Полей сверху и снизу — по пункту: столбик на всплеске должен
        // выстреливать во всю плашку, иначе размах пропадает даром.
        let maxH = bounds.height - 2

        // цвет столбиков выбирается в меню приложения
        let chosen = UserDefaults.standard.string(forKey: "waveColor") ?? "dark"
        let barColor: NSColor = chosen == "green" ? .systemGreen
            : chosen == "red" ? .systemRed
            : .black.withAlphaComponent(0.78)
        // Пока Писарь думает, плашка остаётся на месте и синеет: работа
        // не кончилась, текст сейчас появится — а серые столбики
        // выглядели так, будто волна умерла.
        (busy ? busyColor : barColor).setFill()
        // В покое столбик должен быть кружком, а не лежачим овалом:
        // нижний предел высоты равен ширине. Вертикальный овал —
        // это barW * 1.75.
        let restH = barW
        for i in 0..<bars {
            let sway = busy ? BUSY_BAR : heights[i]
            let h = max(restH, maxH * sway)
            let r = NSRect(x: x0 + CGFloat(i) * (barW + gap),
                           y: (bounds.height - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}

/// Сообщения Писаря. Отдельным окном они были раньше и налезали на волну;
/// теперь это её же плашка в текстовом состоянии. Имя оставлено, чтобы
/// не переписывать полтора десятка мест, которые ею говорят.
enum Toast {
    static let shared = Toast.self

    static func show(_ text: String, seconds: Double = 3.5, near point: NSPoint? = nil) {
        WavePanel.shared.say(text, seconds: seconds, near: point)
    }

    /// Липкая плашка-статус: висит, пока не позовут hide().
    static func showSticky(_ text: String) { show(text, seconds: 0) }

    static func hide() { WavePanel.shared.saidEnough() }
}

final class WavePanel {
    /// Плашка одна на приложение: и волна, и сообщения — её состояния.
    static let shared = WavePanel()

    private let panel: NSPanel
    private let view = WaveView()
    private var popTimer: Timer?

    /// Где показывать плашку: у каретки или внизу экрана. Выбирается в меню.
    enum Place: String {
        case cursor, bottom

        /// Насколько высоко над низом экрана висит нижняя плашка.
        static let bottomShare: CGFloat = 0.10
    }

    static var place: Place {
        get { Place(rawValue: UserDefaults.standard.string(forKey: "wavePlace") ?? "") ?? .cursor }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "wavePlace") }
    }

    /// Куда пользователь перетащил плашку. Пока не таскал — nil,
    /// и плашка ходит за текстовой кареткой.
    static var pinned: NSPoint? {
        get {
            guard let s = UserDefaults.standard.string(forKey: "wavePos") else { return nil }
            let parts = s.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
        }
        set {
            if let p = newValue {
                UserDefaults.standard.set("\(p.x),\(p.y)", forKey: "wavePos")
            } else {
                UserDefaults.standard.removeObject(forKey: "wavePos")
            }
        }
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 68, height: 26),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view

        // Перетаскивание (и только его!) ловит сама WaveView — см. mouseUp.
    }

    /// Место плашки для данного якоря. Внизу экрана — по центру и на
    /// десятой части высоты от низа. У каретки — прибитое, если плашку
    /// перетаскивали, иначе чуть ниже и правее точки набора. И в любом
    /// случае не за краем экрана.
    private func clampedOrigin(for p: NSPoint, size: NSSize? = nil) -> NSPoint {
        let size = size ?? panel.frame.size
        let bottom = Self.place == .bottom
        // экран берём тот, где идёт набор: у нижней плашки тоже — она
        // должна висеть на том мониторе, куда человек смотрит
        let anchor = bottom ? p : (Self.pinned ?? p)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main

        var origin: NSPoint
        if bottom, let s = screen {
            origin = NSPoint(x: s.frame.midX - size.width / 2,
                             y: s.frame.minY + s.frame.height * Place.bottomShare)
        } else {
            origin = Self.pinned ?? NSPoint(x: p.x + 14, y: p.y - size.height - 10)
        }
        if let f = screen?.visibleFrame {
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        return origin
    }

    /// Размер плашки: у волны свой, у текста — по длине надписи.
    private static let barsSize = NSSize(width: 68, height: 26)

    private static func size(for text: String) -> NSSize {
        let w = NSAttributedString(string: text,
                                   attributes: [.font: WaveView.textFont]).size().width
        let screen = (NSScreen.main?.visibleFrame.width ?? 1200) - 80
        return NSSize(width: min(max(ceil(w) + 28, barsSize.width), screen),
                      height: barsSize.height)
    }

    /// Нужна ли волна прямо сейчас. По ней решаем, куда возвращаться,
    /// когда сообщение отвисит своё: к столбикам или в никуда.
    private var barsWanted = false

    /// Номер показа: по нему сообщение узнаёт, не пришло ли следом другое.
    private var generation = 0

    private var sizeTimer: Timer?
    private var shimmerTimer: Timer?

    func show(near p: NSPoint) {
        barsWanted = true
        generation += 1
        view.text = nil
        view.busy = false // прошлая диктовка кончилась «думаю» — гасим синеву
        present(size: Self.barsSize, near: p)
    }

    /// Сообщение в той же плашке. seconds = 0 — висит, пока не позовут
    /// hide(): так Мозг Писаря держит «Причёсываю…» всё время работы.
    func say(_ text: String, seconds: Double = 3.5, near point: NSPoint? = nil) {
        generation += 1
        let g = generation
        view.busy = false
        view.text = text
        // Липкое сообщение вешает только мозг, пока работает, — по нему
        // и пускаем блик. У обычных сообщений свой срок, они и так живые.
        shine(seconds == 0)
        present(size: Self.size(for: text),
                 near: point ?? typingAnchorIfKnown() ?? NSEvent.mouseLocation,
                 explicit: point != nil)
        guard seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == g else { return }
            self.saidEnough()
        }
    }

    /// Сообщение отговорило: если волна всё ещё нужна — возвращаемся
    /// к столбикам, иначе плашка уходит.
    func saidEnough() {
        generation += 1
        shine(false)
        // Текст снимаем ПЕРВЫМ делом: hide() намеренно не гасит плашку
        // с висящим сообщением, и если сбросить текст после, она так
        // и останется на экране.
        view.text = nil
        guard barsWanted else { hide(); return }
        resize(to: Self.barsSize)
    }

    /// Показать плашку нужного размера: если её ещё нет — с прыжком,
    /// если уже висит — плавно переехав из прежнего размера.
    /// явный — место задано снаружи (скажем, под иконкой в строке меню):
    /// такому сообщению плашка переезжает, а не раздаётся на месте.
    private func present(size: NSSize, near p: NSPoint, explicit: Bool = false) {
        if panel.isVisible {
            if explicit {
                move(to: NSRect(origin: clampedOrigin(for: p, size: size), size: size))
            } else {
                resize(to: size)
            }
            return
        }
        sizeTimer?.invalidate()
        let origin = clampedOrigin(for: p, size: size)
        NSLog("Гига волна: показ в \(origin)\(Self.pinned != nil ? " (прибита)" : "")")
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        pop()
    }

    /// Смена размера на месте. Плашка раздаётся из своего якоря: внизу
    /// экрана — из середины (центр стоит, края расходятся), у курсора —
    /// от левого верхнего угла (он стоит, плашка растёт вправо). Якорь
    /// берём у нынешней рамки, а не спрашиваем каретку заново: пока висело
    /// сообщение, курсор мог уехать, и плашка прыгнула бы вслед за ним.
    private func resize(to size: NSSize) {
        sizeTimer?.invalidate()
        let from = panel.frame
        var corner: NSPoint
        if Self.place == .bottom {
            corner = NSPoint(x: from.midX - size.width / 2, y: from.minY)
        } else {
            corner = NSPoint(x: from.minX, y: from.maxY - size.height)
        }
        if let f = (NSScreen.screens.first { $0.frame.intersects(from) } ?? NSScreen.main)?.visibleFrame {
            corner.x = min(max(corner.x, f.minX + 4), f.maxX - size.width - 4)
            corner.y = min(max(corner.y, f.minY + 4), f.maxY - size.height - 4)
        }
        move(to: NSRect(origin: corner, size: size))
    }

    /// Переезд рамки за восемь кадров.
    private func move(to to: NSRect) {
        sizeTimer?.invalidate()
        let from = panel.frame
        guard from != to else { return }
        let steps = 8
        var step = 0
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            step += 1
            let x = min(CGFloat(step) / CGFloat(steps), 1)
            let progress = 1 - pow(1 - x, 3)   // easeOutCubic: резво тронулась, мягко встала
            self.panel.setFrame(NSRect(x: from.minX + (to.minX - from.minX) * progress,
                                       y: from.minY + (to.minY - from.minY) * progress,
                                       width: from.width + (to.width - from.width) * progress,
                                       height: from.height + (to.height - from.height) * progress),
                                display: true)
            if x >= 1 { tm.invalidate(); self.sizeTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        sizeTimer = t
    }

    /// Появление: плашка за 12 кадров вырастает из своего якоря (у курсора —
    /// левый верхний угол, внизу экрана — середина),
    /// в конце чуть перелетает свой размер и садится обратно. Само окно
    /// всё это время стоит на месте в полный рост — растёт только рисунок,
    /// поэтому ни положение, ни перетаскивание от анимации не зависят.
    private func pop() {
        popTimer?.invalidate()
        let steps = 12
        var step = 0
        view.popFromCenter = Self.place == .bottom
        view.scale = Self.popFrom
        view.needsDisplay = true
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            step += 1
            if step >= steps {
                self.view.scale = 1
                tm.invalidate()
                self.popTimer = nil
            } else {
                // easeOutBack: к концу перелетает размер примерно на 7%
                let x = CGFloat(step) / CGFloat(steps) - 1
                let progress = 1 + (Self.popBack + 1) * x * x * x + Self.popBack * x * x
                self.view.scale = Self.popFrom + (1 - Self.popFrom) * progress
            }
            self.view.needsDisplay = true
            self.panel.invalidateShadow() // тень должна ужиматься вместе с плашкой
        }
        RunLoop.main.add(t, forMode: .common)
        popTimer = t
    }

    /// С какого размера начинается появление и насколько сильно
    /// плашка перелетает свой размер в конце.
    private static let popFrom: CGFloat = 0.35
    private static let popBack: CGFloat = 1.2

    /// Во время записи: окно с кареткой переехало — плашка следом.
    /// Прибитую не трогаем; когда её тащат мышью — тем более.
    func follow(_ anchor: NSPoint?) {
        // нижняя плашка стоит на месте: ездить ей некуда
        guard Self.place == .cursor else { return }
        guard let anchor, Self.pinned == nil, panel.isVisible, !view.dragging else { return }
        let o = clampedOrigin(for: anchor)
        let cur = panel.frame.origin
        guard abs(o.x - cur.x) > 2 || abs(o.y - cur.y) > 2 else { return }
        panel.setFrameOrigin(o)
    }

    /// Пустить или погасить бегущий блик по надписи. Кадры — тридцать
    /// в секунду: блик медленный, чаще незачем, а каждый кадр это две
    /// картинки размером с плашку.
    private func shine(_ on: Bool) {
        shimmerTimer?.invalidate()
        shimmerTimer = nil
        view.shimmer = on
        guard on else { return }
        view.phase = 0
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.view.phase += 0.02          // круг примерно за полторы секунды
            if self.view.phase > 1 { self.view.phase = 0 }
            self.view.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        shimmerTimer = t
    }

    func tick(level: CGFloat) { view.tick(level: level) }

    /// Столбики для иконки в строке меню: там места на пять, поэтому
    /// берём каждый третий — иконка живёт тем же звуком, что и плашка.
    var bars: [CGFloat] {
        let h = view.heights
        return (0..<5).map { h[$0 * (h.count - 1) / 4] }
    }

    func busy() {
        view.busy = true
        view.needsDisplay = true
    }

    /// Волна больше не нужна. Висящее сообщение при этом не сбиваем —
    /// оно само уйдёт по времени или по saidEnough().
    func hide() {
        barsWanted = false
        guard view.text == nil else { return }
        shine(false)
        popTimer?.invalidate()
        popTimer = nil
        sizeTimer?.invalidate()
        sizeTimer = nil
        view.scale = 1
        panel.orderOut(nil)
    }
}
