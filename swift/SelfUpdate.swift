// Самообновление: скачать выпуск с GitHub, проверить, подменить себя,
// перезапуститься. Без нотаризации это законно, потому что обновление
// ставит не человек (скачанному из браузера Gatekeeper устроил бы допрос),
// а само приложение, которому уже доверяют: оно стоит и работает.
//
// Security: before the swap, the new bundle must satisfy our designated
// requirement (Apple-issued Developer ID certificate of team CQD93BKAH3,
// bundle id ru.panda.giga, every nested file intact), checked with the
// Security framework, not by parsing codesign output: the team field there
// is written by the signer and can be forged on an ad-hoc signature.
// It must also be newer than the running copy, and come from our mirrors.
// Подмена — после выхода приложения, маленьким шелл-скриптом: ждёт выхода,
// меняет бандл, запускает новый, прибирает за собой.
//
// Ход дела виден в строке меню: «↓ 43%» пока качается, потом «проверяю…» —
// report() дёргается на главной очереди при каждой смене надписи.

import AppKit
import Security

/// Качает файл и рассказывает, сколько уже скачано. Живёт, пока качает.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let onPercent: (Int) -> Void
    private let onDone: (URL?, String?) -> Void // (файл, причина беды)
    /// Сколько байт уже пришло и сколько всего. Проценты для строки меню
    /// годятся, а окну знакомства нужны мегабайты.
    var onBytes: ((Int64, Int64) -> Void)?
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
        if let onBytes {
            DispatchQueue.main.async { onBytes(totalBytesWritten, totalBytesExpectedToWrite) }
        }
        let p = Int(100 * totalBytesWritten / totalBytesExpectedToWrite)
        guard p != lastPercent else { return } // не чаще раза на процент
        lastPercent = p
        DispatchQueue.main.async { self.onPercent(p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // временный файл живёт только внутри этого вызова — сразу забираем
        let keep = NSTemporaryDirectory() + "giga-dl-\(UUID().uuidString).zip"
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

    /// Our Developer ID: only Apple can issue a certificate that meets it.
    static let requirement =
        "identifier \"ru.panda.giga\" and anchor apple generic" +
        " and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */" +
        " and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */" +
        " and certificate leaf[subject.OU] = CQD93BKAH3"

    /// Hosts the update may come from.
    static let trustedHosts: Set<String> = ["github.com", "gitflic.ru"]

    /// The bundle is signed by us and nothing inside has been changed.
    static func isSignedByUs(_ path: String) -> Bool {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess,
              let req
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
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
        let zips = zips.filter { $0.scheme == "https" && trustedHosts.contains($0.host ?? "") }
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

        guard isSignedByUs(newApp) else {
            bail(L("обновление подписано не нами или повреждено", "the update isn't signed by us or is damaged")); return
        }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard let newVersion = Bundle(path: newApp)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              isNewerVersion(newVersion, than: current) else {
            bail(L("в архиве не новая версия", "the archive isn't a newer version")); return
        }

        // подмена после нашего выхода
        let script = dir + "/swap.sh"
        // Модель распознавания может жить внутри старого бандла (толстые
        // выпуски кладут её в Resources/model). Если новый выпуск худой,
        // модель нельзя терять вместе со старым бандлом — спасаем её
        // в ~/.giga/model, где приложение тоже умеет искать. В сам новый
        // бандл не кладём: это сломало бы его подпись.
        // Paths go in as arguments, never pasted into the script text.
        let sh = """
        #!/bin/sh
        NEW="$1"; DEST="$2"; DIR="$3"; PID="$4"
        while /bin/kill -0 "$PID" 2>/dev/null; do /bin/sleep 0.3; done
        if [ ! -d "$NEW/Contents/Resources/model" ] \\
           && [ -d "$DEST/Contents/Resources/model" ] \\
           && [ ! -d "$HOME/.giga/model" ]; then
            /bin/mkdir -p "$HOME/.giga"
            /usr/bin/ditto "$DEST/Contents/Resources/model" "$HOME/.giga/model"
        fi
        /bin/rm -rf "$DEST"
        /usr/bin/ditto "$NEW" "$DEST"
        /usr/bin/open "$DEST"
        /bin/rm -rf "$DIR"
        """
        do {
            try sh.write(toFile: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script, newApp, dest, dir, String(ProcessInfo.processInfo.processIdentifier)]
            try p.run() // НЕ ждём: он ждёт нас
        } catch {
            bail(L("не запустился установщик", "the installer didn't start")); return
        }
        // Всё готово и проверено. Когда выходить — решает приложение:
        // если человек прямо сейчас диктует, оно дождётся конца.
        DispatchQueue.main.async { ready() }
    }
}
