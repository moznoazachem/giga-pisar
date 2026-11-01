import Foundation

/// "Edit on the fly" sends every take to the Brain with "исправь". A take with a
/// question in it sometimes comes back answered instead of fixed (Windows #13),
/// and the person gets a reply where their own words should be. A fix keeps most
/// of the words; an answer keeps few of them.
enum BrainCheck {
    /// The share of the original words that must survive for the result to count as an edit.
    static let keptShare = 0.35

    static func looksLikeAnswer(to original: String, result: String) -> Bool {
        let before = words(original)
        guard before.count >= 4 else { return false } // too short to judge
        let kept = before.intersection(words(result)).count
        return Double(kept) / Double(before.count) < keptShare
    }

    /// Word stems, so that a fix that changes an ending ("третьем" → "третий")
    /// still counts as keeping the word: the first four letters of a word,
    /// whole words of three. Lowercase, ё and е the same.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
            .map { String($0.prefix(4)) })
    }
}
