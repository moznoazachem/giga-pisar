// Пунктуация по правилам для казахского текста из multilingual_ctc.
//
// Модель выдаёт поток строчных слов без знаков. Здесь по паузам между
// словами и по окончаниям расставляются точки, запятые, вопросы и заглавные.
//
// Казахский — язык SOV: сказуемое стоит в конце предложения. Поэтому точку
// на паузе ставим только после формы сказуемого, а запятую — на паузе после
// деепричастия или условной формы (граница придаточного).
//
// Повторяет server/kk_punct.py шаг в шаг: оба обязаны выдавать один текст
// (сверка — scripts/сверка-kk.py).

import Foundation

/// Слово со временем в секундах от начала записи.
struct TimedWord {
    var text: String
    var start: Double
    var end: Double
}

enum KazakhPunct {
    static let pause = 0.6          // пауза после сказуемого — конец предложения
    static let long = 1.5           // такая пауза — конец предложения почти при любом слове
    static let commaPause = 0.35    // пауза после деепричастия — запятая

    static let pred = ["ды", "ді", "ты", "ті", "мыз", "міз", "быз", "біз", "пыз", "піз", "сыз", "сіз",
                       "ңыз", "ңіз", "мын", "мін", "бын", "бін", "пын", "пін", "сың", "сің", "йды", "йді",
                       "йық", "йік", "йміз", "ймыз", "йін", "йын", "шы", "ші", "бар", "жоқ", "емес", "екен",
                       "керек", "мүмкін", "тұр", "отыр", "жатыр", "ған", "ген", "қан", "кен", "дық", "дік",
                       "тық", "тік", "лық", "лік"]
    static let predWords: Set<String> = ["бар", "жоқ", "емес", "екен", "еді"]
    static let notPred = ["ларды", "лерді", "дарды", "дерді", "тарды", "терді", "дағы", "дегі", "тағы", "тегі"]
    static let clause = ["са", "се", "сақ", "сек", "саң", "сең", "саңыз", "сеңіз", "сам", "сем", "ып", "іп",
                         "ғанда", "генде", "қанда", "кенде", "ғандықтан", "гендіктен", "ғанмен", "генмен",
                         "майынша", "мейінше", "йынша", "йінше"]
    static let question: Set<String> = ["ма", "ме", "ба", "бе", "па", "пе"]
    static let commaBefore: Set<String> = ["бірақ", "алайда", "себебі", "өйткені", "яғни", "әйтпесе", "сондықтан"]
    /// С них начинается новое предложение: после сказуемого — точка даже без паузы.
    static let starters: Set<String> = ["келесі", "біріншіден", "екіншіден", "үшіншіден", "төртіншіден", "сонымен",
                                        "сондықтан", "ал", "енді", "демек", "сол", "осылайша"]
    /// На них предложение не кончается: пауза после них — запинка.
    static let noEnd: Set<String> = ["біз", "бір", "сол", "ол", "осы", "бұл", "және", "мен", "немесе", "яғни",
                                     "ал", "мысалы", "оның", "біздің", "сіздер", "енді", "де", "да", "те", "та", "ең", "әр"]

    private static func endsWith(_ w: String, _ list: [String]) -> Bool {
        list.contains { w.hasSuffix($0) }
    }

    /// Похоже ли слово на сказуемое (конец предложения).
    static func isPred(_ w: String) -> Bool {
        if predWords.contains(w) { return true }
        return w.count > 3 && endsWith(w, pred) && !endsWith(w, notPred)
    }

    private static func cap(_ w: String) -> String {
        guard let first = w.first else { return w }
        return String(first).uppercased() + w.dropFirst()
    }

    /// Слова по порядку → текст со знаками.
    static func punctuate(_ words: [TimedWord], pause: Double = KazakhPunct.pause) -> String {
        var sentences: [([String], String)] = []
        var cur: [String] = []
        var prevEnd = 0.0
        for w in words {
            if let prev = cur.last {
                let gap = w.start - prevEnd
                if question.contains(prev) && gap >= commaPause {
                    sentences.append((cur, "?"))
                    cur = []
                } else if (gap >= long && !noEnd.contains(prev))
                            || (gap >= pause && isPred(prev))
                            || (starters.contains(w.text) && isPred(prev) && !noEnd.contains(prev)) {
                    sentences.append((cur, "."))
                    cur = []
                } else if gap >= commaPause && endsWith(prev, clause) && !commaBefore.contains(w.text) {
                    cur[cur.count - 1] = prev + ","
                }
            }
            cur.append(w.text)
            prevEnd = w.end
        }
        if !cur.isEmpty { sentences.append((cur, ".")) }
        return sentences.map { sentence($0.0, $0.1) }.joined(separator: " ")
    }

    private static func sentence(_ ws: [String], _ mark: String) -> String {
        var out: [String] = []
        for w in ws {
            if !out.isEmpty && commaBefore.contains(w) && !out[out.count - 1].hasSuffix(",") {
                out[out.count - 1] += ","
            }
            out.append(w)
        }
        // вопросительная частица посреди предложения: «сәлеметсіздер ме? құрметті…»
        if out.count > 1 {
            for k in 0..<(out.count - 1) where question.contains(out[k]) { out[k] += "?" }
            for k in 1..<out.count where out[k - 1].hasSuffix("?") { out[k] = cap(out[k]) }
        }
        var text = out.joined(separator: " ")
        while text.hasSuffix(",") { text.removeLast() }
        return cap(text) + mark
    }
}
