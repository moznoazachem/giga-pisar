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
        // Раскладка как у «Обновления ПО»: значок слева, справа колонка —
        // заголовок, статус, полоска во всю ширину колонки, кнопка под её
        // правым краем. Всё на констрейнтах, чтобы ничего не расползалось.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .boldSystemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        cancelButton = NSButton(title: L("Отменить", "Cancel"), target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular

        for v in [icon, title, status, bar, cancelButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let side: CGFloat = 20
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
            icon.topAnchor.constraint(equalTo: root.topAnchor, constant: side),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -side),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: side + 2),

            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bar.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),

            cancelButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cancelButton.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 14),
            cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        let w = NSWindow(contentRect: root.frame,
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("Обновление", "Update")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = root
        window = w
    }

    @objc private func cancel() {
        onCancel?()
        hide()
    }

    // крестик — только спрятать, дело продолжается
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
}
