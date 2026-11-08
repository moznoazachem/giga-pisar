// Окно настроек в духе системных: слева список разделов со значками,
// справа — карточки со строками. Раньше здесь были вкладки в панели
// инструментов и таблица «подпись — поле»; разделов стало больше, чем
// помещается в ряд, а строки настроек ничем не отличались друг от друга
// и читались сплошняком.
//
// Значок строки (RowIcon) взят из проекта words как есть, чтобы не
// разводить два похожих рисования.

import AppKit
import ServiceManagement
import SwiftUI

// MARK: разделы

enum SettingsSection: Int, CaseIterable, Identifiable {
    // Raw values are stored in "settingsTab": new sections get new numbers,
    // the order of the cases is the order in the sidebar.
    case general = 0, dictation = 1, history = 6, dictionary = 5, wave = 2, brain = 3, about = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .general: return L("Основные", "General")
        case .dictation: return L("Диктовка", "Dictation")
        case .history:   return L("История", "History")
        case .dictionary: return L("Словарь", "Dictionary")
        case .wave:      return L("Волна голоса", "Voice Wave")
        case .brain:   return L("Мозг", "Brain")
        case .about:   return L("О программе", "About")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .dictation: return "mic.fill"
        case .history:   return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed.fill"
        case .wave:      return "waveform"
        case .brain:   return "brain.head.profile"
        case .about:   return "info"
        }
    }

    var color: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .dictation: return Color(nsColor: .systemRed)
        case .history:   return Color(nsColor: .systemGreen)
        case .dictionary: return Color(nsColor: .systemOrange)
        case .wave:      return Color(nsColor: .systemIndigo)
        case .brain:   return Color(nsColor: .systemPurple)
        case .about:   return Color(nsColor: .systemBlue)
        }
    }

    /// Разделы, которые начинаются со строки-выключателя, шапки не
    /// показывают: строка и так говорит, что это за штука.
    var showsHeader: Bool {
        switch self {
        case .wave, .brain: return false
        default:            return true
        }
    }

    /// Строка под названием в шапке раздела: чем он вообще занят.
    var summary: String {
        switch self {
        case .general:
            return L("То, что настраивают один раз и больше не трогают.",
                     "The things you set once and never touch again.")
        case .dictation:
            return L("Зажми клавишу, говори, отпусти: текст появится там, где курсор.",
                     "Hold the key, speak, release: the text appears at the cursor.")
        case .history:
            return L("Последние диктовки: переслушать, прогнать через Мозг, скопировать. Только в памяти, пока Писарь запущен.",
                     "Recent dictations: listen again, run through the Brain, copy. Memory only, while Pisar is running.")
        case .dictionary:
            return L("Писарь иногда пишет имена, термины и английские названия не так, как нужно. Добавь их сюда один раз, и дальше они будут писаться правильно.",
                     "Pisar sometimes spells names, terms and English words its own way. Add them here once and they will be written right from then on.")
        case .wave:
            return L("Пока идёт диктовка, на экране видно, что Писарь слышит голос.",
                     "While you dictate, the screen shows that Pisar hears your voice.")
        case .brain:
            return L("Нейросеть правит надиктованное по команде «Писарь, …». Без обращения текст вставляется сразу.",
                     "An AI model edits the dictation on a “Pisar, …” command. Without the address the text goes in at once.")
        case .about:
            return L("Распознавание идёт на этом маке, звук никуда не уходит.",
                     "Speech is recognized on this Mac; audio never leaves it.")
        }
    }

    /// Заголовок окна следует за разделом, как в системных настройках.
    var windowTitle: String {
        switch self {
        case .about: return L("О Гига Писаре", "About Giga Pisar")
        default:     return title
        }
    }
}

// MARK: состояние

/// Живое состояние окна. Настройки хранятся там же, где и были, — в App,
/// Brain и UserDefaults; здесь только выбранный раздел и счётчик, по
/// которому вид перечитывает их заново.
final class SettingsModel: ObservableObject {
    @Published var section: SettingsSection = .general {
        didSet { if section != oldValue { onSectionChange?(section) } }
    }
    @Published var revision = 0

    /// Плавающее поле для пробы диктовки: висит внизу правой колонки
    /// поверх любого раздела.
    @Published var tryOpen = false
    @Published var tryText = ""

    /// Окно просит сказать, когда раздел сменился: ему нужно поправить
    /// заголовок и запомнить выбор.
    var onSectionChange: ((SettingsSection) -> Void)?

    unowned let app: GigaApp
    /// Облачные настройки живут дольше перерисовки: там набранный ключ
    /// и незавершённые запросы к сервису.
    private var cloudState: CloudBrainState?

    var cloud: CloudBrainState {
        if let cloudState { return cloudState }
        let state = CloudBrainState()
        state.saved = { [weak self] in
            self?.app.buildMenu()
            self?.bump()
        }
        cloudState = state
        return state
    }

    /// The dictionary table outlives redraws: it holds unsaved typing.
    lazy var dictionary = DictionaryEditor()

    /// History playback: stays the same object across redraws.
    lazy var player = DictationPlayer()

    init(app: GigaApp) { self.app = app }

    /// Что-то изменилось — перечитать всё заново.
    func bump() { revision += 1 }

    /// Сделать и сразу показать: меню и окно всегда говорят одно и то же.
    func act(_ body: () -> Void) {
        body()
        app.buildMenu()
        bump()
    }
}

// MARK: окно целиком

/// Левая колонка. Живёт в NSSplitViewItem(sidebarWith:), поэтому фон и
/// вибрация у неё системные — рисовать их самим больше не нужно.
struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appHeader
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases.filter { $0 != .about }) { section in
                    sidebarRow(section)
                }
            }
            .padding(.horizontal, 9)
            Spacer(minLength: 12)
            // Низ колонки: проба диктовки и «о программе» — то, что не
            // относится к настройкам как таковым.
            VStack(spacing: 2) {
                tryRow
                sidebarRow(.about)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 10)
        }
        // Панель инструментов отодвигает содержимое боковика на всю свою
        // высоту, и шапка уезжает слишком низко: ведём колонку доверху
        // сами и отступаем ровно настолько, чтобы разойтись со светофором.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// Не раздел, а переключатель: поле для пробы показывается поверх
    /// любого раздела и постоянной подсветки не требует.
    private var tryRow: some View {
        HStack(spacing: 9) {
            RowIcon(systemName: "text.cursor", backgroundColor: Color(nsColor: .systemTeal), sideLength: 22)
            Text(L("Проверка", "Try It"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) { model.tryOpen.toggle() }
        }
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let chosen = model.section == section
        return HStack(spacing: 9) {
            RowIcon(systemName: section.icon, backgroundColor: section.color, sideLength: 22)
            Text(section.title)
                .foregroundStyle(chosen ? Color.white : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        // Значок в списке измеряется нулевой высотой (так он не растягивает
        // строку в чужих списках), поэтому высоту строки задаём сами — 32,
        // как в системных настройках.
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(chosen ? Color.accentColor : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.section = section }
    }

    /// Шапка боковика: у системных настроек на этом месте учётная запись,
    /// у нас — кто это вообще такой и какой версии.
    private var appHeader: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Гига Писарь", "Giga Pisar"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("Версия \(APP_VERSION)", "Version \(APP_VERSION)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 44)
        .padding(.bottom, 12)
    }
}

/// Правая колонка: шапка раздела, его строки и плавающее поле для пробы.
/// Название раздела теперь рисует панель инструментов окна.
struct SettingsDetail: View {
    @ObservedObject var model: SettingsModel
    /// Открыли проверку — курсор сразу в поле, чтобы можно было диктовать.
    @FocusState private var tryFocused: Bool

    var body: some View {
        // Новый раздел показываем с начала. Прокрутку не отматываем, а
        // пересобираем весь список (`id` по разделу): у свежего он и так
        // стоит в начале, причём с правильным отступом под панелью, —
        // а `scrollTo` прижимал содержимое к верхней границе прокрутки,
        // то есть под саму панель.
        ScrollView {
            VStack(spacing: 18) {
                if model.section.showsHeader { header }
                page
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .id(model.section)
        .safeAreaInset(edge: .bottom) {
            if model.tryOpen { tryPanel }
        }
        .frame(minWidth: 460)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Поле, в котором можно продиктовать что угодно, не выходя из
    /// настроек: видно и волну, и то, как встаёт текст.
    private var tryPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField(L("Поставь сюда курсор, зажми \(currentHotkey().title) и скажи что-нибудь",
                        "Click here, hold \(currentHotkey().title) and say something"),
                      text: $model.tryText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2, reservesSpace: true)
                .focused($tryFocused)
            Button {
                withAnimation(.easeOut(duration: 0.18)) { model.tryOpen = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 66)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor)))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        // Не выезжает из-за края окна, а приподнимается на месте: сдвиг
        // всего на 8 вверх, лёгкий рост с 0.98 и проявление.
        .transition(.offset(y: 8)
            .combined(with: .scale(scale: 0.98))
            .combined(with: .opacity))
        .onAppear { tryFocused = true }
    }

    /// Шапка раздела — как в системных настройках: значок слева, рядом
    /// название и строка о том, чем раздел занят.
    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            RowIcon(systemName: model.section.icon, backgroundColor: model.section.color,
                    sideLength: 30, reservesHeight: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.section.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(model.section.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.cardFill))
    }

    @ViewBuilder
    private var page: some View {
        switch model.section {
        case .general:   GeneralPage(model: model)
        case .dictation: DictationPage(model: model)
        case .history:   HistoryPage(model: model)
        case .dictionary: DictionaryPage(model: model)
        case .wave:      WavePage(model: model)
        case .brain:     BrainPage(model: model)
        case .about:     AboutPage(model: model)
        }
    }
}

extension Color {
    /// Серая подложка карточки на белом фоне правой колонки: у системы
    /// ровно наоборот тому, что рисуется по умолчанию.
    static let cardFill = Color.primary.opacity(0.05)
}

// MARK: кирпичи страниц

/// Карточка: несколько строк под одним скруглением, с разделителями
/// между ними — как в системных настройках.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.cardFill))
            // Непрозрачное содержимое (трёхмерная сцена) иначе срезает
            // карточке скруглённые углы.
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Карточка со своим заголовком над ней — так система подписывает группы,
/// в которых строка не одна и подпись в неё не влезает.
struct SettingsGroup<Content: View, Trailing: View, Footer: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var footer: Footer
    @ViewBuilder var content: Content

    init(_ title: String,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder footer: () -> Footer = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.footer = footer()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 4)
            SettingsCard { content }
            // Подпись под карточкой — там же, где система объясняет,
            // что значит только что показанный переключатель.
            footer
                .padding(.horizontal, 4)
        }
    }
}

/// Строка настройки: значок, название, при надобности пояснение, справа —
/// сам переключатель или кнопка.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    let color: Color
    let title: String
    var subtitle: String? = nil
    var enabled: Bool = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // Пояснение идёт под названием и во всю ширину строки — в том
        // числе под переключателем: иначе оно упирается в него и рвётся
        // на три коротких огрызка.
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 11) {
                RowIcon(systemName: icon, backgroundColor: enabled ? color : Color(nsColor: .systemGray),
                        sideLength: 22, reservesHeight: true)
                    .opacity(enabled ? 1 : 0.5)
                Text(title)
                Spacer(minLength: 12)
                trailing
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 33)   // значок 22 + просвет 11
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .opacity(enabled ? 1 : 0.6)
    }
}

/// Черта между строками — от текста, а не от края: значок остаётся
/// в своей колонке, как в системных списках.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 49)
    }
}
