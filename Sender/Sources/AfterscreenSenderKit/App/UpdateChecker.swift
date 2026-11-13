import AfterscreenCore
import Foundation

/// A newer release, and which side it updates
public struct AvailableUpdate: Equatable {
    public var version: String
    public var page: URL
    public var mac: Bool
    public var receiver: Bool
}

/// GitHub's latest release, every 6 hours; no server of ours
/// The request carries no identity; GitHub sees the IP
final class UpdateChecker {
    static let repository = "lakystars/afterscreen"
    /// Main queue; the latest release's tag
    var onTag: ((String) -> Void)?
    private let session = URLSession(configuration: .ephemeral)
    private var timer: Timer?
    private var task: URLSessionDataTask?
    /// Failures retry every 30 min: offline at login, rate limit
    private var retry: DispatchWorkItem?

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        retry?.cancel()
        retry = nil
        task?.cancel()
        task = nil
    }

    private func check() {
        guard let url = URL(string: "https://api.github.com/repos/\(UpdateChecker.repository)/releases/latest") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Afterscreen/\(AppVersion.current ?? "dev")", forHTTPHeaderField: "User-Agent")
        task?.cancel()
        task = session.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let tag = ok ? data.flatMap(UpdateChecker.tag(from:)) : nil
            DispatchQueue.main.async {
                // Stopped meanwhile: a late answer shows nothing
                guard let self = self, self.timer != nil else { return }
                if let tag = tag {
                    self.onTag?(tag)
                    return
                }
                guard !ok, self.retry == nil else { return }
                let retry = DispatchWorkItem { [weak self] in
                    self?.retry = nil
                    self?.check()
                }
                self.retry = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 1800, execute: retry)
            }
        }
        task?.resume()
    }

    /// `tag_name` of a published release shaped like a version
    static func tag(from data: Data) -> String? {
        struct Release: Decodable {
            var tag_name: String
            var draft: Bool?
            var prerelease: Bool?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data), release.draft != true, release.prerelease != true,
              AppVersion.parts(release.tag_name) != nil else { return nil }
        return release.tag_name
    }

    /// Built here, not taken from the response
    static func page(for tag: String) -> URL? {
        URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")
    }

    /// `installed` nil: unknown, as in `swift run`
    /// `receiver` nil: none connected; "1.0.0" for one without a version
    static func update(tag: String, installed: String?, receiver: String?) -> AvailableUpdate? {
        guard let page = page(for: tag) else { return nil }
        let mac = installed.map { AppVersion.isNewer(tag, than: $0) } ?? false
        let peer = receiver.map { AppVersion.isNewer(tag, than: $0) } ?? false
        guard mac || peer else { return nil }
        return AvailableUpdate(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page, mac: mac, receiver: peer)
    }
}
