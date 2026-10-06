import Foundation

// swiftc swift/RecordingStart.swift scripts/test-recording-start.swift -o /tmp/giga-recording-test
// /tmp/giga-recording-test (also run with swiftc -O)

@main
struct RecordingStartTests {
    static func main() {
        for (key, right, left, family) in [(UInt16(54), UInt(0x10), UInt(0x08), UInt(0x100000)),
                                          (61, 0x40, 0x20, 0x080000), (62, 0x2000, 0x01, 0x040000)] {
            func edge(_ event: UInt16, _ flags: UInt, _ down: Bool) -> RecordingStart.Edge {
                RecordingStart.edge(hotkey: key, eventKey: event, flags: flags, isDown: down)
            }
            precondition(edge(key, right | left | family, false) == .press)
            precondition(edge(key, left | family, true) == .release)
            precondition(edge(56, family, true) == .none) // foreign synthetic event
            precondition(edge(key, family, false) == .press) // remote fallback
            precondition(edge(key, 0, true) == .release)
            precondition(edge(56, 0x20000, true) == .release) // missed key-up
            precondition(edge(56, right | family, false) == .none) // no foreign start
        }
        for down in [true, false] {
            precondition(RecordingStart.edge(hotkey: 63, eventKey: 56,
                                            flags: 0x820002, isDown: down) == .none)
        }
        precondition(RecordingStart.edge(hotkey: 63, eventKey: 63, flags: 0x800000, isDown: false) == .press)
        precondition(RecordingStart.edge(hotkey: 63, eventKey: 63, flags: 0, isDown: true) == .release)
        precondition(RecordingStart.edge(hotkey: 0, eventKey: 0, flags: UInt.max, isDown: false) == .none)

        let gate = RecordingStart()
        var starts = 0
        let released = gate.schedule { starts += 1 }
        gate.cancel()
        DispatchQueue.main.async(execute: released)
        let queued = gate.schedule { starts += 1000 }
        DispatchQueue.main.async(execute: queued)
        gate.cancel() // Release after enqueue, before main gets to execute it.
        let superseded = gate.schedule { starts += 100 }
        let current = gate.schedule { starts += 1 }
        // Simulate the old permission callback arriving after a new press.
        DispatchQueue.main.async(execute: superseded)
        DispatchQueue.main.async(execute: current)
        var finished = false
        DispatchQueue.main.async { finished = true }
        pump(until: { finished })
        precondition(starts == 1, "Released/superseded presses started recording")
        gate.cancel()
        gate.cancel() // idempotent; a later press remains usable
        let next = gate.schedule { starts += 1 }
        DispatchQueue.main.async(execute: next)
        finished = false
        DispatchQueue.main.async { finished = true }
        pump(until: { finished })
        precondition(starts == 2)
        precondition(gate.take == 0)
        precondition(gate.acceptTranscription("previous text"))
        let previousTake = gate.take
        for (samples, aborted) in [(1600, false), (16000, true), (0, false)] {
            precondition(!RecordingStart.shouldTranscribe(sampleCount: samples, aborted: aborted, minimumSamples: 6400))
            precondition(gate.take == previousTake, "Tap, shortcut or failed start superseded a result")
        }
        precondition(!gate.acceptTranscription(" \n "))
        precondition(gate.take == previousTake)
        precondition(RecordingStart.shouldTranscribe(sampleCount: 6400, aborted: false, minimumSamples: 6400))
        precondition(gate.acceptTranscription("new text"))
        precondition(gate.take == previousTake + 1)
        print("RecordingStart: modifier isolation, release, stale callback, recovery PASS")
    }

    static func pump(until finished: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !finished() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(finished(), "Main queue did not drain within 2 seconds")
    }
}
