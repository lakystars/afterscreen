import AppKit
import Combine
import CoreGraphics
import AfterscreenCore

/// UI state for the menu bar popover
public final class AppModel: ObservableObject {
    @Published public var receivers: [DiscoveredReceiver] = []
    @Published public var snapshot = SenderSnapshot()
    @Published public var activeReceiver: String?
    @Published public var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published public var lastMessage: String?

    private var session: SenderSession?
    private let discovery = Discovery()

    public init() {
        discovery.onChange = { [weak self] list in self?.receivers = list }
        discovery.start()
    }

    public var isActive: Bool { session != nil }

    public func connect(_ receiver: DiscoveredReceiver) {
        guard session == nil else { return }
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        guard screenRecordingGranted else {
            CGRequestScreenCaptureAccess()
            lastMessage = "Allow Screen Recording for Afterscreen, then connect again"
            return
        }
        let session = SenderSession(target: receiver)
        session.onUpdate = { [weak self] s in self?.snapshot = s }
        session.onEnd = { [weak self] reason in
            self?.session = nil
            self?.activeReceiver = nil
            self?.lastMessage = reason
        }
        self.session = session
        activeReceiver = receiver.name
        lastMessage = nil
        session.start()
    }

    public func disconnect() {
        session?.stop()
    }

    public func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Status item text: link glyph, fps and throughput while streaming
    public var statusTitle: String {
        guard snapshot.isStreaming else { return "▭" }
        return "▭ \(LinkLabel.glyph(snapshot.link)) \(Int(snapshot.sentFPS.rounded()))fps · \(Format.compactGbps(snapshot.throughputBitsPerSecond))"
    }
}
