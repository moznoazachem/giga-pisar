// Окно первого запуска: два разрешения, каждое со своей кнопкой.
//
// Оба доступа выдаёт только macOS, приложение включить их за человека не
// может. Микрофон система спрашивает своим окном с настоящей кнопкой
// «Разрешить». Универсальный доступ — нет: её окно умеет лишь открыть
// Настройки, а там нужно самому найти Giga Pisar в списке и включить
// тумблер. Поэтому окно ведёт за руку: у каждого шага своя кнопка (люди
// тыкали в кружочки-«галочки», которые ничего не делали), перед вторым
// шагом написано, что именно произойдёт и как выглядит тумблер, а когда
// доступ включён, приложение само выходит вперёд и показывает зелёное
// «Включено». В конце — поле, куда ложится первая диктовка, чтобы
// попробовать не выходя из окна.
//
// Для снимков экрана: GIGA_DEMO_PERMS=none|mic|all рисует окно так, будто
// доступов нет (есть только микрофон, есть оба), ничего не спрашивая,
// и показывает его при запуске.

import AVFoundation
import AppKit

final class Onboarding: NSObject {
    private var window: NSWindow?
    private var timer: Timer?
    private var axAsked = false          // системный запрос AX уже дёргали?
    private var wasAllGranted = false    // чтобы выйти вперёд ровно в момент «готово»

    // живые части окна
    private var header = NSTextField(labelWithString: "")
    private var sub = NSTextField(labelWithString: "")
    private var cards: [PermissionCard] = []
    private var axHint: NSView?
    private var tryBox: NSView?
    private var tryField: NSTextView?
    private var laterButton = NSButton()
    private var doneButton = NSButton()

    static let demo = ProcessInfo.processInfo.environment["GIGA_DEMO_PERMS"]

    static var micGranted: Bool {
        if let demo { return demo == "mic" || demo == "all" }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    static var axGranted: Bool {
        if let demo { return demo == "all" }
        return AXIsProcessTrusted()
    }
    static var allGranted: Bool { micGranted && axGranted }

    func show() {
        if window == nil { build() }
        wasAllGranted = Self.allGranted
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        if Self.allGranted { window?.makeFirstResponder(tryField) } // диктовка ляжет в поле
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: вёрстка

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        header.font = .boldSystemFont(ofSize: 17)
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 3
        sub.preferredMaxLayoutWidth = 472
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(4, after: header)
        stack.setCustomSpacing(18, after: sub)

        let mic = PermissionCard(
            symbol: "mic.fill",
            title: L("Микрофон", "Microphone"),
            why: L("Чтобы слышать, что ты диктуешь", "To hear what you dictate"),
            action: { [weak self] in self?.askMicrophone() })
        let ax = PermissionCard(
            symbol: "accessibility",
            title: L("Универсальный доступ", "Accessibility"),
            why: L("Чтобы поставить текст туда, где курсор: приложение нажимает ⌘V за тебя",
                   "To put the text where your cursor is: the app presses ⌘V for you"),
            action: { [weak self] in self?.askAccessibility() })
        cards = [mic, ax]
        for c in cards {
            stack.addArrangedSubview(c)
            c.widthAnchor.constraint(equalToConstant: 472).isActive = true
        }

        // подсказка ко второму шагу: что откроется и как выглядит тумблер
        let hint = buildAxHint()
        axHint = hint
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(6, after: ax)

        // финал: поле для первой диктовки
        let box = buildTryBox()
        tryBox = box
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalToConstant: 472).isActive = true

        laterButton = NSButton(title: L("Позже", "Later"), target: self, action: #selector(closeWindow))
        laterButton.bezelStyle = .rounded
        doneButton = NSButton(title: L("Готово", "Done"), target: self, action: #selector(closeWindow))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [laterButton, doneButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let spacer = NSView()
        let footer = NSStackView(views: [spacer, buttons])
        footer.orientation = .horizontal
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalToConstant: 472).isActive = true
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Giga Pisar"
        w.isReleasedWhenClosed = false
        w.contentView = stack
        window = w
    }

    private func buildAxHint() -> NSView {
        let text = NSTextField(wrappingLabelWithString: L(
            "Сейчас система спросит и предложит открыть Настройки. Там в списке найди Giga Pisar и включи тумблер. Потом вернись сюда: окно само отметит, что готово.",
            "macOS will ask and offer to open System Settings. Find Giga Pisar in the list there and turn the switch on. Then come back: this window will mark it done by itself."))
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = 300

        // сам тумблер, как в Настройках: только картинка. Выключенный
        // NSSwitch рисуется серым, поэтому он живой, но всегда «вкл».
        let toggle = NSSwitch()
        toggle.state = .on
        toggle.target = self
        toggle.action = #selector(keepToggleOn(_:))
        toggle.controlSize = .regular
        let name = NSTextField(labelWithString: "Giga Pisar")
        name.font = .systemFont(ofSize: 12)
        let sample = NSStackView(views: [name, toggle])
        sample.orientation = .horizontal
        sample.spacing = 10
        sample.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        sample.wantsLayer = true
        sample.layer?.cornerRadius = 7
        sample.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        let row = NSStackView(views: [text, sample])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 472).isActive = true
        return row
    }

    @objc private func keepToggleOn(_ sender: NSSwitch) { sender.state = .on }

    private func buildTryBox() -> NSView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let tv = NSTextView()
        tv.font = .systemFont(ofSize: 14)
        tv.isRichText = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        tryField = tv
        let box = NSStackView(views: [scroll])
        box.orientation = .vertical
        return box
    }

    // MARK: состояние

    private func refresh() {
        // окно закрыли крестиком — опрашивать больше некого
        if window?.isVisible != true { timer?.invalidate(); return }

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let mic = Self.micGranted, ax = Self.axGranted, all = mic && ax
        cards[0].set(granted: mic, buttonTitle: micStatus == .denied && Self.demo == nil
                     ? L("Открыть настройки", "Open Settings") : L("Разрешить", "Allow"))
        cards[1].set(granted: ax, buttonTitle: axAsked
                     ? L("Открыть настройки", "Open Settings") : L("Разрешить", "Allow"))
        // Return нажимает кнопку текущего шага
        cards[0].button.keyEquivalent = !mic ? "\r" : ""
        cards[1].button.keyEquivalent = mic && !ax ? "\r" : ""

        axHint?.isHidden = ax || !mic
        tryBox?.isHidden = !all
        laterButton.isHidden = all
        doneButton.isHidden = !all

        if all {
            header.stringValue = L("Всё готово", "All set")
            let key = currentHotkey().title
            let keyRu = key.prefix(1).lowercased() + key.dropFirst() // «правый ⌘» посреди фразы
            sub.stringValue = L("Зажми \(keyRu), скажи что-нибудь и отпусти. Попробуй прямо здесь:",
                                "Hold \(key), say something and let go. Try it right here:")
        } else {
            header.stringValue = L("Два разрешения, и можно диктовать", "Two permissions and you're set")
            sub.stringValue = L("Оба выдаёт macOS, само приложение включить их не может. Как только доступ включён, здесь загорится «Включено».",
                                "Both are granted by macOS, the app can't switch them on itself. As soon as one is on, it lights up here as “On”.")
        }
        window?.setContentSize(window?.contentView?.fittingSize ?? .zero)

        // доступ только что включили в Настройках — выйти вперёд, чтобы
        // человек увидел зелёное, а не искал окно за Настройками
        if all && !wasAllGranted {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(tryField)
        }
        wasAllGranted = all
    }

    // MARK: действия

    private func askMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        case .authorized:
            break
        default:
            openPane("Privacy_Microphone")
        }
    }

    private func askAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        if axAsked {
            openPane("Privacy_Accessibility")
        } else {
            axAsked = true
            // системное окно «Giga Pisar would like to control this computer…»
            // с кнопкой «Open System Settings»; заодно приложение появляется
            // в списке Accessibility, тумблером вниз
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            refresh()
        }
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func closeWindow() {
        timer?.invalidate()
        window?.orderOut(nil)
    }
}

/// Карточка одного разрешения: значок, название, зачем, справа кнопка
/// «Разрешить», которая после включения становится зелёным «Включено».
final class PermissionCard: NSView {
    let button: NSButton
    private let status = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let action: () -> Void

    init(symbol: String, title: String, why: String, action: @escaping () -> Void) {
        self.action = action
        button = NSButton(title: "", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium))
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let name = NSTextField(labelWithString: title)
        name.font = .boldSystemFont(ofSize: 13)
        let desc = NSTextField(wrappingLabelWithString: why)
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 270
        let text = NSStackView(views: [name, desc])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(tap)
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.textColor = .systemGreen
        status.stringValue = "✓ " + L("Включено", "On")
        status.isHidden = true

        let right = NSStackView(views: [button, status])
        right.orientation = .horizontal
        right.setContentHuggingPriority(.required, for: .horizontal)
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [icon, text, gap, right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func set(granted: Bool, buttonTitle: String) {
        button.title = buttonTitle
        button.isHidden = granted
        status.isHidden = !granted
        icon.contentTintColor = granted ? .systemGreen : .controlAccentColor
    }

    @objc private func tap() { action() }
}
