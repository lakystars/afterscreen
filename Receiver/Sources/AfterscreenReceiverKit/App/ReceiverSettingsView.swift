import AfterscreenCore
import AppKit
import SwiftUI

/// Receiver settings window content; SwiftUI as of macOS 10.15
struct ReceiverSettingsView: View {
    @ObservedObject var settings: ReceiverSettings
    let pairings: PairingStoring
    /// Re-read after a removal; the keychain posts no change
    @State private var paired: [(id: String, name: String)] = []
    /// Re-read as screens come and go
    @State private var displays: [ReceiverDisplay] = []

    /// Automatic is the empty key
    private var displayChoice: Binding<String> {
        Binding(get: { settings.display?.key ?? "" }, set: { key in
            guard !key.isEmpty else { return settings.display = nil }
            if let d = displays.first(where: { $0.key == key }) { settings.display = .init(key: d.key, name: d.name) }
        })
    }

    private var chosenMissing: ReceiverSettings.ChosenDisplay? {
        settings.display.flatMap { chosen in displays.contains { $0.key == chosen.key } ? nil : chosen }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(L10n.t("Open at login", "로그인 시 열기"), isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Accept connections over", "받을 연결")).font(.headline)
                Picker("", selection: $settings.accept) {
                    Text(L10n.t("Any network: Thunderbolt, USB, Ethernet or Wi-Fi", "모든 연결: Thunderbolt, USB, 이더넷, Wi-Fi"))
                        .tag(ReceiverSettings.Accept.any)
                    Text(L10n.t("Cables only: Thunderbolt, USB or Ethernet", "케이블만: Thunderbolt, USB, 이더넷")).tag(ReceiverSettings.Accept.wired)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()
                Toggle(L10n.t("Ethernet and Wi-Fi: paired Macs only", "이더넷·Wi-Fi는 페어링한 Mac만"), isOn: $settings.pairedOnly)
                Text(L10n.t("A Mac connecting for the first time pairs with a code shown here. Thunderbolt and USB cables connect without pairing.",
                            "처음 연결하는 Mac은 이 화면에 표시되는 코드로 페어링합니다. Thunderbolt·USB 케이블은 페어링 없이 연결됩니다."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(paired, id: \.id) { pair in
                    HStack {
                        Text(pair.name)
                        Spacer()
                        Button(L10n.t("Remove", "해제")) {
                            pairings.remove(pair.id)
                            paired = pairings.pairs
                        }
                    }
                    .font(.system(size: 12))
                }
            }
            .onAppear { paired = pairings.pairs }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Show on", "표시할 화면")).font(.headline)
                Picker("", selection: displayChoice) {
                    Text(L10n.t("Automatic: \(ComputerName.current)'s own screen first", "자동: \(ComputerName.current) 자체 화면 우선")).tag("")
                    ForEach(displays, id: \.key) { d in
                        // Verbatim: no thousands separators
                        Text(verbatim: "\(d.name) · \(d.pixels.width)×\(d.pixels.height)").tag(d.key)
                    }
                    if let missing = chosenMissing {
                        Text(L10n.t("\(missing.name) (not connected)", "\(missing.name) (연결 안 됨)")).tag(missing.key)
                    }
                }
                .labelsHidden()
                .frame(width: 340)
                if let missing = chosenMissing {
                    Text(L10n.t("\(missing.name) is not connected, so the screen is picked automatically.",
                                "\(missing.name)이(가) 연결돼 있지 않아 자동으로 고릅니다."))
                        .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Toggle(L10n.t("Switch the screen to its 1:1 resolution while streaming", "스트리밍 중에는 화면을 패널 1:1 해상도로 전환"), isOn: $settings.matchPanelMode)
                Text(L10n.t("A scaled resolution resamples the stream twice and blurs it. Windows on \(ComputerName.current) may move when it switches back. Applies from the next connection.",
                            "스케일된 해상도에서는 스트림이 두 번 리샘플링돼 흐려집니다. 되돌릴 때 \(ComputerName.current)의 창 위치가 바뀔 수 있습니다. 다음 연결부터 적용됩니다."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { displays = ReceiverDisplay.connected() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = ReceiverDisplay.connected()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Show the stream", "스트림 표시 방식")).font(.headline)
                Picker("", selection: $settings.presentation) {
                    Text(L10n.t("A desktop of its own (Control-arrow switches to \(ComputerName.current)'s)",
                                "별도 데스크톱 (Control + 화살표로 \(ComputerName.current) 데스크톱과 전환)"))
                        .tag(ReceiverSettings.Presentation.space)
                    Text(L10n.t("Cover the whole screen, menu bar and Dock included", "화면 전체 덮기 (메뉴 막대와 Dock 포함)"))
                        .tag(ReceiverSettings.Presentation.cover)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()
                Text(L10n.t("Applies from the next connection.", "다음 연결부터 적용됩니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Connection effect", "연결 효과")).font(.headline)
                Picker("", selection: $settings.effect) {
                    Text(L10n.t("Tile wave", "타일 웨이브")).tag(ReceiverSettings.Effect.tiles)
                    Text(L10n.t("None", "없음")).tag(ReceiverSettings.Effect.none)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()
                Text(L10n.t("Applies from the next connection.", "다음 연결부터 적용됩니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Display with no sender", "송신기가 없을 때 화면")).font(.headline)
                Picker("", selection: $settings.onDisconnect) {
                    Text(L10n.t("Show \(ComputerName.current)'s desktop", "\(ComputerName.current) 데스크톱 보기")).tag(ReceiverSettings.OnDisconnect.showDesktop)
                    Text(L10n.t("Turn the display off", "화면 끄기")).tag(ReceiverSettings.OnDisconnect.sleepDisplay)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()
                Text(L10n.t("Stopping on \(ComputerName.current) (Esc twice) always shows the desktop.",
                            "\(ComputerName.current)에서 중지하면(Esc 두 번) 항상 데스크톱이 보입니다."))
                    .font(.caption).foregroundColor(.secondary)
                Text(L10n.t("To sleep or shut down the receiver, choose it in the sender's settings. That setting comes first.",
                            "수신기를 잠자기로 전환하거나 종료하려면 송신기 설정에서 고르세요. 그 설정이 우선합니다."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                ShutdownPermission().padding(.top, 6)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}

/// Consent for a sender's shut down request
/// Until given, such a request sleeps this Mac
private struct ShutdownPermission: View {
    /// nil until read on appear: each read asks TCC
    @State private var status: OSStatus?
    @State private var asking = false

    private var denied: Bool { status == OSStatus(errAEEventNotPermitted) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.t("Shut down when the sender asks", "송신기가 요청하면 시스템 종료"))
                Spacer()
                if status == noErr {
                    Text(L10n.t("Allowed", "허용됨")).foregroundColor(.secondary)
                } else if denied {
                    Button(L10n.t("Open Settings…", "설정 열기…")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                } else if status != nil {
                    // Blocks until answered: off main
                    Button(L10n.t("Allow…", "허용…")) {
                        asking = true
                        DispatchQueue.global().async {
                            let answer = Shutdown.consent(ask: true)
                            DispatchQueue.main.async { status = answer; asking = false }
                        }
                    }
                    .disabled(asking)
                }
            }
            Text(caption).font(.caption).foregroundColor(.secondary)
        }
        .onAppear(perform: refresh)
        // Back from System Settings: this window stayed open
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var caption: String {
        if status == noErr { return L10n.t("Chosen on the sender, in its settings.", "송신기 설정에서 선택합니다.") }
        if denied {
            return L10n.t("Turn on loginwindow for Afterscreen Receiver under Automation; the button opens it.",
                          "자동화 항목에서 Afterscreen Receiver의 loginwindow를 켜세요. 버튼을 누르면 그 화면이 열립니다.")
        }
        return L10n.t("Chosen on the sender, in its settings. Until allowed here, the request puts \(ComputerName.current) to sleep.",
                      "송신기 설정에서 선택합니다. 여기서 허용하기 전에는 요청이 오면 \(ComputerName.current)을(를) 잠자기로 전환합니다.")
    }

    private func refresh() {
        status = Shutdown.consent(ask: false)
    }
}
