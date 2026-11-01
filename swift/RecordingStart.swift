import Foundation

/// Main-queue only. A released or superseded press must never start recording.
final class RecordingStart {
    private var pending: DispatchWorkItem?
    private(set) var take = 0

    static func shouldTranscribe(sampleCount: Int, aborted: Bool, minimumSamples: Int) -> Bool {
        !aborted && sampleCount >= minimumSamples && sampleCount > 0
    }

    func acceptTranscription(_ text: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        take += 1
        return true
    }

    func schedule(_ start: @escaping () -> Void) -> DispatchWorkItem {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        let work = DispatchWorkItem(block: start)
        pending = work
        return work
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        pending?.cancel()
        pending = nil
    }

    // NX_DEVICE* masks from IOKit/hidsystem/IOLLEvent.h. Aggregate flags
    // cannot distinguish releasing right Command while left Command is held.
    enum Edge { case press, release, none }

    // Keep these key codes aligned with HOTKEYS in main.swift.
    static func edge(hotkey: UInt16, eventKey: UInt16, flags: UInt, isDown: Bool) -> Edge {
        let device, family: UInt
        switch hotkey {
        case 54: (device, family) = (0x10, 0x100000)
        case 61: (device, family) = (0x40, 0x080000)
        case 62: (device, family) = (0x2000, 0x040000)
        case 63: (device, family) = (0x800000, 0x800000)
        default: return .none
        }
        let own = eventKey == hotkey
        // Remote/synthetic events may carry only aggregate modifier flags.
        let down = flags & device != 0
            || (own && flags & 0x207F == 0 && flags & family != 0)
        if down, !isDown, own { return .press }
        if !down, isDown, own || flags & family == 0 { return .release }
        return .none
    }

    /// ⌘ ⌥ ⌃ ⇧ in NSEvent.ModifierFlags bits. fn is left out: F-keys and
    /// arrows carry it on their own, and a combination must not depend on it.
    static let modifierMask: UInt = 0x100000 | 0x080000 | 0x040000 | 0x020000

    /// A custom combination (#43): a regular key with modifiers, so key-down
    /// and key-up rather than flagsChanged. The press is the first key-down
    /// with exactly those modifiers; the release is that key's key-up however
    /// the modifiers are by then. Repeats and other keys are nothing.
    static func customEdge(code: UInt16, modifiers: UInt, eventCode: UInt16, eventFlags: UInt,
                           keyDown: Bool, isRepeat: Bool, isDown: Bool) -> Edge {
        guard eventCode == code else { return .none }
        if keyDown {
            guard !isRepeat, !isDown, eventFlags & modifierMask == modifiers & modifierMask else { return .none }
            return .press
        }
        return isDown ? .release : .none
    }
}
