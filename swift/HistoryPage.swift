// Раздел «История»: последние диктовки с их звуком. Зачем: надиктовал,
// отвлёкся, вернулся — распозналось криво, а что имелось в виду, уже не
// вспомнить. Здесь можно переслушать запись, прогнать текст через Мозг,
// если забыл сказать «Писарь, …», и скопировать. Всё живёт только в
// памяти, как и раньше (App.recoveredTakes).

import AVFoundation
import SwiftUI

/// Один проигрыватель на весь раздел: новая запись останавливает прежнюю.
final class DictationPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing: Int?
    private var player: AVAudioPlayer?

    func toggle(take: Int, audio: Data?) {
        let again = playing == take
        stop()
        guard !again, let audio, let p = try? AVAudioPlayer(data: audio) else { return }
        p.delegate = self
        p.play()
        player = p
        playing = take
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { if player === self.player { self.stop() } }
    }
}

struct HistoryPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var player: DictationPlayer
    @State private var open: Int?
    @State private var improving: Set<Int> = []
    /// Takes whose text does not fit in two lines: only they get «Show all».
    @State private var truncated: Set<Int> = []

    init(model: SettingsModel) {
        self.model = model
        self.player = model.player
    }

    var body: some View {
        let records = model.app.dictationHistory
        VStack(spacing: 18) {
            if !records.isEmpty {
                SettingsCard {
                    ForEach(Array(records.enumerated()), id: \.element.id) { i, record in
                        if i > 0 { Divider().padding(.leading, 16) }
                        row(record)
                    }
                }
            }
        }
        .onDisappear { player.stop() }
    }

    private func row(_ record: GigaApp.DictationRecord) -> some View {
        let expanded = open == record.take
        let text = record.versions.last ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            Text(when(record))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            if expanded {
                Text(text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                // Свёрнутый текст сверяем с полным по высоте: так видно,
                // влез ли он в две строки и нужна ли ссылка «Показать полностью».
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { clipped in
                        Text(text)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: clipped.size.width, alignment: .leading)
                            .hidden()
                            .background(GeometryReader { full in
                                Color.clear.preference(key: TextOverflow.self,
                                                       value: full.size.height > clipped.size.height + 1)
                            })
                    })
                    .onPreferenceChange(TextOverflow.self) { over in
                        if over { truncated.insert(record.take) } else { truncated.remove(record.take) }
                    }
            }
            if expanded || truncated.contains(record.take) {
                Button(expanded ? L("Свернуть ⌃", "Show less ⌃") : L("Показать полностью ⌄", "Show all ⌄")) {
                    open = expanded ? nil : record.take
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .focusable(false)
            }
            actions(record, text: text)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Сегодня только время, вчера — «вчера», раньше — дата.
    private func when(_ record: GigaApp.DictationRecord) -> String {
        let time = record.date.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(record.date) ? time
            : Calendar.current.isDateInYesterday(record.date) ? L("вчера, ", "yesterday, ") + time
            : record.date.formatted(.dateTime.day().month().hour().minute())
    }

    private func actions(_ record: GigaApp.DictationRecord, text: String) -> some View {
        let playing = player.playing == record.take
        let busy = improving.contains(record.take)
        let brain = Brain.shared.ready
        return HStack(spacing: 10) {
            Button {
                player.toggle(take: record.take, audio: model.app.dictationAudio(take: record.take))
            } label: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
            }
            .disabled(record.seconds == nil)
            .help(L("Послушать", "Listen"))
            .focusable(false)
            Button {
                improving.insert(record.take)
                model.app.improveDictation(take: record.take) { improving.remove(record.take) }
            } label: {
                if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "wand.and.stars") }
            }
            .disabled(!brain || busy)
            .help(L("Улучшить", "Improve"))
            .focusable(false)
            Button {
                model.app.copyDictation(text)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help(L("Копировать", "Copy"))
            .focusable(false)
            if let seconds = record.seconds {
                let n = Int(seconds.rounded())
                Text(String(format: "%d:%02d", n / 60, n % 60))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }
}

private struct TextOverflow: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
