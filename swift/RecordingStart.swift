import Foundation

/// Main-queue only. A released or superseded press must never start recording.
final class RecordingStart {
    private var pending: DispatchWorkItem?

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
}
