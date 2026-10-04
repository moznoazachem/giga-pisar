// Запись с микрофона — по-висперному.
//
// Раньше мы просили у устройства сразу 16 кГц/16 бит (AVAudioRecorder
// с жёсткими настройками), и частоту на лету пересчитывал драйвер.
// Настоящие драйверы с этим справляются, а виртуальные (Parallels, VMware,
// UTM) на таком запросе теряют куски звука — диктовка приходила с дырками.
//
// Теперь берём звук в РОДНОМ формате устройства (драйверу — самая простая
// работа «отдай как есть»), а в 16 кГц для модели пересчитываем сами,
// штатным AVAudioConverter. Так пишут MacWhisper и остальные серьёзные
// диктовалки. Бонус: движок держим готовым между записями — старт быстрее,
// и начало фразы не съедается.

import AVFoundation

final class Mic {
    /// Движок живёт между записями: повторный старт заметно быстрее первого.
    /// Микрофон между записями НЕ открыт (оранжевой точки нет) — устройство
    /// включается только на время start()…stop().
    private var engine: AVAudioEngine?
    private var configurationChanged = false
    private var chunks: [[Float]] = []   // куски записи в родной частоте, моно
    private var nativeRate: Double = 0
    private let lock = NSLock()
    private(set) var isRecording = false
    private let audioQueue = DispatchQueue(label: "ru.panda.giga.audio")
    private var stopping = false // main queue
    private var pendingStart: ((Error?) -> Void)? // at most one held press
    private var engineActive = false // audioQueue only
    private let startOverride: (() throws -> Void)?
    private let stopOverride: (() -> [Float])?

    /// Громкость для волны, 0…1. Считается в звуковом потоке, читается
    /// из главного — живёт под тем же локом, что и куски записи.
    ///
    /// Это ПИКОВЫЙ измеритель с удержанием: между двумя взглядами волны
    /// микрофон может прислать и три куска, и ни одного, и всплеск голоса
    /// не должен пропасть ни в том, ни в другом случае. Поэтому куски
    /// копят максимум, а взгляд его забирает и обнуляет копилку.
    private var levelPeak: Float = 0
    private var levelSeen = false
    private var levelHeld: Float = 0

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        guard levelSeen else { return levelHeld } // куска ещё не было — держим прошлое
        levelSeen = false
        levelHeld = levelPeak
        levelPeak = 0
        return levelHeld
    }

    /// Тишина и полный голос в дБ относительно максимума. Ниже пола
    /// столбики лежат, выше потолка стоят во весь рост. Меряем пики
    /// по 10 мс, а не среднее по всему куску, поэтому и края взяты
    /// по-пиковому: тихая комната живёт около −55 дБ, обычная речь
    /// даёт пики от −35 до −12.
    private static let dbFloor: Float = -50
    private static let dbCeil: Float = -15

    /// Кривая громкости. Ухо слышет тихое лучше, чем показывает линейка:
    /// без поджатия обычная речь болталась бы в нижней трети столбика,
    /// и волна казалась вялой. 0.6 поднимает середину, не трогая края.
    private static let curve: Float = 0.6

    // Injection exercises the real lifecycle without opening a microphone.
    init(startEngine: (() throws -> Void)? = nil, stopEngine: (() -> [Float])? = nil) {
        startOverride = startEngine; stopOverride = stopEngine
        // Сменился микрофон или его формат (воткнули наушники, виртуалка
        // передёрнула устройство) — старый движок больше не годится,
        // следующая запись соберёт себе новый.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.audioQueue.async {
                if self.engineActive { self.configurationChanged = true }
                else { self.engine = nil }
            }
        }
    }

    /// Запускает запись. Бросает, если устройство не завелось, — тогда
    /// звука точно нет и надо честно сказать об этом человеку.
    func start(_ done: @escaping (Error?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRecording else {
            done(OrtError.failed("микрофон уже запущен")); return
        }
        if stopping { isRecording = true; pendingStart = done; return }
        isRecording = true
        audioQueue.async {
            var error: Error?
            do {
                if let start = self.startOverride { try start() }
                else { try self.startEngine() }
            } catch let failure { error = failure }
            let failure = error
            DispatchQueue.main.async {
                if failure != nil, self.pendingStart == nil { self.isRecording = false }
                done(failure)
            }
        }
    }

    private func startEngine() throws {
        let e = engine ?? AVAudioEngine()
        let input = e.inputNode
        let fmt = input.inputFormat(forBus: 0) // родной формат устройства
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            engine = nil
            throw OrtError.failed("микрофон не отдал формат звука")
        }
        nativeRate = fmt.sampleRate
        lock.lock(); chunks = []; lock.unlock()

        input.removeTap(onBus: 0) // на случай хвоста от прошлого раза
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let self, let data = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }
            let channels = Int(buf.format.channelCount)
            var mono = [Float](repeating: 0, count: n)
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<n { mono[i] += p[i] }
            }
            if channels > 1 {
                let k = Float(channels)
                for i in 0..<n { mono[i] /= k }
            }
            // Громкость: не среднее по всему куску, а самое громкое
            // окно в 10 мс внутри него. Кусок в 4096 отсчётов — это ~85 мс;
            // среднее по такому сроку размазывает слоги в ровный гул,
            // и волна получается вялой, хотя голос живой.
            let window = max(1, Int(self.nativeRate / 100))
            var peak: Float = 0
            var i = 0
            while i < n {
                let edge = min(i + window, n)
                var sum: Float = 0
                for j in i..<edge { sum += mono[j] * mono[j] }
                peak = max(peak, sqrt(sum / Float(edge - i)))
                i = edge
            }
            let db = 20 * log10(max(peak, 1e-7))
            let norm = min(max((db - Self.dbFloor) / (Self.dbCeil - Self.dbFloor), 0), 1)
            let level = pow(norm, Self.curve)
            self.lock.lock()
            self.chunks.append(mono)
            self.levelPeak = max(self.levelPeak, level)
            self.levelSeen = true
            self.lock.unlock()
        }

        e.prepare()
        do {
            try e.start()
        } catch {
            input.removeTap(onBus: 0)
            engine = nil // сломанный движок не переиспользуем
            throw error
        }
        engine = e
        engineActive = true
    }

    /// Останавливает запись и отдаёт всё записанное: 16 кГц, моно.
    func stop(_ done: @escaping ([Float]?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRecording else { DispatchQueue.main.async { done(nil) }; return }
        isRecording = false
        if pendingStart != nil {
            pendingStart = nil; DispatchQueue.main.async { done(nil) }; return
        }
        stopping = true
        audioQueue.async {
            let samples = self.stopOverride?() ?? self.stopEngine()
            DispatchQueue.main.async {
                self.stopping = false
                if let pending = self.pendingStart {
                    self.pendingStart = nil; self.isRecording = false
                    self.start(pending)
                }
                done(samples)
            }
        }
    }

    private func stopEngine() -> [Float]? {
        guard engineActive, let e = engine else { return nil }
        e.inputNode.removeTap(onBus: 0)
        e.stop() // сам движок оставляем — следующий старт быстрее
        engineActive = false
        if configurationChanged {
            engine = nil
            configurationChanged = false
        }
        lock.lock()
        let recorded = chunks
        chunks = []
        levelPeak = 0; levelHeld = 0; levelSeen = false // микрофон закрыт — волне показывать нечего
        lock.unlock()
        let native = recorded.flatMap { $0 }
        return Self.resample(native, from: nativeRate, to: 16000)
    }

    /// Пересчёт частоты штатным конвертером Apple — тем же классом качества,
    /// что делает система, только у нас, а не в драйвере.
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard !x.isEmpty else { return [] }
        guard from != to else { return x }
        guard
            let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from,
                                      channels: 1, interleaved: false),
            let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to,
                                       channels: 1, interleaved: false),
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt,
                                         frameCapacity: AVAudioFrameCount(x.count)),
            let conv = AVAudioConverter(from: inFmt, to: outFmt)
        else { return [] }

        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer {
            inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count)
        }

        var out: [Float] = []
        out.reserveCapacity(Int(Double(x.count) * to / from) + 16)
        var fed = false
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 8192)
            else { break }
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { _, status in
                if fed {
                    status.pointee = .endOfStream
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return inBuf
            }
            if let err { NSLog("Гига Писарь: ресемплинг — \(err)"); break }
            if outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(
                    start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            }
            if st == .endOfStream || st == .error || outBuf.frameLength == 0 { break }
        }
        return out
    }
}
