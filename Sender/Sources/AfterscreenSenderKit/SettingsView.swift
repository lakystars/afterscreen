import AppKit
import AfterscreenCore
import SwiftUI

/// Sender settings window content
public struct SettingsView: View {
    @ObservedObject var settings: SenderSettings
    var panelPoints: PixelSize

    public init(settings: SenderSettings, panelPoints: PixelSize) {
        self.settings = settings
        self.panelPoints = panelPoints
    }

    public var body: some View {
        Form {
            Section(L10n.t("Display", "디스플레이")) {
                Picker(L10n.t("Size", "크기"), selection: $settings.displaySize) {
                    ForEach(DisplaySize.allCases) { size in
                        let p = size.points(for: panelPoints)
                        Text(L10n.t("\(size.title)  ·  looks like \(p.width) × \(p.height)", "\(size.title)  ·  \(p.width) × \(p.height)처럼 보임")).tag(size)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(L10n.t("Applies while streaming. System Settings → Displays lists the same sizes.",
                            "스트리밍 중에도 바로 적용됩니다. 시스템 설정 → 디스플레이에도 같은 크기가 있습니다."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L10n.t("Transfer resolution", "전송 해상도"), selection: $settings.streamResolution) {
                    ForEach(StreamResolution.allCases) { Text($0.title).tag($0) }
                }
                Text(L10n.t("Automatic: the panel's resolution over cables, four fifths over Wi-Fi (5K iMac: 5120 × 2880 or 4096 × 2304). At four fifths the desktop switches to half that size, the sharpest there (5K iMac: looks like 2048 × 1152); over cables it returns to the size above.",
                            "자동: 케이블 연결은 패널 해상도, Wi-Fi는 4/5 해상도로 보냅니다(5K iMac: 5120 × 2880 또는 4096 × 2304). 4/5 해상도일 때는 화면 크기를 그 절반으로 바꿔 가장 선명하게 보여 줍니다(5K iMac: 2048 × 1152처럼 보임). 케이블로 연결하면 위에서 고른 크기로 돌아옵니다."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.t("Arrange Displays…", "디스플레이 배치…")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                }
            }
            Section(L10n.t("Connection", "연결")) {
                Toggle(L10n.t("Connect automatically", "자동으로 연결"), isOn: $settings.autoConnect)
                Text(settings.lastReceiver.map {
                    L10n.t("Connects to \($0) when it appears, after sleep, and after the link drops.",
                           "\($0)이(가) 보이면, 잠자기에서 깨어났을 때, 링크가 끊겼을 때 다시 연결합니다.")
                } ?? L10n.t("Connects to the receiver you last connected to.", "마지막으로 연결한 수신기에 연결합니다."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.t("Open at login", "로그인 시 열기"), isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
            Section(L10n.t("Menu bar", "메뉴 막대")) {
                Toggle(L10n.t("Show frame rate and throughput", "프레임과 전송량 표시"), isOn: $settings.menuBarStats)
                Text(L10n.t("Off: the icon only.", "끄면 아이콘만 보입니다.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.t("Language", "언어")) {
                Picker(L10n.t("Language", "언어"), selection: $settings.language) {
                    ForEach(Language.allCases, id: \.self) { Text(L10n.name($0)).tag($0) }
                }
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}
