// Окно настроек: боковое меню слева, как в системных настройках, и
// страницы справа. Сам вид живёт в SettingsView.swift на SwiftUI; здесь
// только окно, которое его держит, и переходники к меню в строке.
// Каждая правка применяется сразу, и меню с окном всегда говорят одно и то
// же (App.settingsChanged).

import AppKit
import SwiftUI

/// SwiftUI занимает имя App под свой протокол, поэтому внутри вида
/// приложение зовём так.
typealias GigaApp = App

final class SettingsWindow: NSObject, NSWindowDelegate {
    enum Tab: Int, CaseIterable { case general, brain, edit, about }

    private weak var app: App?
    private var window: NSWindow?
    private var model: SettingsModel?
    private var split: NSSplitViewController?
    /// Название раздела в панели инструментов: меняется вместе с выбором.
    private var titleItem: NSToolbarItem?
    private var titleField: NSTextField?

    init(app: App) {
        self.app = app
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(tab: Tab? = nil) {
        if window == nil { makeWindow() }
        if let tab { select(tab) }
        model?.bump()
        // На время окна становимся обычным приложением: с иконкой в доке
        // и своей строкой меню. Иначе это окно-аксессуар, а у аксессуара
        // нет меню «Правка» — в полях ввода не работает ⌘V.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Перечитать состояние заново, не трогая открытый раздел.
    /// keepBrain остался ради облачной панели: она на AppKit и живёт отдельно,
    /// а вид её только показывает, так что сбрасывать ничего не нужно.
    func refresh(keepBrain: Bool = false) {
        DispatchQueue.main.async { [weak self] in self?.model?.bump() }
    }

    /// Проценты качающейся модели: вид перечитает строку сам.
    func updateDownload() { model?.bump() }

    // MARK: окно

    private func makeWindow() {
        guard let app else { return }
        let model = SettingsModel(app: app)
        model.section = SettingsSection(rawValue: UserDefaults.standard.integer(forKey: "settingsTab")) ?? .general
        model.onSectionChange = { [weak self] section in
            UserDefaults.standard.set(section.rawValue, forKey: "settingsTab")
            self?.window?.title = section.windowTitle
            self?.titleField?.stringValue = section.title
        }
        self.model = model

        // Две колонки — родной NSSplitViewController: от него боковик
        // получает системный материал и правильные отступы под строкой
        // заголовка, а панель инструментов — черту, которая появляется,
        // когда содержимое уезжает под неё. Своими руками это только
        // изображалось.
        let sidebar = NSHostingController(rootView: SettingsSidebar(model: model))
        let detail = NSHostingController(rootView: SettingsDetail(model: model))
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 232
        sidebarItem.maximumThickness = 232
        sidebarItem.canCollapse = false
        // Кнопки сворачивания у нас нет — в системных настройках её тоже нет.
        sidebarItem.allowsFullHeightLayout = true
        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 460
        split.addSplitViewItem(detailItem)
        self.split = split

        let w = NSWindow(contentViewController: split)
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        w.setContentSize(NSSize(width: 732, height: 560))
        w.minSize = NSSize(width: 692, height: 420)
        w.title = model.section.windowTitle
        w.titleVisibility = .hidden   // название раздела стоит в панели
        w.isReleasedWhenClosed = false
        w.delegate = self

        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar
        w.toolbarStyle = .unified

        w.center()
        window = w
    }

    /// Разделов в окне больше, чем вкладок, которыми его зовут снаружи,
    /// поэтому переводим явно, а не по номеру.
    private func section(for tab: Tab) -> SettingsSection {
        switch tab {
        case .general: return .general
        case .brain:   return .brain
        case .edit:    return .brain   // правка выделенного переехала в «Мозг»
        case .about:   return .about
        }
    }

    private func select(_ tab: Tab) {
        let section = section(for: tab)
        model?.section = section
        UserDefaults.standard.set(section.rawValue, forKey: "settingsTab")
        window?.title = section.windowTitle
        titleField?.stringValue = section.title
    }

    func windowWillClose(_ notification: Notification) {
        if let s = model?.section { UserDefaults.standard.set(s.rawValue, forKey: "settingsTab") }
        // Окно закрыли — снова живём только в строке меню.
        NSApp.setActivationPolicy(.accessory)
    }
}

extension SettingsWindow: NSToolbarDelegate {
    private static let titleItemId = NSToolbarItem.Identifier("sectionTitle")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Разделитель повторяет границу колонок: слева от него — боковик,
        // справа — название раздела, ровно как в системных настройках.
        [.sidebarTrackingSeparator, Self.titleItemId]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .sidebarTrackingSeparator, let split {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        }
        guard id == Self.titleItemId else { return nil }
        // Свой ярлык, а не item.title: системный текстовый пункт рисуется
        // мелким и приглушённым, как подпись под кнопкой, а в настройках
        // заголовок раздела крупный и обычного цвета.
        let label = NSTextField(labelWithString: model?.section.title ?? "")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        // Без явной высоты пункт растягивает всю панель: у системных
        // настроек она 54, у нас выходило под 70.
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: 22).isActive = true
        titleField = label
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = label
        titleItem = item
        return item
    }
}

/// Target/action as a closure, for controls built in code.
final class ActionTarget: NSObject {
    private let handler: (Any?) -> Void
    init(_ handler: @escaping (Any?) -> Void) { self.handler = handler }
    @objc func fire(_ sender: Any?) { handler(sender) }
}

// MARK: - the cloud Brain, inline on the Brain tab

/// Pick the service, paste the key, the model is chosen and checked. Like the rest of
/// Settings it saves by itself as soon as the set is usable; there is no Save button.

// MARK: - what each Brain choice is, judged against this Mac

enum BrainAdvice {
    static var ramGB: Int { Int(ProcessInfo.processInfo.physicalMemory / (1 << 30)) }

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(cString: buf).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? L("неизвестный чип", "unknown chip") : s
    }

    static var thisMac: String {
        L("Твой мак: \(chip), \(ramGB) ГБ памяти.", "This Mac: \(chip), \(ramGB) GB of memory.")
    }

    static func describe(_ choice: String) -> String {
        let intel = !Brain.shared.engineAvailable
        switch choice {
        case "gigachat":
            let base = L("Родной русский, лучшее качество правки, работает без интернета. Весит 6,5 ГБ, нужно от 16 ГБ памяти.",
                         "Native Russian, the best edits, works offline. 6.5 GB, needs 16 GB of memory or more.")
            if intel { return base + " " + L("На маке с Intel не работает.", "Does not run on Intel Macs.") }
            return base + " " + (ramGB < 16
                ? L("На твоём маке \(ramGB) ГБ: будет тормозить и теснить другие программы. Лучше Qwen или облако.",
                    "This Mac has \(ramGB) GB: it will be slow and crowd other apps. Qwen or the cloud fits better.")
                : L("Твоему маку хватит.", "This Mac can handle it."))
        case "qwen":
            let base = L("Лёгкая и быстрая, работает без интернета. Весит 1,9 ГБ, хватает 8 ГБ памяти. Русский неродной, но аккуратный.",
                         "Light and fast, works offline. 1.9 GB, 8 GB of memory is enough. Russian is not native but tidy.")
            if intel { return base + " " + L("На маке с Intel не работает.", "Does not run on Intel Macs.") }
            return base + " " + (ramGB < 8
                ? L("На твоём маке \(ramGB) ГБ: может подтормаживать.", "This Mac has \(ramGB) GB: it may be slow.")
                : L("Твоему маку подходит.", "Fits this Mac."))
        case BrainServer.id:
            return L("Быстро и умно на любом маке, включая Intel. Нужен ключ сервиса и деньги на его балансе API (это не подписка вроде ChatGPT Plus). На сервер уходит только текст, звук остаётся на маке.",
                     "Fast and smart on any Mac, Intel included. Needs a service key and money on its API balance (not a subscription like ChatGPT Plus). Only text goes to the server; audio stays on the Mac.")
        default:
            return L("Мозг выключен: текст вставляется как распознан.", "The Brain is off: text goes in as recognized.")
        }
    }

    static func service(_ p: BrainProvider) -> String {
        switch p.id {
        case "deepseek": return L("Быстрая недорогая модель с хорошим русским. Пополнить баланс можно на пару долларов.",
                                  "A fast, inexpensive model with good Russian. A couple of dollars of balance goes a long way.")
        case "openrouter": return L("Один ключ ко множеству моделей разных компаний. Нужен баланс на счету.",
                                    "One key to many models from different companies. Needs a balance.")
        case "openai": return L("Модели ChatGPT. Оплата API отдельно от подписки ChatGPT Plus. Из России не работает без VPN.",
                                "ChatGPT models. API billing is separate from ChatGPT Plus.")
        case "groq": return L("Очень быстрые открытые модели, есть бесплатный лимит. Русский слабее, чем у остальных.",
                              "Very fast open models with a free tier. Russian is weaker than the others.")
        case "gemini": return L("Модели Google, есть бесплатный лимит. Из России не работает без VPN.",
                                "Google models with a free tier.")
        case "anthropic": return L("Модели Claude, платно. Из России не работает без VPN.", "Claude models, paid.")
        default: return L("Своя нейросеть или любой совместимый сервис: адрес и, если нужно, ключ.",
                          "Your own model or any compatible service: the address and, if needed, a key.")
        }
    }
}
