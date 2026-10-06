// Мозг Писаря: локальная нейронка правит надиктованный текст по команде.
//
// Говоришь текст, в конце добавляешь обращение обычными словами:
//   «…жду ответа. Писарь, исправь»
//   «…созвон в пять. Гига Писарь, переведи на английский»
// Всё после слова «Писарь» — команда. Не позвал Писаря — текст вставляется
// сырым и мгновенно, нейронка его даже не видит.
//
// Нейронка — просто файл на диске (~/Library/Application Support/Giga Pisar/
// models), крутится локально через приложенный llama-server (движок llama.cpp,
// Contents/Frameworks/llama). Ничего в интернет не уходит — как и распознавание.
// Сервер поднимается при первой команде (она из-за этого дольше, ~10 с),
// думает 1–4 секунды, а после 15 минут простоя выгружается — память дороже.
//
// Если нейронка не ответила за разумное время или упала — вставляем сырой
// текст: диктовка не имеет права сломаться из-за мозга.

import AppKit
import Security

// MARK: own server (OpenAI-compatible API)
//
// Instead of a local model the Brain can think on a server the user picks:
// a cloud service with a key (OpenRouter, DeepSeek, OpenAI…) or their own
// LM Studio / Ollama / llama.cpp. Only the recognized text is sent, never
// audio. The key lives in the login keychain, not in UserDefaults.

enum BrainServer {
    static let id = "server"
    private static let keychainService = "Giga Pisar Brain"
    /// Ключ у каждого сервиса свой: переключился на другой и вернулся —
    /// прежний ключ на месте. До 3.9 ключ был один на всех, он лежит под
    /// этой учёткой и переезжает к своему сервису при первом обращении.
    private static let legacyAccount = "api-key"
    private static func account(_ providerId: String) -> String { "api-key." + providerId }

    /// Чей ключ нужен прямо сейчас — по сохранённому адресу.
    static var currentProviderId: String {
        baseURL.isEmpty ? BrainProviders.deepseek.id : BrainProviders.fromURL(baseURL).id
    }

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: "brainServerURL") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "brainServerURL") }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "brainServerModel") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "brainServerModel") }
    }

    /// Единственный ключ, сохранённый прежними версиями, отдаём тому
    /// сервису, который тогда и был настроен (копией: старая запись остаётся).
    static func migrateLegacyKey() {
        guard !UserDefaults.standard.bool(forKey: "brainKeyMigrated") else { return }
        let old = read(account: legacyAccount)
        guard !old.isEmpty else {
            UserDefaults.standard.set(true, forKey: "brainKeyMigrated")
            return
        }
        // Отметку ставим только после удачного переезда: иначе сбой
        // Связки ключей молча оставил бы человека без ключа.
        guard write(old, account: account(currentProviderId)) else { return }
        // Старую запись оставляем: откатится человек на 3.8.x — ключ на месте.
        UserDefaults.standard.set(true, forKey: "brainKeyMigrated")
        NSLog("Гига мозг: ключ переехал к сервису \(currentProviderId)")
    }

    /// Stores the key (empty removes it). Returns false when the Keychain refused.
    @discardableResult
    static func saveKey(_ raw: String, for providerId: String? = nil) -> Bool {
        write(raw, account: account(providerId ?? currentProviderId))
    }

    static var apiKey: String { apiKey(for: currentProviderId) }

    static func apiKey(for providerId: String) -> String {
        migrateLegacyKey()
        return read(account: account(providerId))
    }

    private static func write(_ raw: String, account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService,
                                   kSecAttrAccount as String: account]
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let s = SecItemDelete(base as CFDictionary)
            return s == errSecSuccess || s == errSecItemNotFound
        }
        // Update in place, so a failed write never loses the old key.
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data(key.utf8)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { NSLog("Giga brain: keychain save failed (\(status))") }
        return status == errSecSuccess
    }

    private static func read(account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// ".../v1" -> ".../v1/chat/completions"; the full path is accepted as is.
    static func completionsURL(_ base: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return s.lowercased().hasSuffix("/chat/completions") ? u : URL(string: s + "/chat/completions")
    }
    static func modelsURL(_ base: String) -> URL? {
        guard let c = completionsURL(base) else { return nil }
        return c.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
    }

    static var configured: Bool { completionsURL(baseURL) != nil && !model.isEmpty }
    /// "api.deepseek.com" for menus.
    static var host: String { URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL }

    /// Plain http to somewhere that is neither this Mac nor the local network: text and key travel in the clear.
    static func insecureRemote(_ base: String) -> Bool {
        guard let u = URL(string: base.trimmingCharacters(in: .whitespaces)), u.scheme?.lowercased() == "http",
              let h = u.host?.lowercased() else { return false }
        if h == "localhost" || h == "127.0.0.1" || h == "::1" || h.hasSuffix(".local") { return false }
        let p = h.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            if p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1]))
                || (p[0] == 100 && (64...127).contains(p[1])) { return false }
        }
        return true
    }

    /// macOS (App Transport Security) lets plain http reach only this Mac and the local network.
    static func atsBlocked(_ error: Error?) -> Bool {
        (error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection
    }
    static var httpsNeeded: String {
        L("для сервера в интернете нужен адрес https://", "a server on the internet needs an https:// address")
    }

    /// The error text an OpenAI-style server puts in {"error":{"message":…}} or {"message":…}.
    static func serverMessage(_ data: Data?) -> String {
        guard let data else { return "" }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let e = obj["error"] as? String { return e }
            if let m = obj["message"] as? String { return m }
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    /// What went wrong, in words a person can act on; the raw server text goes to the log.
    static func describeFailure(code: Int, body: Data?, error: Error?) -> String {
        if atsBlocked(error) { return httpsNeeded }
        if let e = error as? URLError {
            return e.code == .timedOut ? L("сервер не ответил вовремя", "the server did not answer in time")
                                       : L("нет связи с сервером, проверь интернет", "cannot reach the server, check the connection")
        }
        let raw = serverMessage(body)
        if !raw.isEmpty { NSLog("Giga brain: server \(code): \(raw)") }
        let m = (raw + " " + (body.flatMap { String(data: $0, encoding: .utf8) } ?? "")).lowercased()
        if code == 402 || ["insufficient_quota", "quota", "billing", "balance", "credit", "payment"].contains(where: m.contains) {
            return L("на счету сервиса нет денег или не подключена оплата API (это отдельно от подписки вроде ChatGPT Plus)",
                     "no money on the service account or API billing is not set up (separate from subscriptions like ChatGPT Plus)")
        }
        if ["country", "region", "territory", "location"].contains(where: m.contains) {
            return L("сервис недоступен из твоей страны", "the service is not available in your country")
        }
        switch code {
        case 401: return L("сервис не принял ключ", "the service rejected the key")
        case 403: return L("у ключа нет доступа к этой модели или сервису", "the key has no access to this model or service")
        case 404: return L("модель недоступна для этого ключа, выбери другую", "the model is not available for this key, pick another one")
        case 429: return L("слишком много запросов, попробуй через минуту", "too many requests, try again in a minute")
        case 500...: return L("у сервиса сбой (ошибка \(code)), попробуй позже", "the service is failing (error \(code)), try later")
        default: return L("сервис ответил ошибкой \(code)", "the service answered with error \(code)")
        }
    }

    /// A one-word request: a key that lists models may still be unable to chat (no API balance,
    /// no access to the model, a blocked country). done(nil) means the model answers.
    static func probe(base: String, key: String, model: String, done: @escaping (String?) -> Void) {
        guard let url = completionsURL(base) else { done(L("неверный адрес", "invalid address")); return }
        var req = request(url, key: key)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "Ответь одним словом: ок"]],
        ])
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            done(code == 200 ? nil : describeFailure(code: code, body: data, error: error))
        }.resume()
    }

    static func request(_ url: URL, key: String) -> URLRequest {
        var req = URLRequest(url: url)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Model ids from GET /models, for the picker.
    static func fetchModels(base: String, key: String, done: @escaping (Result<[String], Error>) -> Void) {
        guard let url = modelsURL(base) else {
            done(.failure(NSError(domain: "Giga", code: 1, userInfo: [NSLocalizedDescriptionKey: L("неверный адрес", "invalid address")])))
            return
        }
        var req = request(url, key: key)
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error {
                done(.failure(atsBlocked(error)
                    ? NSError(domain: "Giga", code: -1022, userInfo: [NSLocalizedDescriptionKey: httpsNeeded])
                    : error))
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["data"] as? [[String: Any]] else {
                done(.failure(NSError(domain: "Giga", code: code,
                                      userInfo: [NSLocalizedDescriptionKey: L("сервер ответил \(code)", "server answered \(code)")])))
                return
            }
            done(.success(list.compactMap { $0["id"] as? String }.sorted()))
        }.resume()
    }
}

struct BrainModel {
    let id: String
    let name: String        // короткое имя для меню
    let details: String     // честное описание: вес, чей русский, какие маки
    let file: String
    let url: String
    /// Зеркала, которые пробуем раньше url: из России Hugging Face еле ползёт
    /// (сотни килобайт в секунду), а GitHub отдаёт в десятки раз быстрее.
    var mirrors: [String] = []
    /// Точный размер файла: страница ошибки вместо модели не пройдёт.
    var bytes: Int64 = 0
    /// SHA-256 of the file: a replaced or damaged model is never loaded.
    var sha256: String = ""
    /// Прежние имена файла: у кого модель уже скачана под старым именем,
    /// она остаётся и работает, перекачивать не заставляем.
    var legacyFiles: [String] = []
    let sizeText: String    // «6,5 ГБ» — для пункта «скачать»
    let minRAMGB: UInt64    // ниже этого объёма памяти отговариваем
    var icon: String? = nil // значок в меню: системный символ или свой из ресурсов
}

var BRAIN_MODELS: [BrainModel] { [
    BrainModel(id: "gigachat",
               name: "GigaChat",
               details: L("родной русский · 6,5 ГБ · маки от 16 ГБ",
                          "native Russian · 6.5 GB · Macs with 16 GB"),
               file: "GigaChat3.1-10B-A1.8B-q4_K_M.gguf",
               url: "https://huggingface.co/ai-sage/GigaChat3.1-10B-A1.8B-GGUF/resolve/main/GigaChat3.1-10B-A1.8B-q4_K_M.gguf",
               bytes: 6_474_702_976,
               sha256: "68a8732fb5cee04f83ebffd7924e15c534d4442c5a43d2ba9e2041fe310b8deb",
               sizeText: L("6,5 ГБ", "6.5 GB"),
               minRAMGB: 16,
               icon: "gigachat"),
    BrainModel(id: "qwen",
               name: "Qwen",
               details: L("лёгкая · 1,9 ГБ · русский неродной, но аккуратная",
                          "light · 1.9 GB · non-native Russian, but tidy"),
               // Q3_K_M вместо Q4_K_M (18.09.2026): в памяти 2,35 ГБ вместо 3,0,
               // качество на наших командах не хуже. Q2 уже коверкает слова.
               file: "Qwen3-4B-Instruct-2507-Q3_K_M.gguf",
               url: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q3_K_M.gguf",
               // тот же файл байт в байт, что качает Писарь для Windows
               mirrors: ["https://github.com/moznoazachem/giga-pisar-win/releases/download/brain-models/Qwen3-4B-Instruct-2507-Q3_K_M.gguf"],
               bytes: 2_075_618_400,
               sha256: "9c6e0763577125a994a9bea0bbd7a737ac4498b8a6a4e0f788727553af1806c9",
               legacyFiles: ["Qwen3-4B-Instruct-2507-Q4_K_M.gguf"],
               sizeText: L("1,9 ГБ", "1.9 GB"),
               minRAMGB: 8,
               icon: "qwen"),
] }

final class Brain: NSObject, URLSessionDownloadDelegate {
    static let shared = Brain()
    static let port: UInt16 = 8617
    /// Random per launch: other programs on this Mac (or a web page) can't use our server.
    private let serverKey = UUID().uuidString + UUID().uuidString

    /// Что выбрано в меню. nil — мозг выключен.
    var chosenId: String? {
        get {
            guard let v = UserDefaults.standard.string(forKey: "brainModel"),
                  v != "off" else { return nil }
            return v
        }
        set { UserDefaults.standard.set(newValue ?? "off", forKey: "brainModel") }
    }

    var chosenModel: BrainModel? { BRAIN_MODELS.first { $0.id == chosenId } }

    /// Кнопочки-подсказки после вставки. По умолчанию ВЫКЛЮЧЕНЫ (решение
    /// от 02.09.2026: менюшка после каждой вставки мешает, кто хочет,
    /// включит сам). Явный выбор пользователя хранится и уважается.
    var chipsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "brainChips") }
        set { UserDefaults.standard.set(newValue, forKey: "brainChips") }
    }
    /// The Brain thinks on the user's server rather than on this Mac.
    var usesServer: Bool { chosenId == BrainServer.id }
    /// Ready to work: a server is set up, or a local model is chosen, on disk and the engine is here.
    var ready: Bool {
        if usesServer { return BrainServer.configured }
        return engineAvailable && (chosenModel.map { downloaded($0) } ?? false)
    }
    /// Send every take through the Brain, not only those ending with "Писарь, …". Off by default:
    /// with a local model every paste would wait seconds.
    /// With text selected at the key press, the take is a command on the selection. On by default;
    /// turned off, a selection changes nothing and plain dictation goes over it.
    var onSelection: Bool {
        get { UserDefaults.standard.object(forKey: "brainOnSelection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "brainOnSelection") }
    }
    var everyTake: Bool {
        get { UserDefaults.standard.bool(forKey: "brainEveryTake") }
        set { UserDefaults.standard.set(newValue, forKey: "brainEveryTake") }
    }

    /// Меню перерисовать (и процент скачивания показать) — дергает App.
    var onChange: (() -> Void)?

    // MARK: файлы моделей

    static var modelsDir: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Giga Pisar/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
    /// Лежит ли у человека модель под старым именем (скачана до смены файла).
    func usesLegacyFile(_ m: BrainModel) -> Bool {
        !FileManager.default.fileExists(atPath: Self.modelsDir + "/" + m.file) && m.legacyFiles.contains { FileManager.default.fileExists(atPath: Self.modelsDir + "/" + $0) }
    }
    /// Что написать под моделью в меню: для старого файла его настоящий размер.
    func detailsText(_ m: BrainModel) -> String {
        guard usesLegacyFile(m) else { return m.details }
        let size = (try? FileManager.default.attributesOfItem(atPath: path(m)))?[.size] as? UInt64 ?? 0
        return L("скачана раньше · \(Memory.gb(size)) ГБ · работает как есть",
                 "downloaded earlier · \(Memory.gb(size)) GB · works as is")
    }

    /// Файл модели: новый, а если его нет, но лежит старый — старый.
    func path(_ m: BrainModel) -> String {
        let fresh = Self.modelsDir + "/" + m.file
        if FileManager.default.fileExists(atPath: fresh) { return fresh }
        for old in m.legacyFiles {
            let p = Self.modelsDir + "/" + old
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return fresh
    }
    /// Сколько памяти займёт поднятая модель: файл целиком плюс контекст
    /// и накладные llama.cpp (около 700 МБ при контексте 4096).
    func memoryNeeded(_ m: BrainModel) -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: path(m)))?[.size] as? UInt64 ?? 0
        return size + 700 * 1_048_576
    }
    /// Скачана целиком: файл на месте и весит как модель, а не как обрывок
    /// (меньше гигабайта у нейронки не бывает; обрывок llama-server не
    /// поднимет, и человек видел бы «Запускаю нейронку…» без конца).
    func downloaded(_ m: BrainModel) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path(m)))?[.size] as? Int64 ?? 0
        return size > 900_000_000
    }

    /// Сколько места занимает файл модели на диске.
    func fileSize(_ m: BrainModel) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path(m)))?[.size] as? Int64 ?? 0
    }

    /// Удалить скачанный файл — освободить место. Если модель работала,
    /// сначала гасим сервер, иначе он держит файл открытым.
    func deleteFile(_ m: BrainModel) {
        if chosenId == m.id { stopServer() }
        try? FileManager.default.removeItem(atPath: Self.modelsDir + "/" + m.file)
        for old in m.legacyFiles {
            try? FileManager.default.removeItem(atPath: Self.modelsDir + "/" + old)
        }
        onChange?()
    }

    // MARK: скачивание модели (с процентами и докачкой после обрывов)

    private(set) var downloadingId: String?
    private(set) var downloadPercent = 0
    /// Сколько байт уже скачано и сколько всего: в настройках показываем
    /// это словами — «2,1 из 6,5 ГБ», а не только проценты.
    private(set) var downloadedBytes: Int64 = 0
    private(set) var downloadTotalBytes: Int64 = 0
    private var dlSession: URLSession?
    private var dlTask: URLSessionDownloadTask?
    private var dlRetries = 0
    /// Какой адрес из «зеркала, потом основной» качаем сейчас.
    private var dlSourceIndex = 0

    private func sources(_ m: BrainModel) -> [String] { m.mirrors + [m.url] }

    /// Следующий адрес, если этот не дал файла. false — адреса кончились.
    private func tryNextSource() -> Bool {
        guard let id = downloadingId, let m = BRAIN_MODELS.first(where: { $0.id == id }),
              dlSourceIndex + 1 < sources(m).count, let sess = dlSession else { return false }
        dlSourceIndex += 1
        dlRetries = 0
        let next = sources(m)[dlSourceIndex]
        NSLog("Гига мозг: качаю с запасного адреса \(next)")
        dlTask = sess.downloadTask(with: URL(string: next)!)
        dlTask?.resume()
        return true
    }

    func startDownload(_ m: BrainModel) {
        cancelDownload()
        downloadingId = m.id
        downloadPercent = 0
        downloadedBytes = 0
        downloadTotalBytes = 0
        dlRetries = 0
        dlSourceIndex = 0
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        dlSession = s
        dlTask = s.downloadTask(with: URL(string: sources(m)[0])!)
        dlTask?.resume()
        onChange?()
    }

    func cancelDownload() {
        dlTask?.cancel()
        dlSession?.invalidateAndCancel()
        dlTask = nil; dlSession = nil
        downloadingId = nil
        onChange?()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        downloadedBytes = totalBytesWritten
        downloadTotalBytes = totalBytesExpectedToWrite
        let p = Int(100 * totalBytesWritten / totalBytesExpectedToWrite)
        guard p != downloadPercent else { return }
        downloadPercent = p
        DispatchQueue.main.async { self.onChange?() }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadingId, let m = BRAIN_MODELS.first(where: { $0.id == id })
        else { return }
        // Сервер мог отдать страницу ошибки, а не модель: проверяем ответ и размер.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? Int64) ?? 0
        let hashOK = status == 200 && (m.bytes == 0 || size == m.bytes)
            && (m.sha256.isEmpty || sha256Hex(ofFile: location.path) == m.sha256)
        if !hashOK {
            NSLog("Гига мозг: адрес отдал не модель (ответ \(status), \(size) байт)")
            DispatchQueue.main.async {
                if !self.tryNextSource() {
                    self.downloadingId = nil
                    self.onChange?()
                    Toast.shared.show(L("Скачивание сорвалось — попробуй ещё раз из меню",
                                        "Download failed — try again from the menu"))
                }
            }
            return
        }
        try? FileManager.default.removeItem(atPath: path(m))
        do {
            try FileManager.default.moveItem(atPath: location.path, toPath: path(m))
            DispatchQueue.main.async {
                self.downloadingId = nil
                self.dlTask = nil; self.dlSession = nil
                self.chosenId = id       // скачал — сразу и выбрал
                self.onChange?()
                Toast.shared.show(L("\(m.name) скачан — Писарь слушает команды",
                                    "\(m.name) is ready — Pisar takes commands now"))
            }
        } catch {
            NSLog("Гига мозг: не сохранил модель — \(error)")
            DispatchQueue.main.async {
                self.downloadingId = nil
                self.onChange?()
            }
        }
        s.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, downloadingId != nil else { return }
        // Сеть мигнула — докачиваем с места обрыва, до пяти попыток.
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        DispatchQueue.main.async {
            if let resume, self.dlRetries < 5, let sess = self.dlSession {
                self.dlRetries += 1
                NSLog("Гига мозг: обрыв, докачиваю (попытка \(self.dlRetries))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard self.downloadingId != nil else { return }
                    self.dlTask = sess.downloadTask(withResumeData: resume)
                    self.dlTask?.resume()
                }
            } else if self.tryNextSource() {
                return
            } else {
                NSLog("Гига мозг: скачивание сорвалось — \(error)")
                self.downloadingId = nil
                self.onChange?()
                Toast.shared.show(L("Скачивание сорвалось — попробуй ещё раз из меню",
                                    "Download failed — try again from the menu"))
            }
        }
    }

    // MARK: llama-server рядом с нами

    private var server: Process?
    private var serverModelId: String?

    /// Лог llama-server: ~/Library/Logs/Giga Pisar/brain.log, перезаписывается при запуске.
    static var logPath: String {
        NSHomeDirectory() + "/Library/Logs/Giga Pisar/brain.log"
    }
    /// Почему не вышло в последний раз, по-человечески; nil — причина неизвестна.
    private(set) var lastFailure: String?
    /// Текст для плашки: общая фраза плюс причина, если она известна.
    func failureText(_ generic: String) -> String {
        guard let why = lastFailure else { return generic }
        return generic + ". " + why.prefix(1).uppercased() + why.dropFirst()
    }
    private var idleTimer: Timer?

    /// Нейронка ест 3–6 ГБ памяти, пока сидит в сервере. Без дела не держим:
    /// поднимается при первой команде, через 15 минут простоя выгружается.
    private func scheduleIdleStop() {
        DispatchQueue.main.async { [weak self] in
            self?.idleTimer?.invalidate()
            self?.idleTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60,
                                                   repeats: false) { [weak self] _ in
                NSLog("Гига мозг: 15 минут без работы — отпускаю память")
                self?.stopServer()
            }
        }
    }

    private var serverBinary: String {
        Bundle.main.bundlePath + "/Contents/Frameworks/llama/llama-server"
    }
    /// Движок вложен только для Apple Silicon: на M-чипах нейронка летает,
    /// на Intel мучилась бы. Там мозг в меню честно говорит, что не судьба.
    var engineAvailable: Bool {
        #if arch(arm64)
        return FileManager.default.fileExists(atPath: serverBinary)
        #else
        return false
        #endif
    }

    /// Поднять сервер под выбранную модель (или погасить, если мозг выключен).
    func ensureServer() {
        guard let m = chosenModel, downloaded(m), engineAvailable else {
            stopServer()
            return
        }
        if let s = server, s.isRunning, serverModelId == m.id { return }
        stopServer()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: serverBinary)
        p.arguments = ["-m", path(m), "--host", "127.0.0.1", "--port", "\(Self.port)",
                       "-c", "4096", "-ngl", "99", "--no-webui",
                       "--no-slots", "--api-key", serverKey]
        // Что говорит сервер, пишем в лог: когда нейронка не поднимается на
        // чужом маке, без этого не понять, почему.
        let log = Self.logPath
        try? FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log, contents: nil)
        let handle = FileHandle(forWritingAtPath: log)
        p.standardOutput = handle ?? FileHandle.nullDevice
        p.standardError = handle ?? FileHandle.nullDevice
        lastFailure = nil
        do {
            try p.run()
            server = p
            serverModelId = m.id
            NSLog("Гига мозг: поднял \(m.name) на порту \(Self.port), лог \(log)")
        } catch {
            NSLog("Гига мозг: сервер не поднялся — \(error)")
            lastFailure = L("нейронка не запустилась", "the brain didn't start")
        }
    }

    func stopServer() {
        server?.terminate()
        server = nil
        serverModelId = nil
    }

    // MARK: обращение «Писарь, …»

    /// Ищет в тексте обращение к Писарю. Всё после него — команда.
    /// Берём ПОСЛЕДНЕЕ вхождение: если в самом тексте шла речь про Писаря,
    /// сработает только хвостовое обращение. Распознавание может услышать
    /// «песарь» или «писарь» с разными окончаниями — сравнение мягкое.
    static func parseCommand(_ text: String) -> (body: String, command: String)? {
        let pat = "(?:гига[\\s,—-]+)?п[еиэ]сар[ьяюе]?\\b[\\s,.:!—-]*"
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive])
        else { return nil }
        let ns = text as NSString
        let all = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let m = all.last else { return nil }
        let command = ns.substring(from: m.range.location + m.range.length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var body = ns.substring(to: m.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // висячие запятые и тире перед обращением («…текст, Писарь исправь»)
        while let last = body.last, ",—-–".contains(last) {
            body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !command.isEmpty, !body.isEmpty else { return nil }
        return (body, command)
    }

    /// Обращение «Писарь,» в начале голосовой команды над выделением —
    /// необязательное, но если сказано, в команду не попадает.
    static func stripAddress(_ text: String) -> String {
        let pat = "^\\s*(?:гига[\\s,—-]+)?п[еиэ]сар[ьяюе]?\\b[\\s,.:!—-]*"
        guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive])
        else { return text }
        let ns = text as NSString
        let out = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                              withTemplate: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: сама работа

    /// Что за текст правим: наговоренный (убираем оговорки и паразиты)
    /// или выделенный человеком в документе (уже написанный, трогаем
    /// только то, что просит команда).
    enum Mode { case dictation, selection }

    private static let selectionPrompt = """
    Ты редактируешь текст, который пользователь выделил в своём документе, \
    и выполняешь над ним команду пользователя. Сохраняй смысл и разбиение \
    на абзацы, ничего не добавляй от себя и не комментируй. Тон и стиль \
    сохраняй, если только команда не велит их изменить: команда важнее. \
    Команда дана в конце этой инструкции, в сам текст не входит, и \
    упоминать её в ответе нельзя. Верни ТОЛЬКО готовый текст, без кавычек \
    вокруг него.
    """

    private static let systemPrompt = """
    Ты обрабатываешь надиктованный голосом текст перед вставкой. Правила: \
    убери слова-паразиты и оговорки (э, ну, типа, вот, как бы), убери повторы \
    и самоисправления, расставь знаки препинания, исправь очевидные ошибки \
    распознавания. Сохраняй смысл и лексику, ничего не добавляй от себя и \
    не комментируй. Живой тон автора сохраняй, если только команда не велит \
    его изменить: команда важнее тона. Выполни команду пользователя: она \
    дана в конце этой инструкции, в сам текст не входит, и упоминать её \
    в ответе нельзя. Верни ТОЛЬКО готовый текст, без кавычек вокруг него.
    """

    /// Прогнать текст через нейронку. done зовётся на любом исходе:
    /// с готовым текстом — или с nil, если мозг не справился (тогда
    /// вызывающий вставляет сырой текст, диктовка не ломается).
    /// Что показать на плашке-статусе, пока нейронка думает.
    static func actionLabel(_ command: String) -> String {
        let c = command.lowercased()
        if c.contains("перевед") || c.contains("англ") { return L("Перевожу…", "Translating…") }
        if c.contains("сократ") || c.contains("короче") { return L("Сокращаю…", "Shortening…") }
        if c.contains("мысль") { return L("Собираю мысль…", "Composing…") }
        if c.contains("сглад") || c.contains("мягче") { return L("Сглаживаю…", "Smoothing…") }
        if c.contains("исправ") || c.contains("ошибк") { return L("Исправляю…", "Fixing…") }
        return L("Причёсываю…", "Polishing…")
    }

    func transform(_ body: String, command: String, mode: Mode = .dictation,
                   done: @escaping (String?) -> Void) {
        // холодный старт — нейронку ещё надо поднять с диска (~10 секунд),
        // человек должен видеть, что происходит, а не гадать
        let cold = !usesServer && (server?.isRunning != true || serverModelId != chosenId)
        // Перед холодным стартом смотрим, влезет ли модель в свободную
        // память. Не влезет — macOS начнёт выгружать чужое на диск, и старт
        // растянется на минуты. Лучше спросить заранее, чем молча висеть.
        if cold, let m = chosenModel {
            let need = memoryNeeded(m), free = Memory.available
            if free < need {
                onMainInModal {
                    let a = NSAlert()
                    a.messageText = L("Памяти впритык", "Memory is tight")
                    a.informativeText = L("Свободно \(Memory.gb(free)) ГБ, а \(m.name) нужно около \(Memory.gb(need)) ГБ. Нейронка всё равно запустится, но macOS будет выгружать другие программы на диск, и ждать можно несколько минут. Закрой тяжёлые программы и попробуй снова, или запускай так.",
                                          "\(Memory.gb(free)) GB free, and \(m.name) needs about \(Memory.gb(need)) GB. It will still start, but macOS will swap other apps to disk and it may take minutes. Close heavy apps and try again, or go ahead anyway.")
                    a.addButton(withTitle: L("Всё равно запустить", "Start anyway"))
                    a.addButton(withTitle: L("Отмена", "Cancel"))
                    if a.runModal() == .alertFirstButtonReturn {
                        self.transformNow(body, command: command, mode: mode, cold: cold, done: done)
                    } else {
                        self.lastFailure = L("мало свободной памяти, запуск отменён",
                                             "not enough free memory, start cancelled")
                        done(nil)
                    }
                }
                return
            }
        }
        transformNow(body, command: command, mode: mode, cold: cold, done: done)
    }

    private func transformNow(_ body: String, command: String, mode: Mode, cold: Bool,
                              done: @escaping (String?) -> Void) {
        if usesServer {
            stopServer()   // a local model left from before only eats memory
            let action = Self.actionLabel(command)
            DispatchQueue.main.async { Toast.shared.showSticky(action) }
            lastFailure = nil
            chat(body: body, command: command, mode: mode) { out in
                DispatchQueue.main.async { Toast.shared.hide() }
                done(out)
            }
            return
        }
        ensureServer()
        scheduleIdleStop()
        let action = Self.actionLabel(command)
        DispatchQueue.main.async {
            Toast.shared.showSticky(cold ? L("Запускаю нейронку…", "Starting the brain…") : action)
        }
        let finish: (String?) -> Void = { out in
            DispatchQueue.main.async { Toast.shared.hide() }
            done(out)
        }
        // Холодный старт на слабом маке (8 ГБ, Qwen 2,5 ГБ) бывает и минуту:
        // ждём до полутора, показывая секунды, чтобы «висит» не казалось
        // «сломалось». Если сервер умер, не ждём вовсе.
        let started = Date()
        let deadline = started.addingTimeInterval(90)
        waitHealthy(until: deadline, tick: { [weak self] in
            guard cold else { return }
            let sec = Int(Date().timeIntervalSince(started))
            if sec >= 5, sec % 5 == 0 {
                DispatchQueue.main.async {
                    Toast.shared.showSticky(L("Запускаю нейронку… \(sec) с, память занята на \(Memory.usedPercent)%",
                                              "Starting the brain… \(sec)s, memory \(Memory.usedPercent)% used"))
                }
            }
            _ = self
        }) { [weak self] ok in
            guard ok else {
                if let s = self?.server, !s.isRunning {
                    self?.lastFailure = L("нейронка упала при запуске, подробности в \(Self.logPath)",
                                          "the brain crashed on start, details in \(Self.logPath)")
                } else if Date() >= deadline {
                    self?.lastFailure = L("нейронка не поднялась за полторы минуты",
                                          "the brain didn't come up within 90 seconds")
                }
                finish(nil); return
            }
            self?.lastFailure = nil
            if cold {
                DispatchQueue.main.async { Toast.shared.showSticky(action) }
            }
            self?.chat(body: body, command: command, mode: mode, done: finish)
        }
    }

    /// Сервер мог только-только подняться и ещё грузить модель с диска —
    /// ждём его «ok», спрашивая раз в полсекунды.
    private func waitHealthy(until deadline: Date, tick: @escaping () -> Void = {},
                             _ done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let s = self.server, !s.isRunning {
                done(false)                       // our server died (maybe the port is taken): never trust whoever answers
            } else if self.server != nil, let data, String(data: data, encoding: .utf8)?.contains("ok") == true {
                done(true)
            } else if Date() < deadline {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    tick()
                    self.waitHealthy(until: deadline, tick: tick, done)
                }
            } else {
                done(false)
            }
        }.resume()
    }

    /// Если модель всё же подумала вслух, оставляем только ответ.
    static func stripThinking(_ s: String) -> String {
        guard let close = s.range(of: "</think>") else { return s }
        return String(s[close.upperBound...])
    }

    private func chat(body: String, command: String, mode: Mode, done: @escaping (String?) -> Void) {
        // Команда уходит в системную инструкцию, а тексту — отдельное
        // сообщение целиком. Раньше команда подклеивалась к тексту строкой
        // «Команда: …», и нейронка иногда обрабатывала её как часть текста
        // (перевела на английский вместе с текстом — «Command: …»).
        let messages: [[String: String]] = [
            ["role": "system", "content": (mode == .selection ? Self.selectionPrompt : Self.systemPrompt)
                + "\n\nКоманда пользователя к тексту: \(command)."],
            ["role": "user", "content": body],
        ]
        if usesServer {
            chatServer(messages: messages, lean: false, done: done)
            return
        }
        let payload: [String: Any] = ["messages": messages,
                                      "temperature": 0.3, "max_tokens": 2048,
                                      // Qwen3 без «Instruct» умеет думать вслух блоком <think>:
                                      // для правки текста это лишнее и долго
                                      "chat_template_kwargs": ["enable_thinking": false]]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/v1/chat/completions")!)
        req.setValue("Bearer \(serverKey)", forHTTPHeaderField: "Authorization")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 60
        URLSession.shared.dataTask(with: req) { data, _, error in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  case let text = Self.stripThinking(msg["content"] as? String ?? "")
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else {
                NSLog("Гига мозг: не ответил — \(error?.localizedDescription ?? "пустой ответ")")
                self.lastFailure = L("нейронка не ответила", "the brain didn't answer")
                done(nil)
                return
            }
            done(text)
        }.resume()
    }

    /// The same request to the user's server. Some APIs reject parameters they do not know
    /// (temperature on reasoning models, reasoning_effort elsewhere) with 400: then we retry
    /// once with the bare minimum, model and messages.
    /// Servers that rejected the extra parameters once; for them we go lean right away (per address and model).
    private static var leanServers = Set<String>()
    private static let leanLock = NSLock()

    private func chatServer(messages: [[String: String]], lean requested: Bool, done: @escaping (String?) -> Void) {
        let serverId = BrainServer.baseURL + "|" + BrainServer.model
        Self.leanLock.lock()
        let lean = requested || Self.leanServers.contains(serverId)
        Self.leanLock.unlock()
        guard let url = BrainServer.completionsURL(BrainServer.baseURL) else {
            lastFailure = L("не задан адрес сервера", "no server address")
            done(nil); return
        }
        var payload: [String: Any] = ["model": BrainServer.model, "messages": messages]
        if !lean {
            payload["temperature"] = 0.3
            payload["reasoning_effort"] = "none"
        }
        var req = BrainServer.request(url, key: BrainServer.apiKey)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 60
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 400 || code == 422, !lean {
                NSLog("Giga brain: server rejected extra parameters, retrying lean")
                Self.leanLock.lock(); Self.leanServers.insert(serverId); Self.leanLock.unlock()
                self.chatServer(messages: messages, lean: true, done: done)
                return
            }
            guard code == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  case let text = Self.stripThinking(msg["content"] as? String ?? "")
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else {
                NSLog("Giga brain: server failed, code \(code), \(error?.localizedDescription ?? "no text")")
                let reason = code == 200
                    ? L("сервер вернул пустой ответ", "the server returned an empty answer")
                    : BrainServer.describeFailure(code: code, body: data, error: error)
                self.lastFailure = reason
                done(nil)
                return
            }
            done(text)
        }.resume()
    }
}



// MARK: known cloud services

struct BrainProvider {
    let id: String
    let name: String
    let baseURL: String           // empty for "own server"
    let preferredModels: [String]
    let keysURL: String
    var isCustom: Bool { baseURL.isEmpty }
}

enum BrainProviders {
    static let deepseek = BrainProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1",
                                        preferredModels: ["deepseek-flash", "deepseek-chat"], keysURL: "https://platform.deepseek.com/api_keys")
    static let openrouter = BrainProvider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                                          preferredModels: ["deepseek/deepseek-chat-v3-0324", "deepseek/deepseek-chat", "google/gemini-2.5-flash", "openai/gpt-4.1-mini"],
                                          keysURL: "https://openrouter.ai/keys")
    static let openai = BrainProvider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
                                      preferredModels: ["gpt-4.1-mini", "gpt-4o-mini"], keysURL: "https://platform.openai.com/api-keys")
    static let groq = BrainProvider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1",
                                    preferredModels: ["llama-3.3-70b-versatile"], keysURL: "https://console.groq.com/keys")
    static let gemini = BrainProvider(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                                      preferredModels: ["gemini-2.5-flash", "gemini-2.0-flash"], keysURL: "https://aistudio.google.com/apikey")
    static let anthropic = BrainProvider(id: "anthropic", name: "Anthropic (Claude)", baseURL: "https://api.anthropic.com/v1",
                                         preferredModels: ["claude-haiku-4-5"], keysURL: "https://console.anthropic.com/settings/keys")
    static let custom = BrainProvider(id: "custom", name: "", baseURL: "", preferredModels: [], keysURL: "")
    static let all = [deepseek, openrouter, openai, groq, gemini, anthropic, custom]

    static func title(_ p: BrainProvider) -> String {
        p.isCustom ? L("Свой сервер (LM Studio, Ollama…)", "Own Server (LM Studio, Ollama…)") : p.name
    }

    /// Guesses the service from the look of the key; nil when it could be anything.
    static func fromKey(_ raw: String) -> BrainProvider? {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("sk-or-") { return openrouter }
        if k.hasPrefix("sk-ant-") { return anthropic }
        if k.hasPrefix("gsk_") { return groq }
        if k.hasPrefix("AIza") { return gemini }
        if k.range(of: "^sk-[0-9a-f]{32}$", options: .regularExpression) != nil { return deepseek }
        // Plain "sk-" is used by several services; only OpenAI's long keys are a safe guess.
        if k.hasPrefix("sk-proj-") || k.hasPrefix("sk-svcacct-") || (k.hasPrefix("sk-") && k.count >= 45) { return openai }
        return nil
    }

    static func fromURL(_ raw: String) -> BrainProvider {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        if u.lowercased().hasSuffix("/chat/completions") { u.removeLast("/chat/completions".count) }
        return all.first { !$0.isCustom && $0.baseURL.caseInsensitiveCompare(u) == .orderedSame } ?? custom
    }

    /// Only chat models: no embeddings, speech, images and the like.
    static func chatModels(_ ids: [String]) -> [String] {
        let skip = "embed|whisper|tts|dall-e|moderation|image|audio|realtime|transcribe|search|guard|imagen|veo|aqa"
        var seen = Set<String>()
        return ids.filter { $0.range(of: skip, options: [.regularExpression, .caseInsensitive]) == nil }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func pickDefault(_ p: BrainProvider, _ models: [String]) -> String? {
        for want in p.preferredModels {
            if let hit = models.first(where: { $0.caseInsensitiveCompare(want) == .orderedSame })
                ?? models.first(where: { $0.localizedCaseInsensitiveContains(want) }) { return hit }
        }
        return models.first ?? p.preferredModels.first
    }
}

/// Runs on the main thread even while a modal dialog is up and even if the dialog itself was
/// opened from a main-queue block (which keeps DispatchQueue.main from draining until it returns).
func onMainInModal(_ f: @escaping () -> Void) {
    RunLoop.main.perform(inModes: [.common, .modalPanel], block: f)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}
