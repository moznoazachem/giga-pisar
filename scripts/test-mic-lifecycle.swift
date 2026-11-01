import Foundation

// Standalone shim for the app's error type; no ORT/model or microphone used.
enum OrtError: Error { case failed(String) }

@main struct MicLifecycleTests {
    static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }
    static func main() {
        var started = false, stopped = false, beat = false, restarted = false
        let mic = Mic(startEngine: { Thread.sleep(forTimeInterval: 0.4) },
                      stopEngine: { Thread.sleep(forTimeInterval: 0.2); return [1, 2, 3] })
        mic.start { error in precondition(error == nil); started = true }
        precondition(mic.isRecording)
        // Release BEFORE the engine has started. Stop must run after start;
        // an old start completion must not re-enable recording.
        mic.stop { samples in precondition(samples == [1, 2, 3]); stopped = true }
        precondition(!mic.isRecording)
        mic.start { error in precondition(error == nil); restarted = true }
        precondition(mic.isRecording && !restarted)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { beat = true }
        spin(0.2)
        precondition(beat && !started && !stopped)
        spin(0.6)
        precondition(started && stopped && mic.isRecording)
        spin(0.4)
        precondition(restarted && mic.isRecording)
        mic.stop { _ in }
        spin(0.3)
        print("PASS slow start/stop: heartbeat, early release, admission, retry")

        mic.start { _ in }
        mic.stop { _ in }
        mic.start { _ in fatalError("released pending press started") }
        var returned = false
        mic.stop { samples in
            precondition(returned && samples == nil, "cancel completion must be async and distinct from silence")
        }
        returned = true
        spin(0.8)
        precondition(!mic.isRecording)
        print("PASS release cancels pending press while previous engine stops")

        let broken = Mic(startEngine: { throw OrtError.failed("synthetic") }, stopEngine: { [] })
        var failed = false
        broken.start { error in failed = error != nil }
        spin(0.1)
        precondition(failed && !broken.isRecording)
        failed = false
        broken.start { error in failed = error != nil }
        spin(0.1)
        precondition(failed && !broken.isRecording)
        print("PASS failed engine start does not latch recording or block retry")

        var attempts = 0, retried = false
        let retry = Mic(startEngine: {
            attempts += 1
            Thread.sleep(forTimeInterval: 0.1)
            if attempts == 1 { throw OrtError.failed("first start fails late") }
        }, stopEngine: { [] })
        retry.start { error in precondition(error != nil) }
        retry.stop { _ in }
        retry.start { error in precondition(error == nil); retried = true }
        spin(0.4)
        precondition(retried && retry.isRecording)
        retry.stop { _ in }
        spin(0.1)
        print("PASS old start error does not reset a newer pending held press")

        let left: [Float] = [1, 0, -1, 0.5], right: [Float] = [0, 0, 1, 0.5]
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                precondition(Mic.mixToMono([l.baseAddress!], frames: 4) == left)
                precondition(Mic.mixToMono([l.baseAddress!, r.baseAddress!], frames: 4) == [0.5, 0, 0, 0.5])
            }
        }
        print("PASS channels are averaged into mono")

        precondition(Mic.level(of: [Float](repeating: 0, count: 4800), rate: 48000) == 0)
        precondition(Mic.level(of: [Float](repeating: 1, count: 4800), rate: 48000) == 1)
        // A single loud 10 ms window counts, however quiet the rest is.
        let burst = [Float](repeating: 0, count: 4320) + [Float](repeating: 1, count: 480)
        precondition(Mic.level(of: burst, rate: 48000) == 1)
        print("PASS level follows the loudest 10 ms window")

        let tone44 = (0..<44100).map { Float(sin(Double($0) * 0.05)) }
        let tone48 = (0..<48000).map { Float(sin(Double($0) * 0.05)) }
        let joined = Mic.resample([(rate: 44100, samples: tone44), (rate: 48000, samples: tone48)], to: 16000)
        precondition(abs(joined.count - 32000) < 64, "two one-second segments give two seconds: \(joined.count)")
        precondition(Mic.resample([], to: 16000).isEmpty)
        print("PASS segments at different rates are resampled separately and joined")
    }
}
