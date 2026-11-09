import SwiftUI

/// Talon lives in the menu bar. The window (Overview, Processes) opens from the panel, from the
/// Dock while it's open, or at launch with `--open`. `--demo` uses synthetic data; `--snapshot DIR`
/// renders every surface to PNGs and exits.
@main
struct TalonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

struct SettingsView: View {
    var model: LiveModel

    var body: some View {
        Form {
            LabeledContent("Data source") {
                switch model.connection {
                case .connected(let l): Text(l)
                case .connecting: Text("connecting…")
                case .unavailable: Text("talond not running").foregroundStyle(.secondary)
                }
            }
            if let s = model.status {
                LabeledContent("talond", value: "\(s.version) · pid \(s.pid)")
                LabeledContent("History", value: Fmt.bytes(s.databaseBytes))
                LabeledContent("Database", value: s.databasePath)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
