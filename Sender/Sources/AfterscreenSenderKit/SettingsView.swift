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
            Section("Display") {
                Picker("Size", selection: $settings.displaySize) {
                    ForEach(DisplaySize.allCases) { size in
                        let p = size.points(for: panelPoints)
                        Text("\(size.title)  ·  looks like \(p.width) × \(p.height)").tag(size)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Applies while streaming. System Settings → Displays lists the same sizes.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Arrange Displays…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                }
            }
            Section("Connection") {
                Toggle("Connect automatically", isOn: $settings.autoConnect)
                Text(settings.lastReceiver.map { "Connects to \($0) when it appears, after sleep, and after the link drops." }
                     ?? "Connects to the receiver you last connected to.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
