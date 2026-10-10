import Darwin
import Foundation

/// Own CPU share since previous sample and physical footprint
public final class ProcessMetrics {
    private var lastCPU: Double
    private var lastWall: Double

    public init() {
        lastCPU = ProcessMetrics.cpuSeconds()
        lastWall = ProcessInfo.processInfo.systemUptime
    }

    /// CPU % can exceed 100 on multiple cores
    public func sample() -> (cpuPercent: Double, memoryBytes: UInt64) {
        let cpu = ProcessMetrics.cpuSeconds()
        let wall = ProcessInfo.processInfo.systemUptime
        let percent = wall > lastWall ? max(0, (cpu - lastCPU) / (wall - lastWall) * 100) : 0
        lastCPU = cpu
        lastWall = wall
        return (percent, ProcessMetrics.footprint())
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
