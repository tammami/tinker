import Foundation

/// The process's resident set, in bytes, as the kernel reports it. Zero when the
/// kernel refuses to say, which a test should treat as "cannot measure" rather than as
/// a number.
///
/// Used by the streaming tests to prove that a result read slowly is not a result held
/// in memory (SPEC §4, §12.6).
public func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size)
}
