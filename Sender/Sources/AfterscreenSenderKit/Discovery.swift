import Foundation
import AfterscreenCore

public struct DiscoveredReceiver: Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var model: String
    public var panel: String
    public var port: UInt16
    public var addresses: [String]
}

/// Bonjour browse + resolve for receivers; publishes on the main queue
final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onChange: (([DiscoveredReceiver]) -> Void)?

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var resolved: [String: DiscoveredReceiver] = [:]

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: AfterscreenProtocol.bonjourType + ".", inDomain: "local.")
    }

    func stop() {
        browser.stop()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        resolved[service.name] = nil
        publish()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        func text(_ key: String) -> String { txt[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let addresses = (sender.addresses ?? []).compactMap(Discovery.ip(from:))
        resolved[sender.name] = DiscoveredReceiver(name: sender.name, model: text("model"), panel: text("panel"),
                                                   port: UInt16(sender.port), addresses: addresses)
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
