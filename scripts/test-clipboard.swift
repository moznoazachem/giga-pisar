// swiftc -parse-as-library swift/Clipboard.swift scripts/test-clipboard.swift -o /tmp/test-clipboard
import AppKit

private final class SlowProvider: NSObject, NSPasteboardItemDataProvider {
    var delay: TimeInterval = 0.5
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        if type.rawValue == "org.giga.test.optional" { return }
        Thread.sleep(forTimeInterval: delay)
        item.setString("synthetic source", forType: type)
    }
}

@main struct ClipboardTests {
    static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }
    static func main() throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count == 3 {
            let board = NSPasteboard(name: .init(CommandLine.arguments[2]))
            board.clearContents()
            let item = NSPasteboardItem(), provider = SlowProvider()
            provider.delay = CommandLine.arguments[1] == "slow" ? 4 : 0.5
            item.setDataProvider(provider, forTypes: [.string, .init("org.giga.test.optional")])
            precondition(board.writeObjects([item]))
            let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in }
            FileHandle.standardOutput.write(Data([82]))
            withExtendedLifetime(provider) { spin(20) }
            timer.invalidate(); return
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = DictationClipboard(name: board.name)
        func seed(_ s: String) { board.clearContents(); precondition(board.setString(s, forType: .string)) }
        func value() -> String? { board.string(forType: .string) }

        seed("original")
        var readOnly: String?
        clipboard.readText { readOnly = $0 }
        spin(0.2)
        precondition(readOnly == "original" && value() == "original" && !clipboard.isBusy)
        print("PASS read-only text access shares queue and preserves clipboard")
        var pasted = false, failures = 0
        clipboard.paste("dictation", allowed: { true }, action: { _, done in
            precondition(value() == "dictation"); pasted = true; done(true)
        }, failed: { failures += 1 })
        spin(0.75)
        precondition(pasted && failures == 0 && value() == "original")
        print("PASS normal paste and exact restore")

        clipboard.paste("dictation", allowed: { true }, action: { _, done in
            seed("new user copy"); done(true)
        }, failed: { failures += 1 })
        spin(0.75)
        precondition(value() == "new user copy" && failures == 0)
        print("PASS newer user copy survives restore")
        var rejectedChangedPaste = false
        clipboard.paste("replacement", allowed: { true }, action: { isOurs, done in
            precondition(isOurs())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                seed("copy during undo")
                rejectedChangedPaste = !isOurs()
                done(false)
            }
        }, failed: { fatalError("snapshot failed") })
        spin(0.8)
        precondition(rejectedChangedPaste && value() == "copy during undo" && !clipboard.isBusy)
        seed("new user copy")
        print("PASS clipboard ownership detects change during asynchronous undo and preserves new copy")

        clipboard.paste("first", allowed: { true }, action: { _, done in done(true) }, failed: { failures += 1 })
        clipboard.paste("second", allowed: { true }, action: { _, _ in fatalError("overlap") }, failed: { failures += 1 })
        spin(0.75)
        precondition(failures == 1 && value() == "new user copy")
        clipboard.paste("wrong target", allowed: { false }, action: { _, _ in fatalError("stale") }, failed: { failures += 1 })
        spin(0.35)
        precondition(failures == 2 && value() == "new user copy")
        print("PASS overlapping and stale requests never write")

        var selected: DictationClipboard.Selection?
        clipboard.selection(allowed: { true }, copy: { seed("selected words") }, done: { selected = $0 })
        spin(0.4)
        precondition(selected == .text("selected words") && value() == "new user copy")
        print("PASS selection copy/restore")
        clipboard.selection(allowed: { true }, copy: {}, done: { selected = $0 })
        spin(1)
        precondition(selected == .noChange)
        clipboard.selection(allowed: { true }, copy: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { seed("late selection") }
        }, done: { selected = $0 })
        spin(0.8)
        precondition(selected == .text("late selection") && value() == "new user copy")
        print("PASS no selection differs from failure; delayed copy is captured and restored")

        var permissions = 0, rejected = false
        clipboard.paste("focus changed", allowed: { permissions += 1; return permissions == 1 },
                        action: { _, _ in fatalError("wrong target") }, failed: { rejected = true })
        spin(0.4)
        precondition(rejected && value() == "new user copy")
        print("PASS target changes after write: original restored, refusal reported")

        let healthy = Process(), healthyReady = Pipe()
        healthy.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        healthy.arguments = ["healthy", board.name.rawValue]; healthy.standardOutput = healthyReady
        try healthy.run()
        precondition(healthyReady.fileHandleForReading.readData(ofLength: 1) == Data([82]))
        var healthyPaste = false
        clipboard.paste("healthy paste", allowed: { true }, action: { _, done in healthyPaste = true; done(true) },
                        failed: { fatalError("healthy 500ms provider rejected") })
        spin(1.5)
        healthy.terminate(); healthy.waitUntilExit()
        precondition(healthyPaste && value() == "synthetic source")
        print("PASS healthy slow provider and unavailable optional format")

        let concealed = NSPasteboardItem(), second = NSPasteboardItem()
        concealed.setString("synthetic secret", forType: .string)
        concealed.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents(); precondition(board.writeObjects([concealed]))
        clipboard.paste("test", allowed: { true }, action: { _, done in done(true) }, failed: { fatalError("concealed snapshot") })
        spin(0.75); precondition(value() == nil)
        second.setString("second item", forType: .string)
        let first = NSPasteboardItem(); first.setString("first item", forType: .string)
        board.clearContents(); precondition(board.writeObjects([first, second]))
        clipboard.paste("test", allowed: { true }, action: { _, done in done(true) }, failed: { fatalError("multiple items") })
        spin(0.75)
        precondition(board.pasteboardItems?.map { $0.string(forType: .string) } == ["first item", "second item"])
        print("PASS concealed not restored; multiple item data preserved")

        for stopped in [false, true] {
            let child = Process(), ready = Pipe()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["slow", board.name.rawValue]; child.standardOutput = ready
            try child.run()
            precondition(ready.fileHandleForReading.readData(ofLength: 1) == Data([82]))
            if stopped { precondition(kill(child.processIdentifier, SIGSTOP) == 0) }
            let before = failures
            var heartbeat = false
            var unexpectedPaste = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { heartbeat = true }
            clipboard.paste("must not overwrite", allowed: { true }, action: { _, done in unexpectedPaste = true; done(false) }, failed: { failures += 1 })
            spin(3.2)
            let responsive = heartbeat && failures == before + 1
            if !stopped {
                for _ in 0..<10 {
                    clipboard.paste("retry", allowed: { true }, action: { _, _ in fatalError("queued retry") }, failed: { failures += 1 })
                }
                precondition(failures == before + 11)
            }
            // macOS may revoke a stopped provider's ownership. The clipboard
            // then really is empty; a NEW paste may legitimately succeed.
            if stopped { precondition(kill(child.processIdentifier, SIGKILL) == 0) }
            else { spin(1.2); child.terminate() }
            child.waitUntilExit()
            precondition(responsive && !unexpectedPaste)
            seed("copy after failure")
            spin(0.5)
            precondition(value() == "copy after failure")
            var recovered = false
            clipboard.paste("retry succeeds", allowed: { true }, action: { _, done in recovered = true; done(true) }, failed: { fatalError("no recovery") })
            spin(0.75)
            precondition(recovered && value() == "copy after failure")
            print("PASS provider", stopped ? "stopped/killed" : "slow", "heartbeat, timeout, no late overwrite")
        }

        seed("before selection")
        let selectionProvider = Process(), selectionReady = Pipe()
        selectionProvider.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        selectionProvider.arguments = ["slow", board.name.rawValue]; selectionProvider.standardOutput = selectionReady
        var selectionTimedOut = false, selectionCalls = 0
        clipboard.selection(allowed: { true }, copy: {
            try! selectionProvider.run()
            precondition(selectionReady.fileHandleForReading.readData(ofLength: 1) == Data([82]))
        }, done: { value in selectionCalls += 1; selectionTimedOut = value == .failed })
        spin(3.3)
        let responded = selectionTimedOut && selectionCalls == 1
        selectionProvider.terminate(); selectionProvider.waitUntilExit()
        spin(1.3)
        precondition(responded && selectionCalls == 1 && !clipboard.isBusy)
        print("PASS selection read deadline and single completion after late provider")
        print("All clipboard tests passed; only private synthetic pasteboard used")
    }
}
