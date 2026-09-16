// Самообновление: скачать выпуск с GitHub, проверить, подменить себя,
// перезапуститься. Без нотаризации это законно, потому что обновление
// ставит не человек (скачанному из браузера Gatekeeper устроил бы допрос),
// а само приложение, которому уже доверяют: оно стоит и работает.
//
// Безопасность — три замка перед подменой:
//   1) подпись нового бандла цела (codesign --verify --deep --strict);
//   2) команда подписи (TeamIdentifier) та же, что у работающей копии, —
//      чужой архив, даже подсунутый на странице выпусков, не пройдёт;
//   3) bundle id совпадает — это точно Гига Писарь, а не что-то ещё.
// Подмена — после выхода приложения, маленьким шелл-скриптом: ждёт выхода,
// меняет бандл, запускает новый, прибирает за собой.
//
// Ход дела виден в строке меню: «↓ 43%» пока качается, потом «проверяю…» —
// report() дёргается на главной очереди при каждой смене надписи.

import AppKit

/// Качает файл и рассказывает, сколько уже скачано. Живёт, пока качает.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let onPercent: (Int) -> Void
    private let onDone: (URL?, String?) -> Void // (файл, причина беды)
    private var session: URLSession!
    private var lastPercent = -1

    init(onPercent: @escaping (Int) -> Void, onDone: @escaping (URL?, String?) -> Void) {
        self.onPercent = onPercent
        self.onDone = onDone
        super.init()
        // Зеркало, которое молчит полминуты, считаем мёртвым и идём к
        // следующему. Без этого зависший GitFlic держал обновление вечно,
        // а каждое новое «Обновить» молча глоталось.
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL) { session.downloadTask(with: url).resume() }

    /// Остановить и забыть. onDone после этого НЕ зовётся.
    func cancel() { session.invalidateAndCancel() }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Int(100 * totalBytesWritten / totalBytesExpectedToWrite)
        guard p != lastPercent else { return } // не чаще раза на процент
        lastPercent = p
        DispatchQueue.main.async { self.onPercent(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // временный файл живёт только внутри этого вызова — сразу забираем
        let keep = NSTemporaryDirectory() + "giga-update-dl.zip"
        try? FileManager.default.removeItem(atPath: keep)
        do {
            try FileManager.default.moveItem(atPath: location.path, toPath: keep)
            onDone(URL(fileURLWithPath: keep), nil)
        } catch {
            onDone(nil, L("не сохранилось: \(error.localizedDescription)",
                          "couldn't keep the download: \(error.localizedDescription)"))
        }
        s.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return } // это мы сами
            onDone(nil, L("не скачалось: \(error.localizedDescription)",
                          "download failed: \(error.localizedDescription)"))
            s.finishTasksAndInvalidate()
        }
    }
}

enum SelfUpdate {
    /// Что сейчас происходит; показывается в окне хода дела и в меню.
    enum Stage {
        case downloading(Int)   // проценты
        case verifying
    }

    private(set) static var inProgress = false
    /// Версия, которая сейчас ставится (пока inProgress).
    private(set) static var version: String?
    private static var downloader: Downloader? // держим, пока качает

    /// Остановить скачивание. После проверки подписи отменять уже нечего:
    /// подмена ждёт только нашего выхода.
    static func cancel() {
        downloader?.cancel()
        downloader = nil
        inProgress = false
        version = nil
    }

    /// Команда подписи бандла («CXX972W555») или nil, если подписи нет.
    static func teamID(of path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dvv", path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let v = String(line.dropFirst("TeamIdentifier=".count))
            return v == "not set" ? nil : v
        }
        return nil
    }

    /// Подпись бандла цела и ничего внутри не подменено?
    static func signatureIntact(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--verify", "--deep", "--strict", path]
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Качает zip выпуска (пробуя зеркала по очереди), проверяет
    /// и подменяет работающее приложение.
    /// report(надпись) — что показать человеку; fail(причина) — беда;
    /// оба зовутся на главной очереди, при беде НИЧЕГО не тронуто.
    static func run(zips: [URL], version: String,
                    report: @escaping (Stage) -> Void,
                    ready: @escaping () -> Void,
                    fail: @escaping (String) -> Void) {
        guard !inProgress else { return }
        guard !zips.isEmpty else {
            fail(L("у выпуска нет файла", "the release has no file")); return
        }
        inProgress = true
        Self.version = version
        func bail(_ m: String) {
            DispatchQueue.main.async { inProgress = false; Self.version = nil; downloader = nil; fail(m) }
        }

        let dest = Bundle.main.bundlePath
        let fm = FileManager.default
        guard dest.hasSuffix(".app"),
              fm.isWritableFile(atPath: dest),
              fm.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent)
        else {
            bail(L("нет прав заменить \(dest)", "no permission to replace \(dest)"))
            return
        }

        download(zips, at: 0, version: version, dest: dest,
                 report: report, ready: ready, bail: bail)
    }

    /// Пробует зеркала по очереди: сорвалось с одного — тихо идём к следующему.
    private static func download(_ zips: [URL], at i: Int, version: String, dest: String,
                                 report: @escaping (Stage) -> Void,
                                 ready: @escaping () -> Void,
                                 bail: @escaping (String) -> Void) {
        guard i < zips.count else {
            bail(L("не скачалось ни с одного зеркала", "download failed on every mirror"))
            return
        }
        downloader = Downloader(
            onPercent: { p in report(.downloading(p)) },
            onDone: { file, error in
                downloader = nil
                guard let file else {
                    NSLog("Гига Писарь: зеркало \(zips[i].host ?? "?") — \(error ?? "?")")
                    download(zips, at: i + 1, version: version, dest: dest,
                             report: report, ready: ready, bail: bail)
                    return
                }
                DispatchQueue.main.async { report(.verifying) }
                DispatchQueue.global(qos: .userInitiated).async {
                    install(zipFile: file, version: version, dest: dest, ready: ready, bail: bail)
                }
            })
        downloader?.download(zips[i])
    }

    /// Распаковка, три замка, подмена. Зовётся с фоновой очереди.
    private static func install(zipFile: URL, version: String, dest: String,
                                ready: @escaping () -> Void, bail: (String) -> Void) {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "giga-update-\(version)"
        try? fm.removeItem(atPath: dir)
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try fm.moveItem(atPath: zipFile.path, toPath: dir + "/update.zip")
        } catch {
            bail(L("не сохранилось во временную папку", "couldn't save to a temp folder"))
            return
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", dir + "/update.zip", dir]
        do { try unzip.run(); unzip.waitUntilExit() } catch {
            bail(L("архив не распаковался", "couldn't unpack the archive")); return
        }
        guard unzip.terminationStatus == 0,
              let name = (try? fm.contentsOfDirectory(atPath: dir))?
                  .first(where: { $0.hasSuffix(".app") })
        else {
            bail(L("в архиве не нашлось приложения", "no app inside the archive")); return
        }
        let newApp = dir + "/" + name

        // три замка
        guard signatureIntact(newApp) else {
            bail(L("подпись обновления повреждена", "the update's signature is broken")); return
        }
        // Наша официальная команда подписи (Developer ID, сертификат 2026
        // года). Обновление принимается, если подписано ЛИБО той же командой,
        // что работающая копия, ЛИБО официальной — это пропускает переход
        // со старой самодельной подписи на нотаризованную.
        let officialTeam = "CQD93BKAH3"
        guard let newTeam = teamID(of: newApp),
              newTeam == teamID(of: dest) || newTeam == officialTeam else {
            bail(L("обновление подписано не нами", "the update is signed by someone else")); return
        }
        guard Bundle(path: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            bail(L("в архиве не Гига Писарь", "the archive isn't Giga Pisar")); return
        }

        // подмена после нашего выхода
        let script = dir + "/swap.sh"
        // Модель распознавания может жить внутри старого бандла (толстые
        // выпуски кладут её в Resources/model). Если новый выпуск худой,
        // модель нельзя терять вместе со старым бандлом — спасаем её
        // в ~/.giga/model, где приложение тоже умеет искать. В сам новый
        // бандл не кладём: это сломало бы его подпись.
        let sh = """
        #!/bin/sh
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.3; done
        if [ ! -d "\(newApp)/Contents/Resources/model" ] \\
           && [ -d "\(dest)/Contents/Resources/model" ] \\
           && [ ! -d "$HOME/.giga/model" ]; then
            /bin/mkdir -p "$HOME/.giga"
            /usr/bin/ditto "\(dest)/Contents/Resources/model" "$HOME/.giga/model"
        fi
        /bin/rm -rf "\(dest)"
        /usr/bin/ditto "\(newApp)" "\(dest)"
        /usr/bin/open "\(dest)"
        /bin/rm -rf "\(dir)"
        """
        do {
            try sh.write(toFile: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script]
            try p.run() // НЕ ждём: он ждёт нас
        } catch {
            bail(L("не запустился установщик", "the installer didn't start")); return
        }
        // Всё готово и проверено. Когда выходить — решает приложение:
        // если человек прямо сейчас диктует, оно дождётся конца.
        DispatchQueue.main.async { ready() }
    }
}
