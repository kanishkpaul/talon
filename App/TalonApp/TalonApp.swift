import ServiceManagement
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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Open Talon at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
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
