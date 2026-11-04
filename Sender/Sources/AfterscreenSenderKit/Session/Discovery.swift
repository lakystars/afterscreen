import Foundation
import AfterscreenCore

public struct DiscoveredReceiver: Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var model: String
    public var panel: String
    public var port: UInt16
    /// mDNS host name; re-resolved on connect, every link answering
    public var host: String
    /// From the Bonjour resolve, which answers on one interface only
    public var addresses: [String]
    /// The receiver's lasting identity; pairing keys follow it
    public var deviceID = ""
}

/// Bonjour browse + resolve for receivers; publishes on main queue
/// Browser reports a receiver once per answering interface
final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onChange: (([DiscoveredReceiver]) -> Void)?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolved: [String: DiscoveredReceiver] = [:]
    /// Failed resolves per listed service, for the retry backoff
    private var failures: [ObjectIdentifier: Int] = [:]
    /// One scheduled retry per service; a dropped token cancels it
    private var pending: [ObjectIdentifier: UUID] = [:]
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.schedule = schedule
    }

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: AfterscreenProtocol.bonjourType + ".", inDomain: "local.")
    }

    func stop() {
        browser.stop()
    }

    /// Resolves `name` again after a failed connection
    /// A fast restart moves the port without a browser event
    /// Stopped first: a resolve still running refuses another
    func refresh(_ name: String) {
        for service in services where service.name == name {
            service.stop()
            service.resolve(withTimeout: 5)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    /// A receiver leaves the list with its last interface
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let i = services.firstIndex(where: { $0 === service }) ?? services.firstIndex(where: { $0.name == service.name }) {
            forget(services[i])
            services.remove(at: i)
        }
        // Another interface still answers: resolve again, dropping the gone address
        // Stopped first, as in refresh
        if let remaining = services.first(where: { $0.name == service.name }) {
            remaining.stop()
            return remaining.resolve(withTimeout: 5)
        }
        resolved[service.name] = nil
        publish()
    }

    /// Listing cached past its receiver's quit: no answer
    /// Same name back later raises no browser event
    /// Retried while listed
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let id = ObjectIdentifier(sender)
        // In progress: the running resolve reports its own outcome
        let busy = errorDict[NetService.errorCode]?.intValue == NetService.ErrorCode.activityInProgress.rawValue
        guard !busy, pending[id] == nil, services.contains(where: { $0 === sender }) else { return }
        let failed = failures[id, default: 0]
        failures[id] = failed + 1
        let token = UUID()
        pending[id] = token
        schedule(Discovery.retryDelay(after: failed)) { [weak self, weak sender] in
            guard let self = self, let sender = sender, self.pending[id] == token else { return }
            self.pending[id] = nil
            sender.stop()
            sender.resolve(withTimeout: 5)
        }
    }

    /// 2 s, doubling to 15 s
    static func retryDelay(after failures: Int) -> TimeInterval {
        min(15, 2 * pow(2, Double(failures)))
    }

    private func forget(_ service: NetService) {
        failures[ObjectIdentifier(service)] = nil
        pending[ObjectIdentifier(service)] = nil
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let port = UInt16(exactly: sender.port), port > 0 else { return }
        forget(sender)
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        func text(_ key: String) -> String { txt[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let addresses = (sender.addresses ?? []).compactMap(Discovery.ip(from:))
        let receiver = DiscoveredReceiver(name: sender.name, model: text("model"), panel: text("panel"), port: port,
                                          host: sender.hostName ?? "", addresses: addresses, deviceID: text("id"))
        // Unchanged: a refresh would connect at once, past the backoff
        guard resolved[sender.name] != receiver else { return }
        resolved[sender.name] = receiver
        publish()
    }

    private func publish() {
        let list = resolved.values.sorted { $0.name < $1.name }
        onChange?(list)
    }

    private static func ip(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: host)
        }
    }
}
