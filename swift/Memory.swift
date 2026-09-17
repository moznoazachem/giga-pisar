// Сколько памяти свободно. Нужно Мозгу: нейронка целиком ложится в память,
// и если места нет, macOS выгружает чужое на диск, а «Запускаю нейронку…»
// висит минутами. Лучше сказать об этом до запуска.

import Foundation

enum Memory {
    /// Вся память мака, байт.
    static var total: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// Сколько можно занять без выгрузки на диск: свободное плюс то, что
    /// система отдаст сразу (неактивное и очищаемое), байт.
    static var available: UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count) + UInt64(stats.purgeable_count)
        return pages * page
    }

    /// Занято, в процентах от всей памяти.
    static var usedPercent: Int {
        guard total > 0 else { return 0 }
        let used = total > available ? total - available : 0
        return Int(used * 100 / total)
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824).replacingOccurrences(of: ".0", with: "")
    }
}
