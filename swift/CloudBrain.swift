// Облачный Мозг в настройках: сервис, ключ, модель — теми же строками со
// значками, что и остальные настройки. Раньше это была отдельная панель
// на AppKit с таблицей «подпись — поле», и она выбивалась из окна.
//
// Вся логика прежняя: ключ узнаётся по виду, список моделей подгружается
// сам, рабочий набор сохраняется и проверяется запросом к нейросети.

import AppKit
import SwiftUI

/// Живое состояние облачной настройки. Отдельно от вида: запросы уходят
/// в сеть и возвращаются когда угодно, а вид пересобирается часто.
final class CloudBrainState: ObservableObject {
    @Published var providerId: String
    @Published var key: String
    @Published var address: String
    @Published var modelName: String
    @Published var models: [String] = []
    @Published var status: String = ""
    @Published var busy = false

    /// Что-то сохранилось — меню и остальные настройки должны это узнать.
    var saved: () -> Void = {}

    private var pause: Timer?
    /// Номер запроса: ответ на устаревший запрос игнорируем.
    private var serial = 0

    init() {
        let current = BrainServer.baseURL.isEmpty ? BrainProviders.deepseek
                                                  : BrainProviders.fromURL(BrainServer.baseURL)
        providerId = current.id
        key = BrainServer.apiKey(for: current.id)
        address = current.isCustom ? BrainServer.baseURL : ""
        modelName = BrainServer.model
        status = BrainServer.configured
            ? L("Текст (не звук) уходит на \(BrainServer.host), модель \(BrainServer.model).",
                "Text (not audio) goes to \(BrainServer.host), model \(BrainServer.model).")
            : L("Выбери сервис и вставь ключ, модель подберётся сама.",
                "Pick the service and paste the key; the model is chosen for you.")
    }

    /// Есть чем спрашивать список моделей: ключ (или адрес своего сервера).
    var readyToPickModel: Bool {
        provider.isCustom
            ? !address.trimmingCharacters(in: .whitespaces).isEmpty
            : !key.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var provider: BrainProvider {
        BrainProviders.all.first { $0.id == providerId } ?? BrainProviders.deepseek
    }

    private var endpoint: String {
        provider.isCustom ? address.trimmingCharacters(in: .whitespaces) : provider.baseURL
    }

    func pickProvider(_ id: String) {
        guard id != providerId else { return }
        providerId = id
        // У каждого сервиса свой ключ: вернулся к прежнему — он на месте,
        // и ключ от облака никогда не уедет на адрес своего сервера.
        key = BrainServer.apiKey(for: id)
        serial += 1
        models = []
        modelName = ""
        status = ""
        if !provider.isCustom, !key.isEmpty { loadModels(pickDefault: true) }
    }

    /// Вставленный ключ сам говорит, от какого он сервиса; через паузу
    /// подтягивается список моделей.
    func keyChanged() {
        if let guess = BrainProviders.fromKey(key), guess.id != providerId,
           !(provider.isCustom && !address.isEmpty) {
            providerId = guess.id
            serial += 1
            models = []
            modelName = ""
            status = L("Похоже на ключ \(guess.name), выбрал его.", "Looks like a \(guess.name) key, selected it.")
        }
        pause?.invalidate()
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            serial += 1
            busy = false
            return
        }
        pause = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.loadModels(pickDefault: true)
        }
    }

    func addressChanged() {
        guard provider.isCustom, BrainServer.completionsURL(endpoint) != nil else { return }
        loadModels(pickDefault: modelName.isEmpty)
    }

    func reload() { loadModels(pickDefault: modelName.trimmingCharacters(in: .whitespaces).isEmpty) }

    func loadModels(pickDefault: Bool) {
        guard BrainServer.completionsURL(endpoint) != nil else {
            status = L("Впиши адрес сервера.", "Enter the server address.")
            return
        }
        serial += 1
        let mine = serial, p = provider
        status = L("Проверяю ключ и загружаю модели…", "Checking the key and loading models…")
        busy = true
        BrainServer.fetchModels(base: endpoint, key: key.trimmingCharacters(in: .whitespaces)) { [weak self] r in
            DispatchQueue.main.async {
                guard let self, mine == self.serial else { return }
                self.busy = false
                switch r {
                case .success(let all):
                    let ids = BrainProviders.chatModels(all)
                    let typed = self.modelName.trimmingCharacters(in: .whitespaces)
                    self.models = ids
                    self.modelName = pickDefault || typed.isEmpty ? (BrainProviders.pickDefault(p, ids) ?? "") : typed
                    self.saveAndProbe()
                case .failure(let e):
                    let code = (e as NSError).code
                    if code == 401 || code == 403 {
                        self.status = L("\(p.name) не принял ключ. Проверь, что ключ от этого сервиса и скопирован целиком.",
                                        "\(p.name) rejected the key. Check that it is for this service and copied in full.")
                    } else {
                        if !p.isCustom, self.modelName.isEmpty { self.modelName = p.preferredModels.first ?? "" }
                        self.status = L("Список моделей не загрузился: \(e.localizedDescription)",
                                        "Could not load the model list: \(e.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Сохраняем рабочий набор (адрес, модель, ключ) и проверяем, что
    /// нейросеть отвечает.
    func saveAndProbe() {
        let m = modelName.trimmingCharacters(in: .whitespaces)
        let k = key.trimmingCharacters(in: .whitespaces)
        guard BrainServer.completionsURL(endpoint) != nil, !m.isEmpty, provider.isCustom || !k.isEmpty else { return }
        guard !BrainServer.insecureRemote(endpoint) else {
            status = L("Для сервера в интернете нужен адрес https://. Обычный http работает только на этом маке и в домашней сети.",
                       "A server on the internet needs an https:// address. Plain http works only on this Mac and your home network.")
            return
        }
        guard BrainServer.saveKey(k, for: providerId) else {
            status = L("Не получилось сохранить ключ в Связку ключей. Попробуй ещё раз.",
                       "Could not save the key to the Keychain. Try again.")
            return
        }
        BrainServer.baseURL = endpoint
        BrainServer.model = m
        serial += 1
        let mine = serial, host = BrainServer.host
        status = L("Ключ подошёл, проверяю модель \(m)…", "The key works, checking model \(m)…")
        BrainServer.probe(base: endpoint, key: k, model: m) { [weak self] failure in
            DispatchQueue.main.async {
                guard let self, mine == self.serial else { return }
                self.status = failure == nil
                    ? L("Всё работает, сохранено. Модель \(m), текст (не звук) уходит на \(host).",
                        "All set and saved. Model \(m); text (not audio) goes to \(host).")
                    : L("Ключ принят, но нейросеть не отвечает: \(failure!).",
                        "The key is accepted, but the model does not answer: \(failure!).")
                self.saved()
            }
        }
    }
}

struct CloudBrainView: View {
    @ObservedObject var state: CloudBrainState

    var body: some View {
        VStack(spacing: 18) {
            SettingsCard {
                SettingsRow(icon: "cloud.fill", color: Color(nsColor: .systemBlue),
                            title: L("Сервис", "Service"),
                            subtitle: BrainAdvice.service(state.provider)) {
                    Picker("", selection: Binding(get: { state.providerId },
                                                  set: { state.pickProvider($0) })) {
                        ForEach(BrainProviders.all, id: \.id) { p in
                            Text(BrainProviders.title(p)).tag(p.id)
                        }
                    }
                    .labelsHidden().fixedSize()
                }

                if state.provider.isCustom {
                    RowDivider()
                    SettingsRow(icon: "network", color: Color(nsColor: .systemTeal),
                                title: L("Адрес", "Address")) {
                        TextField("http://localhost:1234/v1", text: $state.address)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .onSubmit { state.addressChanged() }
                    }
                }
            }

            // Ключ — отдельной секцией: это длинная строка, которой нужна
            // вся ширина, и рамка поля тут только мешает.
            if !state.provider.isCustom {
                // Без заголовка секции: строка сама себя называет.
                VStack(alignment: .leading, spacing: 7) {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 11) {
                                RowIcon(systemName: "key.fill", backgroundColor: Color(nsColor: .systemOrange),
                                        sideLength: 22, reservesHeight: true)
                                Text(L("Ключ API", "API Key"))
                                Spacer(minLength: 12)
                                Button(L("Где взять ключ \(state.provider.name) →",
                                         "Get a \(state.provider.name) key →")) {
                                    if let u = URL(string: state.provider.keysURL), !state.provider.keysURL.isEmpty {
                                        NSWorkspace.shared.open(u)
                                    }
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                            }
                            HStack(spacing: 8) {
                                SecureField(L("вставьте ключ сюда", "paste the key here"), text: $state.key)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    // Длинный ключ иначе переносится и
                                    // растягивает строку в несколько этажей.
                                    .lineLimit(1)
                                    .frame(height: 18)
                                    .onChange(of: state.key) { _ in state.keyChanged() }
                                Button(L("Вставить из буфера", "Paste")) {
                                    let provider = state.providerId, address = state.address
                                    let original = state.key
                                    DictationClipboard.shared.readText { text in
                                        guard state.providerId == provider, state.address == address,
                                              state.key == original else { return }
                                        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !trimmed.isEmpty else { return }
                                        state.key = trimmed
                                        state.keyChanged()
                                    }
                                }
                                .controlSize(.small)
                            }
                            .padding(.leading, 33)   // под названием: значок 22 + просвет 11
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                    }
                    Text(L("Ключ хранится в Связке ключей этого мака и никуда больше не уходит.",
                           "The key is kept in this Mac's Keychain and goes nowhere else."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }

            // Модель спрашивать не у чего, пока нет ключа (или адреса
            // своего сервера): список подтягивается сам, как только ключ
            // вставлен.
            if state.readyToPickModel {
                SettingsCard {
                    SettingsRow(icon: "cpu.fill", color: Color(nsColor: .systemPurple),
                                title: L("Модель", "Model"),
                                subtitle: state.status) {
                        HStack(spacing: 8) {
                            if state.models.isEmpty {
                                // У облачного сервиса список моделей —
                                // стандартная ручка: не ответила, значит не
                                // принят ключ, и вписанное руками имя не
                                // спасёт. А свой сервер список отдаёт не
                                // всегда, там имя задают вручную.
                                if state.provider.isCustom {
                                    TextField("", text: $state.modelName)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 160)
                                        .onSubmit { state.saveAndProbe() }
                                } else {
                                    Text(state.busy ? L("загружаю…", "loading…")
                                                    : (state.modelName.isEmpty ? "—" : state.modelName))
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Picker("", selection: Binding(get: { state.modelName },
                                                              set: { state.modelName = $0; state.saveAndProbe() })) {
                                    ForEach(state.models, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden().frame(maxWidth: 200)
                            }
                            Button(L("Обновить", "Reload")) { state.reload() }
                                .disabled(state.busy)
                        }
                    }
                }
            }
        }
    }
}
