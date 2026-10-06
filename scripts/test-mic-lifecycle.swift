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
    }
}
