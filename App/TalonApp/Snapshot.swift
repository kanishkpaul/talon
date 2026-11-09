import AppKit
import SwiftUI

/// `Talon --snapshot DIR [--demo]`: render the panel, Overview and Processes into PNGs and exit.
/// Lets the interface be checked from a terminal, with no screen-recording permission.
enum Snapshot {
    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(model: LiveModel, into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.start()
        model.beginViewing()
        Task {
            // Let a few polls land so sparklines and the process table have data.
            try? await Task.sleep(for: .seconds(4))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suffix = appearance == .aqua ? "light" : "dark"
                let panel = MenuPanel(model: model, openWindow: { _ in }, quit: {})
                await render(panel, size: nil, appearance: appearance, to: dir.appendingPathComponent("panel-\(suffix).png"))
                if let rule = model.asking.first {
                    await render(AskBanner(model: model, rule: rule).frame(width: 420).padding(6), size: nil, appearance: appearance,
                                 to: dir.appendingPathComponent("ask-\(suffix).png"))
                }
                model.selectedCeiling = model.ceilings.first?.id
                for pane in MainWindow.Pane.allCases {
                    let window = MainWindow(model: model, initial: pane)
                    if pane == .history { try? await Task.sleep(for: .seconds(1)) }
                    if pane == .scalpel, ProcessInfo.processInfo.environment["TALON_SNAPSHOT_SCAN"] != nil {
                        await render(window, size: NSSize(width: 1240, height: 860), appearance: appearance,
                                     to: dir.appendingPathComponent("scalpel-\(suffix).png"), settle: 12)
                        continue
                    }
                    await render(window, size: NSSize(width: 1240, height: 860), appearance: appearance,
                                 to: dir.appendingPathComponent("\(pane.rawValue.lowercased())-\(suffix).png"))
                }
            }
            print("snapshots written to \(dir.path)")
            NSApp.terminate(nil)
        }
    }

    private static func render<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance.Name, to url: URL, settle: Double = 2) async {
        let host = NSHostingView(rootView: view.frame(width: size?.width, height: size?.height)
            .background(Color(nsColor: .windowBackgroundColor)))  // offscreen there is no glass or window to sit on
        host.appearance = NSAppearance(named: appearance)
        let frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))   // offscreen
        window.orderFrontRegardless()
        host.frame = frame
        // Two seconds for charts, the outline's first reloads and icon loading.
        try? await Task.sleep(for: .seconds(settle))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
