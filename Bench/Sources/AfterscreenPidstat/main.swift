import Darwin
import Foundation

// Samples processes by name: CPU %, wakeups/s, physical footprint, lifetime peak footprint.
// Run: swift run -c release --package-path Bench AfterscreenPidstat <seconds> <process name>...

struct Sample {
    var cpuNs: UInt64
    var sysNs: UInt64
    var wakeups: UInt64
    var footprint: UInt64
    var peak: UInt64
}

func pids(named name: String) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 4096)
    let bytes = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    return buffer.prefix(Int(bytes)).filter { pid in
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: path)).lastPathComponent == name
    }
}

func sample(_ pid: pid_t) -> Sample? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return nil }
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let cpu = (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    return Sample(cpuNs: cpu, sysNs: info.ri_system_time * UInt64(timebase.numer) / UInt64(timebase.denom), wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
                  footprint: info.ri_phys_footprint, peak: info.ri_lifetime_max_phys_footprint)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let seconds = args.first.flatMap(Double.init), args.count > 1 else {
    print("usage: AfterscreenPidstat <seconds> <process name>...")
    exit(2)
}
let targets = args.dropFirst().compactMap { name in pids(named: name).first.map { (name, $0) } }
let before = targets.map { sample($0.1) }
let start = ProcessInfo.processInfo.systemUptime
Thread.sleep(forTimeInterval: seconds)
let elapsed = ProcessInfo.processInfo.systemUptime - start
for ((name, pid), first) in zip(targets, before) {
    guard let a = first, let b = sample(pid) else { print("\(name): gone"); continue }
    let cpu = Double(b.cpuNs - a.cpuNs) / 1e9 / elapsed * 100
    let sys = Double(b.sysNs - a.sysNs) / 1e9 / elapsed * 100
    let wakeups = Double(b.wakeups - a.wakeups) / elapsed
    print(String(format: "%@ (pid %d): CPU %.1f%% (sys %.1f%%)  wakeups %.0f/s  footprint %.0f MB  peak %.0f MB",
                 name, pid, cpu, sys, wakeups, Double(b.footprint) / 1_048_576, Double(b.peak) / 1_048_576))
}
