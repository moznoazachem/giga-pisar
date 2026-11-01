// swiftc -parse-as-library swift/BrainCheck.swift scripts/test-brain-check.swift -o /tmp/giga-brain-check
import Foundation

@main struct BrainCheckTests {
    static func main() {
        let take = "Привет, Саша, как у тебя дела с отчётом, успеешь ли ты к пятнице"
        // A fix keeps the words.
        precondition(!BrainCheck.looksLikeAnswer(to: take, result: "Привет, Саша! Как у тебя дела с отчётом? Успеешь ли ты к пятнице?"))
        // An answer to the question in the take does not.
        precondition(BrainCheck.looksLikeAnswer(to: take, result: "Да, конечно, всё будет готово в срок, не волнуйтесь."))
        precondition(BrainCheck.looksLikeAnswer(to: "Сколько будет дважды два, напиши мне ответ одним числом",
                                                result: "Четыре."))
        // Short takes are never judged: too few words to tell.
        precondition(!BrainCheck.looksLikeAnswer(to: "Как дела?", result: "Хорошо, спасибо!"))
        precondition(!BrainCheck.looksLikeAnswer(to: "", result: "Что-то"))
        // Word forms and ё/е do not count as different words.
        precondition(!BrainCheck.looksLikeAnswer(to: "Ещё раз проверь отчёт перед отправкой клиенту вечером",
                                                 result: "Еще раз проверь отчет перед отправкой клиенту вечером."))
        // Changed endings and a number for a word: the words are still there, so an edit.
        precondition(!BrainCheck.looksLikeAnswer(to: "Встреча завтра в десять утра в переговорной на третьем этаже",
                                                 result: "Встреча завтра в 10:00, переговорная, третий этаж."))
        print("PASS Brain answer instead of an edit is told from a fix")
    }
}
