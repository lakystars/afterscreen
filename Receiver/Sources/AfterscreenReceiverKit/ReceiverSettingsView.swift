import AfterscreenCore
import SwiftUI

/// Receiver settings window content; SwiftUI as of macOS 10.15
struct ReceiverSettingsView: View {
    @ObservedObject var settings: ReceiverSettings

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
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Show the stream", "스트림 표시 방식")).font(.headline)
                Picker("", selection: $settings.presentation) {
                    Text(L10n.t("A desktop of its own (Control-arrow switches to this Mac's)", "별도 데스크톱 (Control + 화살표로 이 Mac 데스크톱과 전환)"))
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
                    Text(L10n.t("Show this Mac's desktop", "이 Mac의 데스크톱 보기")).tag(ReceiverSettings.OnDisconnect.showDesktop)
                    Text(L10n.t("Turn the display off", "화면 끄기")).tag(ReceiverSettings.OnDisconnect.sleepDisplay)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()
                Text(L10n.t("Stopping on this Mac (Esc twice) always shows the desktop.", "이 Mac에서 중지하면(Esc 두 번) 항상 데스크톱이 보입니다."))
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
