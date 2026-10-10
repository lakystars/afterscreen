import SwiftUI

/// Receiver settings window content; SwiftUI as of macOS 10.15
struct ReceiverSettingsView: View {
    @ObservedObject var settings: ReceiverSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            VStack(alignment: .leading, spacing: 4) {
                Text("Accept connections over").font(.headline)
                Picker("", selection: $settings.accept) {
                    Text("Any network: Thunderbolt, USB, Ethernet or Wi-Fi").tag(ReceiverSettings.Accept.any)
                    Text("Cables only: Thunderbolt, USB or Ethernet").tag(ReceiverSettings.Accept.wired)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("When the sender disconnects").font(.headline)
                Picker("", selection: $settings.onDisconnect) {
                    Text("Show this Mac's desktop").tag(ReceiverSettings.OnDisconnect.showDesktop)
                    Text("Turn the display off").tag(ReceiverSettings.OnDisconnect.sleepDisplay)
                }
                .pickerStyle(RadioGroupPickerStyle())
                .labelsHidden()
                Text("Stopping on this Mac (Esc twice) always shows the desktop.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
    }
}
