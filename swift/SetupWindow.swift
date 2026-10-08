// Окно первого запуска: пока Писарь качает модель распознавания, человек
// видит, что происходит, а не пустоту со значком в строке меню.
//
// Отдельное окно, а не лист поверх настроек: до первой диктовки настраивать
// ещё нечего, и это единственное, что в этот момент имеет смысл показывать.
//
// Для предпросмотра без установки: `Giga --setup-preview` рисует окно с
// поддельной загрузкой и ничего не трогает — ни модель, ни настройки.

import AVFoundation
import AppKit
import SwiftUI

/// Шаги первого запуска. Пока их два; дальше сюда же лягут доступы и
/// проба диктовки — окно к этому готово, шаги меняют только содержимое.
/// Доступы, которые выдаёт только macOS. Спросить о них можно лишь так:
/// система сама о выдаче не сообщает.
///
/// Для снимков экрана: GIGA_DEMO_PERMS=none|mic|all показывает окно так,
/// будто доступов нет (есть только микрофон, есть оба), ничего не
/// спрашивая у системы.
enum Access {
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
}

enum SetupStep: Int, CaseIterable {
    case welcome        // знакомство: знак, название и загрузка модели
    case microphone     // доступ к микрофону
    case accessibility  // универсальный доступ: им Писарь вставляет текст
    case key            // какой клавишей диктовать
    case wave           // где показывать волну голоса
    case tryIt          // можно сразу продиктовать в поле
    case brain          // про Мозг: его включают в настройках
}

/// Что показывает окно прямо сейчас.
final class SetupState: ObservableObject {
    /// Какие шаги показываем и в каком порядке. Знакомство — все; когда
    /// доступ отобрали позже, только тот шаг, которого не хватает.
    @Published var steps: [SetupStep] = SetupStep.allCases
    @Published var step: SetupStep = .welcome
    /// Доля скачанного, 0…1.
    @Published var progress: Double = 0
    /// Сколько уже скачано и сколько всего, в байтах. Ноль — ещё не знаем.
    @Published var done: Int64 = 0
    @Published var total: Int64 = 0
    /// Модель на месте: полоска уходит, остаётся галочка.
    @Published var ready = false
    /// Выбранная клавиша диктовки.
    @Published var hotkeyId: String = currentHotkey().id
    /// Куда сообщить о выборе. В приложении — в настройки, в
    /// предпросмотре никуда.
    var pickHotkey: (String) -> Void = { _ in }

    /// Где показывать волну голоса: «cursor» или «bottom».
    @Published var waveChoice = "cursor"
    var pickWave: (String) -> Void = { _ in }

    /// Черновик на последнем шаге: никуда не сохраняется.
    @Published var tryText = ""
    /// Закончить настройку и открыть настройки на «Мозге». Ставит хозяин
    /// окна.
    var finish: () -> Void = {}
    var openBrain: () -> Void = {}

    /// Доступ к микрофону выдан.
    @Published var micGranted = false
    /// В микрофоне отказали. Своим окном это уже не исправить: нужно
    /// включить тумблер в настройках, а macOS отдаёт доступ только
    /// перезапущенному приложению.
    @Published var micDenied = false
    /// Универсальный доступ выдан. Его система сама не даёт: окно лишь
    /// открывает настройки, а тумблер человек включает руками.
    @Published var axGranted = false
    /// Как спросить доступы. Ставит хозяин окна: в приложении это
    /// системные запросы, в предпросмотре — просто отметки.
    var askMic: () -> Void = {}
    var askAX: () -> Void = {}
    /// Перезапустить приложение: после смены тумблера микрофона macOS
    /// иначе доступ не отдаёт.
    var restart: () -> Void = {}
    /// Шаги, с которых окно уже само ушло дальше после выдачи доступа.
    /// Второй раз не листаем: если человек вернулся назад, он пришёл
    /// посмотреть, а не ждать, что экран уедет сам.
    var autoSkipped: Set<SetupStep> = []
    /// Окно вот-вот уйдёт дальше само: кнопку на это время гасим, иначе
    /// человек жмёт её и попадает уже в следующий шаг.
    @Published var autoAdvancing = false

    /// Окно можно закрыть красной кнопкой: так его открывают из
    /// настроек, когда знакомство давно пройдено. В самом знакомстве
    /// закрывать нечего — там идут до конца.
    @Published var closable = false
    /// Окно на экране. Отложенные дела (автопереход) по закрытии должны
    /// молча отваливаться, а не срабатывать в пустоту.
    @Published var live = false

    /// Начать всё заново. Ставится только в предпросмотре — в самом
    /// приложении кнопки «Сбросить» нет и быть не должно.
    var onReset: (() -> Void)?
    /// Текст вместо размеров, когда считать нечего (ошибка, распаковка).
    @Published var note: String = ""
    /// Загрузка сорвалась: сама она не повторится, нужна кнопка.
    @Published var failed = false
    var retry: () -> Void = {}

    /// Какой это шаг по счёту среди показываемых.
    var index: Int { steps.firstIndex(of: step) ?? 0 }

    func next() {
        // Шагов больше нет — значит, всё сделано и окно своё отработало.
        guard index + 1 < steps.count else {
            finish()
            return
        }
        step = steps[index + 1]
    }

    /// Шаг назад: с любого шага можно вернуться и посмотреть предыдущий.
    func back() {
        guard index > 0 else { return }
        step = steps[index - 1]
    }

    var canGoBack: Bool { index > 0 }

    var sizeLine: String {
        if ready { return L("Модель загружена", "The model is ready") }
        if !note.isEmpty { return note }
        guard total > 0 else { return L("Соединяюсь…", "Connecting…") }
        // Целые мегабайты: десятичная часть всё равно меняется быстрее,
        // чем её успеваешь прочесть, а строка от неё дёргается.
        let mb = { (bytes: Int64) in (bytes + 524_288) / 1_048_576 }
        return L("\(mb(done)) из \(mb(total)) МБ", "\(mb(done)) of \(mb(total)) MB")
    }
}

struct SetupView: View {
    @ObservedObject var state: SetupState
    /// Поле на последнем шаге берёт фокус сразу: диктовать надо туда.
    @FocusState private var tryFocused: Bool

    /// Окно фиксированного размера, поэтому места элементов задаём прямо
    /// в пунктах: так полоска и кнопка живут одним слоем поверх шагов и
    /// при переходе переезжают, а не пересоздаются (от этого они мигали).
    private static let size = CGSize(width: 648, height: 506)
    private static let pad: CGFloat = 32
    /// Поля нижней полосы: там тесновато, поэтому меньше боковых.
    private static let padBottom: CGFloat = 24
    private static let buttonWidth: CGFloat = 150
    private static let buttonHeight: CGFloat = 34
    /// Сколько занимает нижняя полоса: кнопка плюс поля вокруг неё.
    private static let footer = padBottom + buttonHeight + padBottom
    /// Отступ сверху: под ним висят «назад» и «Сбросить».
    private static let topZone: CGFloat = 30
    /// Ширина карточек на шаге с клавишей: под неё настроена камера сцены.
    private static let cardWidth: CGFloat = 460

    var body: some View {
        ZStack {
            SetupBackdrop()
            // Градиент — только для знакомства. Дальше фон гасится в
            // белый, чтобы не спорить с содержимым шага.
            Color.white
                .opacity(state.step == .welcome ? 0 : 1)

            // Шаги стоят в ряд, как страницы, и лента сдвигается на
            // ширину окна. Раньше каждый шаг гас и ехал сам по себе, и
            // при возврате элементы разъезжались в разные стороны.
            HStack(spacing: 0) {
                ForEach(state.steps, id: \.rawValue) { step in
                    content(for: step)
                        .frame(width: Self.size.width, height: Self.size.height)
                }
            }
            .frame(width: Self.size.width * CGFloat(state.steps.count),
                   alignment: .leading)
            .offset(x: -CGFloat(state.index) * Self.size.width)
            .frame(width: Self.size.width, alignment: .leading)
            .clipped()

            // Кружок внизу — напоминание, что загрузка идёт, пока её не
            // видно. На проверке полоска стоит прямо в середине экрана,
            // и напоминать уже нечего.
            if state.step != .welcome, state.step != .tryIt,
               state.steps.contains(.welcome), !state.ready {
                footerIndicator
                    .position(x: Self.padBottom + 9, y: Self.size.height - Self.footer / 2)
            }

            // На шаге с универсальным доступом точек нет: там внизу стоит
            // картинка со строкой настроек, и две подсказки разом спорят.
            if state.step != .accessibility, state.steps.count > 1 {
                pageDots
                    // В просвете между содержимым шага и кнопкой.
                    .position(x: Self.size.width / 2,
                              y: buttonCenter.y - Self.buttonHeight / 2 - 20)
            }

            footerControls
                .position(buttonCenter)


            // Верхняя полоса тянет окно: рамки у него нет, а значит нет и
            // заголовка, за который обычно хватают. Кнопки лежат выше
            // по стопке и нажимаются как ни в чём не бывало.
            WindowDrag()
                .frame(height: 56)
                .frame(maxHeight: .infinity, alignment: .top)

            if state.onReset != nil {
                resetButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(16)
            }

            if state.canGoBack {
                backButton
                    // Прячем только там, где в углу стоит красная кнопка
                    // окна: вдвоём им тесно. Нажать всё равно можно.
                    .opacity(state.closable ? 0 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
                    // Под красной кнопкой окна, а не сбоку от неё: вбок
                    // она уезжала от края и висела сама по себе.
                    .padding(.top, state.closable ? 18 : 0)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Окно без рамки, поэтому скругление рисуем сами.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Шаги живут в ленте все сразу, поэтому фокус ставим не при
        // появлении поля, а когда до него дошли.
        .onChange(of: state.step) { step in
            tryFocused = step == .tryIt && state.ready
        }
        .onChange(of: state.micGranted) { granted in
            autoAdvance(from: .microphone, granted: granted)
        }
        .onChange(of: state.axGranted) { granted in
            autoAdvance(from: .accessibility, granted: granted)
        }
        // Модель докачалась, пока человек стоял на проверке: поле
        // появилось — ставим в него курсор.
        .onChange(of: state.ready) { ready in
            if ready, state.step == .tryIt { tryFocused = true }
        }
    }

    /// Доступ выдан — дожидаемся, пока дорисуется галочка, и уходим
    /// дальше сами. Кнопку на это время гасим, чтобы по ней не щёлкали.
    private func autoAdvance(from step: SetupStep, granted: Bool) {
        guard granted, state.step == step, !state.autoSkipped.contains(step) else { return }
        state.autoSkipped.insert(step)
        state.autoAdvancing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            state.autoAdvancing = false
            guard state.live, state.step == step else { return }
            withAnimation(.easeInOut(duration: 0.26)) { state.next() }
        }
    }

    @ViewBuilder
    private func content(for step: SetupStep) -> some View {
        switch step {
        case .welcome:       welcomeContent
        case .microphone:    microphoneContent
        case .accessibility: accessibilityContent
        case .key:           keyContent
        case .wave:          waveContent
        case .tryIt:         tryContent
        case .brain:         brainContent
        }
    }

    /// Точки над кнопкой: видно, сколько шагов и который идёт.
    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(state.steps, id: \.rawValue) { step in
                Circle()
                    .fill(step == state.step
                          ? Color.primary.opacity(0.55)
                          : Color.primary.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
    }

    /// Слева внизу — только кружок загрузки, без слов: подробности
    /// остались на первом шаге, здесь важно лишь, что дело идёт. Когда
    /// модель скачана, он просто исчезает.
    private var footerIndicator: some View {
        ProgressView(value: state.progress)
            .progressViewStyle(.circular)
            .controlSize(.small)
            .transition(.opacity)
    }

    /// Пока доступ не выдан, кнопка просит его, а не листает дальше.
    private var asks: SetupStep? {
        if state.step == .microphone, !state.micGranted { return .microphone }
        if state.step == .accessibility, !state.axGranted { return .accessibility }
        return nil
    }

    /// Кнопка всегда по центру внизу: от шага к шагу она не переезжает,
    /// и взгляд её не ищет.
    private var buttonCenter: CGPoint {
        CGPoint(x: Self.size.width / 2, y: Self.size.height - Self.footer / 2)
    }

    /// Первый шаг: знак и подписи над полоской.
    private var welcomeContent: some View {
        stage(title: L("Гига Писарь", "Giga Pisar"),
              text: L("Качаю модель распознавания — это «уши» Писаря.",
                      "Downloading the speech model — these are Pisar's ears.")) {
            ZStack {
                PulseRings()
                FloatingDots()
                WaveMark().scaleEffect(1.3)
            }
            .frame(width: 240)
        } content: {
            // Подробная полоска живёт только здесь: дальше от неё
            // остаётся кружок в нижней полосе.
            SetupProgress(state: state)
                .frame(width: 345)
        }
    }

    /// Шаг про микрофон: без него диктовать нечем.
    private var microphoneContent: some View {
        permissionStep(
            icon: state.micDenied && !state.micGranted ? "mic.slash.fill" : "mic.fill",
            color: Color(nsColor: .systemRed),
            granted: state.micGranted,
            title: L("Доступ к микрофону", "Microphone Access"),
            text: state.micGranted
                ? L("Писарь слышит голос.\nОсталось разрешить вставку текста.",
                    "Pisar can hear you now.\nOne more permission to go.")
                : state.micDenied
                ? L("Доступ запрещён.\nВключить его можно только в настройках.",
                    "Access is denied.\nIt can only be turned on in Settings.")
                : L("Без него диктовать нечем.\nЗвук остаётся на этом маке и никуда не уходит.",
                    "Without it there is nothing to dictate with.\nThe audio stays on this Mac.")) {
            if state.micDenied, !state.micGranted {
                VStack(spacing: 10) {
                    Text(L("Включи «Гига Писарь» в списке микрофона — и перезапусти его: включённый тумблер macOS отдаёт только заново запущенному приложению.",
                           "Switch Giga Pisar on in the microphone list, then restart it: macOS hands the permission only to a freshly started app."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 345)
                    plainButton(L("Перезапустить", "Restart")) { state.restart() }
                }
            }
        }
    }

    /// Шаг про универсальный доступ: им Писарь вставляет надиктованное
    /// туда, где стоит курсор.
    private var accessibilityContent: some View {
        permissionStep(
            icon: "accessibility",
            color: Color(nsColor: .systemBlue),
            granted: state.axGranted,
            title: L("Универсальный доступ", "Accessibility"),
            text: state.axGranted
                ? L("Писарь сам поставит текст туда, где курсор.\nВсё готово.",
                    "Pisar will put the text where your cursor is.\nAll set.")
                : L("Им Писарь вставляет надиктованное в любое поле.",
                    "This is how Pisar puts the text into any field.")) {
            if !state.axGranted {
                VStack(spacing: 10) {
                    AccessibilityHint(active: state.step == .accessibility) { state.askAX() }
                    Text(L("Строку можно перетащить прямо в список настроек. Если Писарь там уже есть, но доступа нет, — удали его кнопкой «−» и добавь заново.",
                           "You can drag this row right into the Settings list. If Pisar is already there but still has no access, remove it with “−” and add it again."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 345)
                }
            }
        }
    }

    /// Шаг про клавишу: та же трёхмерная клавиатура и те же картинки
    /// клавиш, что в настройках, только без карточек под ними.
    private var keyContent: some View {
        stage(title: L("Клавиша диктовки", "Dictation Key"),
              text: L("Зажми её, говори, отпусти — текст встанет туда, где курсор.",
                      "Hold it, speak, release — the text lands where your cursor is.")) {
            // Клавиатура во всю ширину окна и без подложки: камера стоит
            // по центру, так что видно её целиком и ничего не ездит.
            // 0.063 — это ровно 94 пункта от края кадра до корпуса при
            // ширине окна 648 и этом отъезде камеры (мерил по снимку).
            KeyboardView(hotkeyId: state.hotkeyId, edge: 0.063, pullback: 1.25,
                         backdrop: .white)
                .frame(width: Self.size.width, height: 98)
        } content: {
            SettingsCard {
                KeyPicker(chosen: state.hotkeyId) { id in
                    state.hotkeyId = id
                    state.pickHotkey(id)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(width: Self.cardWidth)
        }
    }

    /// Шаг про волну: те же картинки, что в настройках.
    private var waveContent: some View {
        stage(title: L("Волна голоса", "Voice Wave"),
              text: L("Пока идёт диктовка, на экране видно, что Писарь слышит. Выбери, где ей быть.",
                      "While you dictate, the screen shows that Pisar hears you. Pick where it lives.")) {
            SetupBadge(icon: "waveform", color: Color(nsColor: .systemIndigo), granted: false)
        } content: {
            WavePicker(choice: state.waveChoice) { id in
                state.waveChoice = id
                state.pickWave(id)
            }
            .frame(width: Self.cardWidth)
        }
    }

    /// Проверка: можно сразу продиктовать что-нибудь в поле. Если модель
    /// ещё качается, вместо поля стоит полоска — без «ушей» проверять
    /// нечего, и дальше шаг не пускает.
    private var tryContent: some View {
        stage(title: L("Проверим", "Try It"),
              text: state.ready
                ? L("Диктуй в любом окне, где можно печатать.\nНачнём с этого поля.",
                    "You can dictate in any window you can type in.\nLet us start with this field.")
                : L("Модель ещё качается.\nКак только докачается, можно будет проверить.",
                    "The model is still downloading.\nAs soon as it is here, you can try it.")) {
            SetupBadge(icon: "checkmark", color: Color(nsColor: .systemGreen), granted: false)
        } content: {
            if !state.ready {
                SetupProgress(state: state)
                    .frame(width: 345)
            } else {
            VStack(spacing: 8) {
                TextField("", text: $state.tryText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .multilineTextAlignment(.center)
                    .lineLimit(3, reservesSpace: true)
                    .focused($tryFocused)

                Text(L("Зажми \(currentHotkey().title) и скажи что-нибудь",
                       "Hold \(currentHotkey().title) and say something"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(width: Self.cardWidth)
            }
        }
    }

    /// Последний шаг: про Мозг. Он включается в настройках, поэтому
    /// отсюда прямая дорога туда.
    private var brainContent: some View {
        stage(title: L("Мозг", "Brain"),
              text: L("Писарь умеет не только записывать, но и править надиктованное.\nДля этого нужен Мозг — на этом маке или в облаке.",
                      "Pisar can also edit what you dictate, not just type it.\nThat takes the Brain — on this Mac or in the cloud.")) {
            SetupBadge(icon: "brain", color: Color(nsColor: .systemPurple), granted: false)
        } content: {
            // Названия — плашками, два ряда по три: так читается как
            // перечень, а не как ещё одна строка текста.
            VStack(spacing: 6) {
                ForEach([["GigaChat", "Qwen", "DeepSeek"],
                         ["OpenAI", "Gemini", "LM Studio"],
                         [L("и другие", "and others")]], id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { name in
                            Text(name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
                        }
                    }
                }
            }
        }
    }

    /// Оба шага с доступами устроены одинаково: знак, заголовок и две
    /// строки под ним. Выдали доступ — знак зеленеет и текст меняется.
    private func permissionStep<Extra: View>(icon: String, color: Color, granted: Bool,
                                            title: String, text: String,
                                            @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        stage(title: title, text: text) {
            SetupBadge(icon: icon, color: color, granted: granted)
        } content: {
            extra()
        }
    }

    /// Каркас шага: знак, заголовок с подписью и рабочая часть — одной
    /// стопкой, которая стоит по центру того, что осталось над кнопкой.
    /// Жёстких зон больше нет: от шага к шагу строки немного ездят, зато
    /// нигде не зияет пустота.
    private func stage<Icon: View, Content: View>(
        title: String, text: String,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 32) {
            icon()

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(.horizontal, Self.pad)
        // Сверху — чтобы не упереться в «назад» и «Сбросить», снизу —
        // ровно полоса с кнопкой.
        .padding(.top, Self.topZone)
        .padding(.bottom, Self.footer)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Назад — всегда в левом верхнем углу, как в системных мастерах.
    private var backButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.26)) { state.back() }
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 44, height: 30)
                .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(L("Назад", "Back"))
    }

    /// Только для предпросмотра: пройти всё заново, не перезапуская.
    private var resetButton: some View {
        Button {
            state.onReset?()
        } label: {
            Text(L("Сбросить", "Reset"))
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    /// Когда кнопка серая и не нажимается: окно вот-вот уйдёт дальше само
    /// или модель ещё качается, а без неё проверять нечего.
    private var buttonLocked: Bool {
        state.autoAdvancing || (state.step == .tryIt && !state.ready)
    }

    /// Внизу обычно одна кнопка, а на последнем шаге их две: «Завершить»
    /// и «Открыть настройки».
    @ViewBuilder
    private var footerControls: some View {
        if state.step == .brain {
            HStack(spacing: 12) {
                plainButton(L("Готово", "Done")) { state.finish() }
                filledButton(L("Настроить мозг", "Set Up Brain")) { state.openBrain() }
            }
            .fixedSize()
        } else {
            continueButton
                .fixedSize()
        }
    }

    /// Ширину второй кнопки задаём сами: её надо поставить к правому краю,
    /// а по содержимому её положение не вычислить.
    private var brainButtonWidth: CGFloat { 140 }

    /// Вторая кнопка: та же пилюля, но без заливки.
    private func plainButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: brainButtonWidth, height: Self.buttonHeight)
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
    }

    private func filledButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(height: Self.buttonHeight)
                .background(Capsule().fill(Color.accentColor))
        }
        .buttonStyle(.plain)
    }

    /// Рисуем кнопку сами: у системной рамка заметно больше нарисованной
    /// пилюли, и отступ в 32 превращался на глаз в 18.
    private var continueButton: some View {
        Button {
            switch asks {
            case .microphone:    state.askMic()
            case .accessibility: state.askAX()
            default: withAnimation(.easeInOut(duration: 0.26)) { state.next() }
            }
        } label: {
            Text(asks == nil ? L("Продолжить", "Continue")
                             : (asks == .accessibility || state.micDenied
                                ? L("Разрешить в настройках", "Allow in Settings")
                                : L("Разрешить", "Allow")))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(buttonLocked ? Color(nsColor: .tertiaryLabelColor) : .white)
                .lineLimit(1)
                // Ширина по надписи, но не уже прежней: «Разрешить в
                // настройках» в 150 не влезало и ломалось на две строки.
                .padding(.horizontal, 24)
                .frame(minWidth: Self.buttonWidth, minHeight: Self.buttonHeight)
                .background(Capsule().fill(buttonLocked
                                           ? Color(nsColor: .quaternaryLabelColor)
                                           : Color.accentColor))
        }
        .buttonStyle(.plain)
        .disabled(buttonLocked)
    }
}

/// Загрузка модели: полоска и строка под ней. Когда модель на месте,
/// полоска исчезает, а в строке остаётся галочка со словами.
struct SetupProgress: View {
    @ObservedObject var state: SetupState

    var body: some View {
        VStack(spacing: 8) {
            if !state.ready {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
            }
            HStack(spacing: 6) {
                if state.ready {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
                Text(state.sizeLine)
                    // Моноширинные цифры: иначе строка прыгает на каждом
                    // мегабайте.
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Сорвалась — сама не продолжится, нужна кнопка.
            if state.failed {
                Button(L("Попробовать снова", "Try Again")) { state.retry() }
                    .controlSize(.small)
            }
        }
    }
}

/// Фон окна: лёгкий градиент из белого угла в прохладный.
struct SetupBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(.sRGB, red: 1, green: 1, blue: 1),
                                Color(.sRGB, red: 0.94, green: 0.97, blue: 0.99),
                                Color(.sRGB, red: 0.93, green: 0.98, blue: 0.96)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Кольца за знаком: расходятся и тают, как круги по воде.
struct PulseRings: View {
    @State private var spreading = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .strokeBorder(Color(.sRGB, red: 0.35, green: 0.75, blue: 0.55).opacity(0.22),
                                  lineWidth: 1)
                    .frame(width: 140, height: 140)
                    .scaleEffect(spreading ? 1.9 : 0.75)
                    .opacity(spreading ? 0 : 1)
                    .animation(.easeOut(duration: 4.2)
                        .repeatForever(autoreverses: false)
                        .delay(Double(i) * 1.4), value: spreading)
            }
        }
        .onAppear { spreading = true }
    }
}

/// Точки вокруг знака: каждая качается по своей дуге и в своём темпе.
struct FloatingDots: View {
    private struct Dot {
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let color: Color
        let lift: CGFloat
        let duration: Double
        let delay: Double
    }

    private static let dots: [Dot] = [
        Dot(x: -92, y: -46, size: 5, color: Color(.sRGB, red: 0.45, green: 0.80, blue: 0.40), lift: 7, duration: 3.1, delay: 0),
        Dot(x: -104, y: 18, size: 4, color: Color(.sRGB, red: 0.40, green: 0.78, blue: 0.52), lift: 6, duration: 3.8, delay: 0.6),
        Dot(x: -78, y: 58, size: 6, color: Color(.sRGB, red: 0.38, green: 0.82, blue: 0.46), lift: 8, duration: 4.4, delay: 1.1),
        Dot(x: 96, y: -34, size: 5, color: Color(.sRGB, red: 0.38, green: 0.72, blue: 0.95), lift: 7, duration: 3.5, delay: 0.3),
        Dot(x: 108, y: 30, size: 4, color: Color(.sRGB, red: 0.45, green: 0.78, blue: 0.96), lift: 6, duration: 4.1, delay: 0.9),
    ]

    @State private var drifting = false

    var body: some View {
        ZStack {
            ForEach(Array(Self.dots.enumerated()), id: \.offset) { _, dot in
                Circle()
                    .fill(dot.color.opacity(0.75))
                    .frame(width: dot.size, height: dot.size)
                    .offset(x: dot.x, y: dot.y + (drifting ? -dot.lift : dot.lift))
                    .animation(.easeInOut(duration: dot.duration)
                        .repeatForever(autoreverses: true)
                        .delay(dot.delay), value: drifting)
            }
        }
        .onAppear { drifting = true }
    }
}

/// Окно вокруг вида: без кнопок закрытия и сворачивания — пока модели нет,
/// Писарю нечего делать, а бросать загрузку на полпути незачем.
final class SetupWindow: NSObject, NSWindowDelegate {
    let state = SetupState()
    private var window: NSWindow?

    /// `closable` — показать красную кнопку окна. Её ставят, когда окно
    /// открыли из настроек: человек пришёл посмотреть и волен уйти.
    func show(closable: Bool = false) {
        if window == nil { make() }
        state.closable = closable
        state.live = true
        window?.standardWindowButton(.closeButton)?.isHidden = !closable
        // Пока окно открыто, приложение ведёт себя как обычное: с меню
        // «Правка» и иконкой в доке. Иначе в поле не вставить текст —
        // ни руками, ни диктовкой.
        installMainMenu()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        state.live = false
        window?.orderOut(nil)
        // Обычный режим нужен не только нам: если открыты настройки, им
        // без него не работает вставка в поля. Гасим, только когда на
        // экране не осталось ничего нашего.
        let others = NSApp.windows.contains {
            $0 !== window && $0.isVisible && $0.canBecomeKey
        }
        if !others { NSApp.setActivationPolicy(.accessory) }
    }

    /// Закрыли красной кнопкой — для хозяина окна это то же, что «Готово».
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        state.finish()
        return false
    }



    private func make() {
        let host = NSHostingView(rootView: SetupView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 648, height: 506)
        // Полоса заголовка есть, но пустая и прозрачная, а содержимое
        // идёт во всю высоту — поля сверху и снизу совпадают. Красная
        // кнопка при этом настоящая, системная; жёлтая и зелёная окну
        // ни к чему: размер у него один.
        let w = KeyableWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Вид SwiftUI сам просит себе размер и вместе с полосой
        // заголовка раздувал окно на её высоту. Держим его в простой
        // подложке: она размером с окно и больше ничего не просит.
        let holder = NSView(frame: host.frame)
        // Полоса заголовка оставляет за собой безопасную зону, и вид
        // SwiftUI сдвигался под неё — содержимое начиналось ниже края
        // окна. Нам эта зона не нужна: рисуем от самого верха.
        host.safeAreaRegions = []
        host.autoresizingMask = [.width, .height]
        holder.addSubview(host)
        w.contentView = holder
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.delegate = self
        w.center()
        window = w
    }
}


/// Волна с сайта: десять столбиков разной высоты, каждый со своим
/// градиентом от салатового к бирюзовому, и все дышат — scaleY от 0.72
/// до единицы и обратно за 1,6 с, но каждый со своей фазой, поэтому ряд
/// колышется, а не пульсирует целиком. Размеры те же, что на
/// gigapisar.github.io, уменьшенные под окно.
struct WaveMark: View {
    private struct Bar {
        let height: CGFloat
        let phase: Double
        let top: Color
        let bottom: Color
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    /// Высоты с сайта, умноженные на 0.55: ряд выходит 96 пунктов в ширину —
    /// ровно столько, сколько занимала иконка, которая тут была раньше.
    private static let bars: [Bar] = [
        Bar(height: 19, phase: 0.2, top: rgb(0xa8e063), bottom: rgb(0x1fa03a)),
        Bar(height: 34, phase: 0.5, top: rgb(0xa8e063), bottom: rgb(0x1fa03a)),
        Bar(height: 53, phase: 0.9, top: rgb(0x9adf55), bottom: rgb(0x17963f)),
        Bar(height: 70, phase: 0.1, top: rgb(0x8ad84c), bottom: rgb(0x10884a)),
        Bar(height: 48, phase: 0.7, top: rgb(0x7fd648), bottom: rgb(0x0e9367)),
        Bar(height: 65, phase: 0.4, top: rgb(0x63cf62), bottom: rgb(0x009b82)),
        Bar(height: 41, phase: 1.1, top: rgb(0x4fc884), bottom: rgb(0x00a08c)),
        Bar(height: 57, phase: 0.3, top: rgb(0x3fc39b), bottom: rgb(0x00a08c)),
        Bar(height: 31, phase: 0.8, top: rgb(0x38bfa5), bottom: rgb(0x008f92)),
        Bar(height: 17, phase: 0.6, top: rgb(0x35bcb0), bottom: rgb(0x008699)),
    ]

    @State private var breathing = false

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                Capsule()
                    .fill(LinearGradient(colors: [bar.top, bar.bottom],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 6, height: bar.height)
                    .scaleEffect(y: breathing ? 1 : 0.72)
                    .animation(.easeInOut(duration: 0.8)
                        .repeatForever(autoreverses: true)
                        .delay(bar.phase), value: breathing)
            }
        }
        .frame(width: 96, height: 76)
        .onAppear { breathing = true }
    }
}


/// Окно без рамки по умолчанию не становится активным, и всё внутри
/// рисуется приглушённым — полоска загрузки была серой вместо синей.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}


/// Картинка того, что человек увидит в системных настройках: строка
/// Писаря с включённым тумблером. Это не настоящий список — просто
/// показываем, что именно надо сделать.
struct AccessibilityHint: View {
    /// Шаг сейчас на экране: пока нет, тумблер не дёргается впустую.
    let active: Bool
    /// Нажали на строку — открываем настройки, как и кнопкой внизу: в
    /// этот тумблер обязательно будут тыкать.
    let onTap: () -> Void

    var body: some View {
        row(icon: .app, tint: .clear, name: L("Гига Писарь", "Giga Pisar"), on: true)
            .frame(width: 345)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            // Строку можно утащить мышью прямо в список доступа: система
            // принимает туда само приложение, и это короче, чем искать его
            // через «+» в Программах.
            .onDrag {
                let url = Bundle.main.bundleURL
                let item = NSItemProvider(object: url as NSURL)
                item.suggestedName = url.lastPathComponent
                return item
            } preview: {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text(L("Гига Писарь", "Giga Pisar"))
                        .font(.system(size: 12))
                }
                .padding(8)
            }
    }

    private enum Icon {
        case symbol(String)
        case app
    }

    private func row(icon: Icon, tint: Color, name: String, on: Bool) -> some View {
        HStack(spacing: 10) {
            switch icon {
            case .symbol(let s):
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: s)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white))
            case .app:
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
            }

            Text(name)
                .font(.system(size: 12))
            Spacer(minLength: 8)
            DemoSwitch(active: active)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }


}


/// Знак шага с доступом. Повторяет RowIcon, но рисует галочку сам: её
/// надо вывести линией, а не показать готовым символом (анимация
/// символов появилась только в macOS 14, а мы живём с 13.4).
struct SetupBadge: View {
    let icon: String
    let color: Color
    let granted: Bool

    @State private var drawn: CGFloat = 0

    private var base: Color { granted ? Color(nsColor: .systemGreen) : color }
    private var lighter: Color {
        Color(NSColor(base).blended(withFraction: 0.22, of: .white) ?? NSColor(base))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [lighter, base], startPoint: .top, endPoint: .bottom))
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1.5)

            if granted {
                CheckStroke()
                    .trim(from: 0, to: drawn)
                    .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    .frame(width: 42, height: 30)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .onAppear {
                        drawn = 0
                        withAnimation(.easeOut(duration: 0.32)) { drawn = 1 }
                    }
                    .onDisappear { drawn = 0 }
            } else {
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: granted)
    }
}

/// Линия галочки: от левого края вниз к низу и вверх направо.
struct CheckStroke: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}


/// Тумблер в подсказке сам включается и выключается: показываем, что
/// именно надо сделать в настройках. От кружка при включении расходится
/// волна — как палец нажал.
struct DemoSwitch: View {
    /// Шаг открыт. Шаги стоят в ленте все сразу, поэтому обычный onAppear
    /// сработал бы ещё до того, как человек сюда дойдёт.
    let active: Bool

    @State private var on = false
    /// Каждое включение запускает новую волну: меняем номер — вид
    /// пересоздаётся и проигрывает её с начала.
    @State private var wave = 0
    @State private var alive = true

    /// Смещение кружка от середины: он у края, а не по центру.
    private let knobShift: CGFloat = 6.5

    var body: some View {
        Capsule()
            .fill(on ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
            .frame(width: 28, height: 16)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.5)
                    .offset(x: on ? knobShift : -knobShift))
            .overlay(
                Ripple()
                    .id(wave)
                    .offset(x: on ? knobShift : -knobShift))
            .onAppear { if active { start() } }
            .onChange(of: active) { now in
                if now { start() } else { stop() }
            }
            .onDisappear { stop() }
    }

    /// Первый раз — не сразу: человек должен успеть дойти взглядом до
    /// строки, а не застать тумблер уже включённым.
    private func start() {
        alive = true
        on = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard alive else { return }
            cycle()
        }
    }

    private func stop() {
        alive = false
        on = false
    }

    /// Включился, подержался три секунды, выключился, полторы паузы — и снова.
    private func cycle() {
        guard alive else { return }
        withAnimation(.easeInOut(duration: 0.25)) { on = true }
        // Волна идёт не вместе с тумблером, а на 200 мс позже: сперва
        // глаз видит, что он переключился.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard alive else { return }
            wave += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard alive else { return }
            withAnimation(.easeInOut(duration: 0.25)) { on = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { cycle() }
        }
    }
}

/// Круг, который расходится от кружка тумблера и тает.
struct Ripple: View {
    @State private var spread: CGFloat = 0.95
    @State private var fade: Double = 0.45

    var body: some View {
        Circle()
            .stroke(Color.accentColor, lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .scaleEffect(spread)
            .opacity(fade)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9)) {
                    spread = 2.8
                    fade = 0
                }
            }
    }
}


/// Полоса, за которую окно таскают. `isMovableByWindowBackground` тут не
/// спасает: виды SwiftUI забирают нажатия себе, и до фона окна они не
/// доходят, — поэтому тащим сами.
struct WindowDrag: NSViewRepresentable {
    final class Draggable: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { Draggable() }
    func updateNSView(_ view: NSView, context: Context) {}
}


/// Меню «Правка» для окон приложения: без него в поля не вставить текст
/// и не отменить правку — у приложения без иконки в доке меню нет вовсе.
func installMainMenu() {
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
