import AfterscreenCore
import SwiftUI

/// Receiver settings window content; SwiftUI as of macOS 10.15
struct ReceiverSettingsView: View {
    @ObservedObject var settings: ReceiverSettings
    let pairings: PairingStoring
    /// Re-read after a removal; the keychain posts no change
    @State private var paired: [(id: String, name: String)] = []

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
                    Text(L10n.t("Picture tube", "브라운관")).tag(ReceiverSettings.Effect.crt)
                    Text(L10n.t("None", "없음")).tag(ReceiverSettings.Effect.none)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()
                Text(L10n.t("Applies from the next connection.", "다음 연결부터 적용됩니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("When the sender disconnects", "송신기 연결이 끊기면")).font(.headline)
                Picker("", selection: $settings.onDisconnect) {
                    Text(L10n.t("Show \(ComputerName.current)'s desktop", "\(ComputerName.current) 데스크톱 보기")).tag(ReceiverSettings.OnDisconnect.showDesktop)
                    Text(L10n.t("Turn the display off", "화면 끄기")).tag(ReceiverSettings.OnDisconnect.sleepDisplay)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()
                Text(L10n.t("Stopping on \(ComputerName.current) (Esc twice) always shows the desktop.",
                            "\(ComputerName.current)에서 중지하면(Esc 두 번) 항상 데스크톱이 보입니다."))
                    .font(.caption).foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Language", "언어")).font(.headline)
                Picker("", selection: $settings.language) {
                    ForEach(Language.allCases, id: \.self) { Text(L10n.name($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}
