import Foundation
import Network

/// Local network denial that Settings may show as allowed
enum LocalNetworkAccess {
    /// mDNS group: a local destination that needs no receiver
    static let multicast = "224.0.0.251"

    /// Path verdict toward `host`; no packet is sent
    /// `completion`: main queue; true when privacy denies the path
    static func isDenied(host: String, wait: TimeInterval = 1, completion: @escaping (Bool) -> Void) {
        let c = NWConnection(host: NWEndpoint.Host(host), port: 9, using: .udp)
        let queue = DispatchQueue(label: "afterscreen.localnetwork")
        var done = false
        let finish = { (denied: Bool) in
            guard !done else { return }
            done = true
            c.pathUpdateHandler = nil
            c.stateUpdateHandler = nil
            c.cancel()
            DispatchQueue.main.async { completion(denied) }
        }
        c.pathUpdateHandler = { path in
            if path.unsatisfiedReason == .localNetworkDenied { finish(true) }
        }
        c.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: finish(false)
            default: if c.currentPath?.unsatisfiedReason == .localNetworkDenied { finish(true) }
            }
        }
        c.start(queue: queue)
        // Offline or unanswered: not this denial
        queue.asyncAfter(deadline: .now() + wait) { finish(false) }
    }

    /// true if any of `hosts` is denied
    static func isDenied(hosts: [String], completion: @escaping (Bool) -> Void) {
        var left = hosts.count, denied = false
        guard left > 0 else { return DispatchQueue.main.async { completion(false) } }
        for host in hosts {
            isDenied(host: host) { result in
                denied = denied || result
                left -= 1
                if left == 0 { completion(denied) }
            }
        }
    }
}
