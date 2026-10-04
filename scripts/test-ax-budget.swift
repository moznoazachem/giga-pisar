import AppKit

let busyColor = NSColor.systemBlue // app-level constant; no UI is created
let BUSY_BAR: CGFloat = 0.35

@main struct AXBudgetTests {
    static func main() {
        let element = AXUIElementCreateApplication(getpid())
        precondition(matchesDictationFocus(nil, current: { fatalError("unknown original needs no query") }))
        precondition(!matchesDictationFocus(nil, strict: true, current: { nil }))
        precondition(matchesDictationFocus(element, current: { nil }))
        precondition(!matchesDictationFocus(element, strict: true, current: { nil }))
        precondition(!matchesDictationFocus(element, current: { AXUIElementCreateApplication(getppid()) }))
        precondition(matchesDictationFocus(element, current: { element }))
        AXBudget.enter()
        let outer = AXBudget.deadline
        AXBudget.enter()
        precondition(AXBudget.deadline == outer)
        AXBudget.leave()
        AXBudget.deadline = ProcessInfo.processInfo.systemUptime + 0.01
        var called = false
        precondition(AXBudget.call(element, { called = true; return .success }) == .cannotComplete)
        precondition(!called && AXBudget.retryAfter.isEmpty)
        precondition(AXBudget.sawCannotComplete)
        AXBudget.deadline = ProcessInfo.processInfo.systemUptime + 0.05
        _ = AXBudget.call(element) { .cannotComplete }
        precondition(AXBudget.retryAfter.isEmpty)
        AXBudget.deadline = ProcessInfo.processInfo.systemUptime + 0.2
        _ = AXBudget.call(element) { .cannotComplete }
        precondition(AXBudget.retryAfter.isEmpty, "instant rejection is not a timeout")
        _ = AXBudget.call(element) { Thread.sleep(forTimeInterval: 0.18); return .cannotComplete }
        precondition(AXBudget.retryAfter[getpid()] != nil)
        AXBudget.deadline = ProcessInfo.processInfo.systemUptime + 0.2
        let other = AXUIElementCreateApplication(getppid())
        _ = AXBudget.call(other) { called = true; return .success }
        precondition(called, "cooldown leaked to a different PID")
        AXBudget.leave()
        precondition(AXBudget.depth == 0)
        AXBudget.enter()
        precondition(!AXBudget.sawCannotComplete, "new top-level inspection must clear old failure")
        AXBudget.leave()
        print("PASS AX nested budget, short remainder, per-PID cooldown; no external AX query")
    }
}
