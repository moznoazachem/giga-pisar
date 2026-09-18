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

struct BrainModel {
    let id: String
    let name: String        // короткое имя для меню
    let details: String     // честное описание: вес, чей русский, какие маки
    let file: String
    let url: String
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
               legacyFiles: ["Qwen3-4B-Instruct-2507-Q4_K_M.gguf"],
               sizeText: L("1,9 ГБ", "1.9 GB"),
               minRAMGB: 8,
               icon: "qwen"),
] }

final class Brain: NSObject, URLSessionDownloadDelegate {
    static let shared = Brain()
    static let port: UInt16 = 8617

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
    /// Мозг готов: модель выбрана и лежит на диске.
    var ready: Bool { chosenModel.map { downloaded($0) } ?? false }

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

    // MARK: скачивание модели (с процентами и докачкой после обрывов)

    private(set) var downloadingId: String?
    private(set) var downloadPercent = 0
    private var dlSession: URLSession?
    private var dlTask: URLSessionDownloadTask?
    private var dlRetries = 0

    func startDownload(_ m: BrainModel) {
        cancelDownload()
        downloadingId = m.id
        downloadPercent = 0
        dlRetries = 0
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        dlSession = s
        dlTask = s.downloadTask(with: URL(string: m.url)!)
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
        let p = Int(100 * totalBytesWritten / totalBytesExpectedToWrite)
        guard p != downloadPercent else { return }
        downloadPercent = p
        DispatchQueue.main.async { self.onChange?() }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = downloadingId, let m = BRAIN_MODELS.first(where: { $0.id == id })
        else { return }
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
                       "-c", "4096", "-ngl", "99", "--no-webui"]
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
        let cold = server?.isRunning != true || serverModelId != chosenId
        // Перед холодным стартом смотрим, влезет ли модель в свободную
        // память. Не влезет — macOS начнёт выгружать чужое на диск, и старт
        // растянется на минуты. Лучше спросить заранее, чем молча висеть.
        if cold, let m = chosenModel {
            let need = memoryNeeded(m), free = Memory.available
            if free < need {
                DispatchQueue.main.async {
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
            if let data, String(data: data, encoding: .utf8)?.contains("ok") == true {
                done(true)
            } else if let s = self.server, !s.isRunning {
                done(false)                       // сервер умер — ждать нечего
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
        let payload: [String: Any] = ["messages": messages,
                                      "temperature": 0.3, "max_tokens": 2048,
                                      // Qwen3 без «Instruct» умеет думать вслух блоком <think>:
                                      // для правки текста это лишнее и долго
                                      "chat_template_kwargs": ["enable_thinking": false]]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/v1/chat/completions")!)
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
}
