// App methods tested in-process, without applicationDidFinishLaunching, a model or microphone.
// Run: python3 scripts/test-history.py [screenshot-directory]
extension App {
    func seedHistoryScreenshot() {
        saveDictation("Пример диктовки: текст и звук остаются только в памяти Писаря.",
                      take: 55, audio: [Float](repeating: 0, count: 16000))
    }
    func checkHistory() {
        let samples = [Float](repeating: 0, count: 1600)
        precondition(!historyEnabled && !historyAudioEnabled)
        precondition(rememberDictations)
        for take in 1...25 { saveDictation("default \(take)", take: take, audio: samples) }
        precondition(dictationHistory.isEmpty && takeAudio.isEmpty && takeDates.isEmpty)
        precondition(recoveredTakes.count == 20 && recoveredTakes[25]?.last == "default 25")
        print("PASS fresh defaults: no History/audio, upstream recovery keeps 20")

        historyEnabled = true
        saveDictation("text only", take: 26, audio: samples)
        precondition(dictationHistory.count == 1 && dictationAudio(take: 26) == nil)
        precondition(dictationHistory[0].versions == ["text only"])
        print("PASS History ON / Audio OFF: new text only, no backfill")

        rememberDictations = false
        historyAudioEnabled = true
        for take in 27...51 { saveDictation("with audio \(take)", take: take, audio: samples) }
        precondition(dictationHistory.count == 20 && takeAudio.count == 20 && takeDates.count == 20)
        precondition(dictationHistory.first?.take == 51 && dictationHistory.last?.take == 32)
        precondition(recoveredTakes.count == 1 && recoveredTakes[51]?.last == "with audio 51")
        let wav = dictationAudio(take: 51)!
        precondition(wav.count == 44 + samples.count * 2)
        let decoded = try! AVAudioPlayer(data: wav)
        precondition(abs(decoded.duration - 0.1) < 0.001)
        let player = DictationPlayer()
        player.toggle(take: 51, audio: wav)
        precondition(player.playing == 51)
        player.stop()
        precondition(player.playing == nil)
        print("PASS both ON: playable WAV, cap 20; upstream Remember OFF still keeps one")

        saveDictation("improved text", take: 51)
        precondition(dictationHistory[0].versions == ["with audio 51", "improved text"])
        precondition(dictationAudio(take: 51) == wav)
        var completed = false
        improveDictation(take: 51) { completed = true }
        if usesBrainFixture {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            precondition(completed && dictationHistory[0].versions.last == "fixture: improved text")
            precondition(dictationAudio(take: 51) == wav)
            completed = false
            improveDictation(take: 51) { completed = true }
            historyEnabled = false
            historyEnabled = true
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            precondition(completed && dictationHistory.isEmpty)
            saveDictation("retained text", take: 51, audio: samples)
            print("PASS fixture Brain: explicit Improve appends version, keeps audio; disabled history is not resurrected by pending Improve")
        } else {
            precondition(!Brain.shared.ready)
            precondition(completed && dictationHistory[0].versions.last == "improved text")
            print("PASS versions preserve audio; Improve with Brain OFF completes without changing text")
        }

        historyAudioEnabled = false
        precondition(!dictationHistory.isEmpty && takeAudio.isEmpty)
        saveDictation("no audio again", take: 52, audio: samples)
        precondition(dictationAudio(take: 52) == nil)
        historyAudioEnabled = true
        saveDictation("audio again", take: 53, audio: samples)
        historyEnabled = false
        precondition(dictationHistory.isEmpty && takeAudio.isEmpty && takeDates.isEmpty)
        saveDictation("after off", take: 54, audio: samples)
        precondition(dictationHistory.isEmpty && takeAudio.isEmpty)
        precondition(recoveredTakes.count == 1 && recoveredTakes[54]?.last == "after off")
        copyLastDictation()
        let pasteboard = NSPasteboard(name: .init(Bundle.main.bundleIdentifier!))
        precondition(pasteboard.string(forType: .string) == "after off")
        pasteboard.releaseGlobally()
        historyEnabled = true
        precondition(dictationHistory.isEmpty)
        print("PASS disabling Audio releases audio; disabling History clears it and prevents new collection; Copy Last survives")
    }
}

let testDomain = Bundle.main.bundleIdentifier!
precondition(testDomain.hasPrefix("ru.panda.giga.history-test."))
UserDefaults.standard.removePersistentDomain(forName: testDomain)
defer { UserDefaults.standard.removePersistentDomain(forName: testDomain) }
_ = NSApplication.shared
let testedApp = App()
testedApp.checkHistory()

// Render the real History view without launching app lifecycle/services or touching /Applications.
if CommandLine.arguments.count > 1 {
    let directory = CommandLine.arguments[1]
    let model = SettingsModel(app: testedApp)
    func screenshot(_ name: String) {
        let view = NSHostingView(rootView: HistoryPage(model: model).padding(24)
            .frame(width: 680, height: 520, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
    }
    testedApp.historyEnabled = false
    testedApp.historyAudioEnabled = false
    screenshot("after-default-off")
    testedApp.historyEnabled = true
    testedApp.seedHistoryScreenshot()
    screenshot("after-text-only")
    testedApp.historyAudioEnabled = true
    testedApp.seedHistoryScreenshot()
    screenshot("after-both-on")
}
