// Проверочная командная утилита для казахского ядра (CTC.swift + KazakhPunct.swift).
//
//   kktest запись.wav [ещё.wav ...]     → по строке текста на файл (со знаками)
//   kktest --raw запись.wav ...          → без пунктуации
//   kktest --punct слова.json            → только правила: [[слово, начало, конец], ...] → текст
//
// Модель ищется в PISAR_KK_MODEL_DIR или ~/.giga/model-kk.

import Foundation

var args = Array(CommandLine.arguments.dropFirst())
func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

if args.first == "--punct" {
    guard args.count == 2, let data = FileManager.default.contents(atPath: args[1]),
          let list = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
        fail("kktest --punct слова.json")
    }
    let words = list.compactMap { row -> TimedWord? in
        guard row.count == 3, let t = row[0] as? String,
              let s = (row[1] as? NSNumber)?.doubleValue, let e = (row[2] as? NSNumber)?.doubleValue else { return nil }
        return TimedWord(text: t, start: s, end: e)
    }
    print(KazakhPunct.punctuate(words))
    exit(0)
}

var punct = true
if args.first == "--raw" { punct = false; args.removeFirst() }
guard !args.isEmpty else { fail("kktest [--raw] запись.wav ...") }

let dir = ProcessInfo.processInfo.environment["PISAR_KK_MODEL_DIR"] ?? "\(NSHomeDirectory())/.giga/model-kk"
do {
    let t0 = Date()
    let r = try CTCRecognizer(modelDir: dir)
    r.punctuation = punct
    FileHandle.standardError.write("загрузка \(String(format: "%.2f", Date().timeIntervalSince(t0))) с\n".data(using: .utf8)!)
    for path in args {
        let (samples, rate) = try Audio.readWav(path)
        let t = Date()
        let text = try r.transcribe(samples: samples, rate: rate)
        FileHandle.standardError.write("\((path as NSString).lastPathComponent): \(String(format: "%.1f", Double(samples.count) / Double(rate))) с звука за \(String(format: "%.2f", Date().timeIntervalSince(t))) с\n".data(using: .utf8)!)
        print(text)
    }
} catch {
    fail("ошибка: \(error)")
}
