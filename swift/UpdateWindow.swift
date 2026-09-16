// Окно хода обновления, как у «Обновления ПО» в macOS: полоска, что
// сейчас делаем, кнопка «Отменить». Раньше единственным признаком жизни
// была надпись «↓ 43%» у значка в строке меню, а на маках с чёлкой значок
// в этот момент прячется за ней: человек жал «Обновить», ничего не видел
// и жал снова. Окно от чёлки не зависит. Закрыть его крестиком можно,
// скачивание продолжается; остановить — только кнопкой.

import AppKit

final class UpdateWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var title = NSTextField(labelWithString: "")
    private var status = NSTextField(labelWithString: "")
    private var bar = NSProgressIndicator()
    private var cancelButton = NSButton()
    /// Что делать по «Отменить»; nil — отменять уже нечего (кнопка прячется).
    var onCancel: (() -> Void)?

    func show(version: String) {
        if window == nil { build() }
        title.stringValue = L("Обновление до версии \(version)", "Updating to version \(version)")
        cancelButton.isHidden = onCancel == nil
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.orderOut(nil) }

    /// Скачивание: полоска с процентами.
    func downloading(percent: Int) {
        status.stringValue = L("Скачиваю… \(percent)%", "Downloading… \(percent)%")
        bar.isIndeterminate = false
        bar.doubleValue = Double(percent)
    }

    /// Этап без процентов: проверка подписи, перезапуск, ожидание конца диктовки.
    func busy(_ text: String) {
        status.stringValue = text
        bar.isIndeterminate = true
        bar.startAnimation(nil)
    }

    private func build() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        title.font = .boldSystemFont(ofSize: 14)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor

        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true

        cancelButton = NSButton(title: L("Отменить", "Cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded

        let text = NSStackView(views: [title, status, bar])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        text.setCustomSpacing(10, after: status)

        let top = NSStackView(views: [icon, text])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 14

        let buttons = NSStackView(views: [cancelButton])
        buttons.orientation = .horizontal
        buttons.alignment = .trailing

        let root = NSStackView(views: [top, buttons])
        root.orientation = .vertical
        root.alignment = .trailing
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Giga Pisar"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = root
        w.setContentSize(root.fittingSize)
        window = w
    }

    @objc private func cancel() {
        onCancel?()
        hide()
    }

    // крестик — только спрятать, дело продолжается
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
}
