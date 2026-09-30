// Казахское распознавание: GigaAM Multilingual (multilingual_ctc) в ONNX.
//
// Отличия от русского Recognizer (v3_e2e_rnnt):
//   • один граф вместо трёх: энкодер и CTC-голова вместе, на выходе log_probs [1, T, C];
//   • декодирование простое: самая вероятная буква на кадр, повторы и «пустышка» убираются;
//   • словарь — 70 символов в multilingual_ctc_vocab.json, «пустышка» — номер 70;
//   • пунктуации модель не знает, её ставит KazakhPunct по паузам между словами.
//
// Признаки звука те же, что у v3 (64 мела, окно 320, шаг 160), поэтому Features общий.
// Повторяет server/kk_core.py шаг в шаг — сверка в scripts/сверка-kk.py.

import Foundation

/// Язык диктовки. От него зависит, какая модель слушает.
enum SpeechLang: String {
    case ru     // русский (+ английские вкрапления): v3_e2e_rnnt, пунктуация от модели
    case kk     // казахский: multilingual_ctc, пунктуация по правилам

    static var current: SpeechLang {
        get { SpeechLang(rawValue: UserDefaults.standard.string(forKey: "speechLang") ?? "") ?? .ru }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "speechLang") }
    }

    /// По этому файлу узнаём, что модель на месте.
    var modelFile: String {
        switch self {
        case .ru: return "\(Recognizer.modelName).yaml"
        case .kk: return "\(CTCRecognizer.modelName).yaml"
        }
    }

    /// Папка в ~/.giga и внутри бандла.
    var folder: String { self == .ru ? "model" : "model-kk" }

    var downloadURL: URL {
        switch self {
        case .ru: return URL(string: "https://github.com/moznoazachem/giga-pisar-cli/releases/download/v1.0/gigaam-v3-onnx-int8.tar.gz")!
        // Архив собран scripts/export-kk.py; выложите его в релиз и поправьте ссылку.
        case .kk: return URL(string: "https://github.com/moznoazachem/giga-pisar/releases/download/kk-v1/gigaam-multilingual-ctc-onnx-int8.tar.gz")!
        }
    }

    var downloadMB: Int { self == .ru ? 204 : 244 }
}

/// Любой распознаватель: волна 16 кГц моно → готовый текст.
protocol SpeechRecognizer: AnyObject {
    func transcribe(samples: [Float], rate: Int) throws -> String
}

extension Recognizer: SpeechRecognizer {}

final class CTCRecognizer: SpeechRecognizer {
    static let modelName = "multilingual_ctc"
    static let maxChunk = 24.0          // предел одного прохода модели — 25 секунд

    private let session: OrtSession
    private let vocab: [String]
    private let features: Features
    private let cfg: ModelConfig
    let modelDir: String
    /// Ставить ли знаки. Без них — сырой поток строчных слов, как у модели.
    var punctuation = true

    var blankId: Int { vocab.count }

    init(modelDir: String, threads: Int = 0) throws {
        self.modelDir = modelDir

        var o: OpaquePointer?
        try ortCheck(ortApi.pointee.CreateSessionOptions(&o))
        guard let options = o else { throw OrtError.failed("не создались настройки сессии") }
        defer { ortApi.pointee.ReleaseSessionOptions(options) }
        let n = threads > 0 ? threads : min(8, ProcessInfo.processInfo.activeProcessorCount)
        try ortCheck(ortApi.pointee.SetIntraOpNumThreads(options, Int32(n)))
        try ortCheck(ortApi.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))

        cfg = ModelConfig.load("\(modelDir)/\(Self.modelName).yaml")
        features = Features(cfg.features)
        session = try OrtSession(path: "\(modelDir)/\(Self.modelName).onnx", options: options)

        let data = try Data(contentsOf: URL(fileURLWithPath: "\(modelDir)/\(Self.modelName)_vocab.json"))
        guard let list = try JSONSerialization.jsonObject(with: data) as? [String], !list.isEmpty else {
            throw OrtError.failed("не разобрал словарь: \(Self.modelName)_vocab.json")
        }
        vocab = list
    }

    func transcribe(samples: [Float], rate: Int) throws -> String {
        let w = try words(samples: samples, rate: rate)
        return punctuation ? KazakhPunct.punctuate(w) : w.map(\.text).joined(separator: " ")
    }

    /// Слова со временем для записи любой длины: длинная режется по паузам.
    func words(samples: [Float], rate: Int) throws -> [TimedWord] {
        guard rate == cfg.features.sampleRate else {
            throw OrtError.failed("нужен звук \(cfg.features.sampleRate) Гц, а пришёл \(rate)")
        }
        let total = Double(samples.count) / Double(rate)
        if total <= Self.maxChunk + 1 {
            return try words(wave: samples, offset: 0)
        }
        let bounds = Audio.chunkBounds(total: total,
                                       silences: Audio.silences(samples, rate: rate),
                                       maxChunk: Self.maxChunk)
        var out: [TimedWord] = []
        for (a, b) in bounds {
            let from = min(samples.count, Int(a * Double(rate)))
            let to = min(samples.count, Int(b * Double(rate)))
            if to > from {
                out += try words(wave: Array(samples[from..<to]), offset: a)
            }
        }
        return out
    }

    /// Одна волна (не длиннее предела модели) → слова, время от offset.
    func words(wave: [Float], offset: Double) throws -> [TimedWord] {
        let (feats, frames) = features.compute(wave)
        guard frames > 0 else { return [] }

        let out = try session.run([
            Tensor(floats: feats, shape: [1, Int64(cfg.features.nMels), Int64(frames)]),
            Tensor(ints: [Int64(features.outLen(wave.count))], shape: [1]),
        ])
        // log_probs [1, T, C] — буквы подряд по кадрам
        let lp = out[0].floats
        let T = Int(out[0].shape[1]), C = Int(out[0].shape[2])
        let n = min(Int(out[1].ints.first ?? Int64(T)), T)
        guard n > 0 else { return [] }
        let shift = Double(wave.count) / Double(cfg.features.sampleRate) / Double(n)  // секунд на кадр

        var result: [TimedWord] = []
        var chars = "", firstFrame = -1, lastFrame = -1
        func commit() {
            if !chars.isEmpty {
                result.append(TimedWord(text: chars,
                                        start: offset + Double(firstFrame) * shift,
                                        end: offset + Double(lastFrame + 1) * shift))
            }
            chars = ""; firstFrame = -1; lastFrame = -1
        }

        var prev = -1
        for t in 0..<n {
            var best = 0
            var bestValue = -Float.greatestFiniteMagnitude
            let row = t * C
            for c in 0..<C where lp[row + c] > bestValue { bestValue = lp[row + c]; best = c }
            if best != blankId && best != prev && best < vocab.count {
                let ch = vocab[best]
                if ch == " " {
                    commit()
                } else {
                    chars += ch
                    if firstFrame < 0 { firstFrame = t }
                    lastFrame = t
                }
            }
            prev = best
        }
        commit()
        return result
    }
}
