// Cuts hesitation sounds out of a take: "э-э", "а-а", "м-м" and their spellings. Runs on the
// Mac, so it works with the Brain off and without a network. Words that are sometimes filler
// and sometimes meaning ("вот", "ну", "короче") are not touched: that is the Brain's job.
// Foundation only.

import Foundation

enum Hesitations {
    /// On by default, as on Android.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "dropHesitations") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dropHesitations") }
    }

    // A lone "а" is a conjunction and "мм" is millimetres, so those two stay. A sound in quotes
    // is somebody talking about the sound itself.
    private static let sound = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{N}«"„“-])"# +
        #"(?:[эЭ]+(?:-[эЭ]+)*[мМ]*|[аА]+(?:-[аА]+)+|[аА]{3,}|[мМ]+(?:-[мМ]+)+|[мМ]{3,})"# +
        #"(?![\p{L}\p{N}»"“”-])"#)

    private static let sentenceEnds = ".!?…"
    private static let afterSound = ",.!?…"

    static func removed(_ text: String) -> String {
        let source = text as NSString
        let matches = sound.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var at = 0
        var capitalize = false

        func push(_ chunk: String) {
            guard !chunk.isEmpty else { return }
            out += capitalize ? chunk.prefix(1).uppercased() + chunk.dropFirst() : chunk
            capitalize = false
        }
        // Nil only past the end; half of an emoji is no punctuation and reads as a plain symbol.
        func character(_ index: Int) -> Character? {
            guard index < source.length else { return nil }
            return Unicode.Scalar(source.character(at: index)).map(Character.init) ?? "\u{FFFD}"
        }

        for match in matches {
            let range = match.range
            if range.location < at { continue }
            push(source.substring(with: NSRange(location: at, length: range.location - at)))
            at = range.location + range.length
            var before = out
            while let last = before.last, last == " " || last == "\t" { before.removeLast() }
            let opensSentence = before.last.map { sentenceEnds.contains($0) || $0.isNewline } ?? true
            if opensSentence {
                // "А-а, просто сразу" -> "Просто сразу": the sound goes with its own punctuation.
                while let next = character(at), afterSound.contains(next) { at += 1 }
                while let next = character(at), next == " " || next == "\t" { at += 1 }
                if source.substring(with: range).first?.isUppercase == true { capitalize = true }
                continue
            }
            out = before
            let next = character(at)
            if out.last == "," {
                if next == "," {
                    // "сообщения, э-э, которые" -> "сообщения, которые": one comma is enough.
                    at += 1
                } else if next.map({ sentenceEnds.contains($0) }) ?? true {
                    // "завтра, э-э." -> "завтра."
                    out.removeLast()
                }
            }
        }
        push(source.substring(from: at))

        var cleaned = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.last == "," { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.contains(where: { $0.isLetter || $0.isNumber }) ? cleaned : ""
    }
}
