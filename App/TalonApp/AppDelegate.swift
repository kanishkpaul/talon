import AppKit
import SwiftUI
import TalonModel

/// The AppKit spine: an NSStatusItem with a borderless, non-activating glass panel (MenuBarExtra
/// can't host AppKit views reliably, doesn't animate, and breaks Settings on macOS 26), plus the
/// main window, owned here so the panel can open it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LiveModel.shared
    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanel?
    private var window: NSWindow?
    private var outsideClick: Any?
    private var iconTimer: Timer?
    private var askPanel: NSPanel?
    private var askingFor: UUID?

    func applicationDidFinishLaunching(_ note: Notification) {
        if let dir = Snapshot.requestedDirectory {
            Snapshot.run(model: model, into: dir)
            return
        }
        model.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Talon")
            button.setAccessibilityLabel("Talon")
            button.setAccessibilityHelp("Shows CPU, memory, heat, power and your ceilings")
            button.action = #selector(togglePanel)
            button.target = self
        }
        iconTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIcon()
                self?.refreshAsk()
            }
        }
        if CommandLine.arguments.contains("--open") { showWindow(.overview) }
    }

    /// The icon is quiet until something needs attention: orange under memory or thermal pressure,
    /// red when either is critical, dimmed when talond isn't answering.
    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let s = model.latest
        let mem = s?.memoryPressure ?? .normal
        let heat = s?.thermalPressure ?? .nominal
        let phases = model.ceilingStates.values.map(\.phase)
        if !model.connection.isLive {
            button.contentTintColor = .tertiaryLabelColor
        } else if mem == .critical || heat.rawValue >= ThermalPressure.trapping.rawValue || phases.contains(.asking) {
            button.contentTintColor = .systemRed
        } else if mem == .warning || heat.rawValue >= ThermalPressure.moderate.rawValue
                    || phases.contains(.approaching) || phases.contains(.over) || phases.contains(.enforced) {
            button.contentTintColor = .systemOrange
        } else {
            button.contentTintColor = nil
        }
        button.setAccessibilityValue(model.asking.isEmpty ? (s.map { "CPU \(Fmt.pct($0[.cpu])), memory \(Fmt.bytes($0[.memUsed]))" } ?? "not connected")
                                                         : "\(model.asking.count) ceiling waiting for an answer")
        button.toolTip = s.map {
            "CPU \(Fmt.pct($0[.cpu])) · memory \(Fmt.bytes($0[.memUsed])) · \(Fmt.temp($0[.cpuTemp])) · \(Fmt.watts($0[.systemPower]))"
        } ?? "talond isn't connected"
    }

    // MARK: - Ask panel

    /// An Ask ceiling was crossed: a small glass panel under the menu bar, top right, until it's
    /// answered (here, in the window, or with `talon ceiling answer`) or usage drops back.
    private func refreshAsk() {
        let pending = model.asking.first
        if let shown = askingFor, pending?.id != shown {
            askPanel?.orderOut(nil)
            askPanel = nil
            askingFor = nil
        }
        guard let rule = pending, askingFor == nil else { return }
        let panel = MenuBarPanel(content: AskBanner(model: model, rule: rule) { [weak self] in
            self?.askPanel?.orderOut(nil)
            self?.askPanel = nil
            self?.askingFor = nil
        }
        .frame(width: 420)
        .padding(6))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 12, y: screen.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
        askPanel = panel
        askingFor = rule.id
    }

    // MARK: - Panel

    @objc private func togglePanel() {
        if let panel, panel.isVisible { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let content = MenuPanel(model: model, openWindow: { [weak self] pane in
            self?.closePanel()
            self?.showWindow(pane)
        }, quit: { NSApp.terminate(nil) })
        let panel = MenuBarPanel(content: content)
        panel.onCancel = { [weak self] in self?.closePanel() }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        if let screen = buttonWindow.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    // MARK: - Window

    func showWindow(_ pane: MainWindow.Pane) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Talon"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 820, height: 560)
            w.setFrameAutosaveName("TalonMainWindow")
            w.center()
            window = w
        }
        window?.contentViewController = NSHostingController(rootView: MainWindow(model: model, initial: pane))
        NSApp.setActivationPolicy(.regular)       // a Dock icon while the window is open
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: window)
    }

    @objc private func windowClosed() {
        NSApp.setActivationPolicy(.accessory)     // back to menu-bar-only
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow(.overview)
        return true
    }
}

/// Borderless, non-activating, glass. Becomes key so its controls work without stealing the
/// frontmost app's activation.
final class MenuBarPanel: NSPanel {
    init<Content: View>(content: Content) {
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Liquid Glass, unless the user asked for less transparency: then a solid, rounded panel.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(frame: NSRect(origin: .zero, size: size))
            solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            solid.layer?.cornerRadius = 20
            solid.layer?.borderWidth = 0.5
            solid.layer?.borderColor = NSColor.separatorColor.cgColor
            solid.addSubview(host)
            host.frame = solid.bounds
            host.autoresizingMask = [.width, .height]
            contentView = solid
        } else {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
            glass.cornerRadius = 20
            glass.contentView = host
            host.frame = glass.bounds
            host.autoresizingMask = [.width, .height]
            contentView = glass
        }
    }

    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
