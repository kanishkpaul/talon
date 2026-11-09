// Regenerate the app icon: swiftc -O App/tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon App/TalonApp/Assets.xcassets/AppIcon.appiconset
import AppKit
// Renders the talon icon: a white bird on a deep blue squircle with a soft top light.
let out = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSShadow().then { $0.shadowBlurRadius = s * 0.02; $0.shadowOffset = NSSize(width: 0, height: -s * 0.01); $0.shadowColor = .black.withAlphaComponent(0.3); $0.set() }
    NSGradient(colors: [NSColor(red: 0.04, green: 0.52, blue: 1, alpha: 1), NSColor(red: 0.02, green: 0.16, blue: 0.45, alpha: 1)])!
        .draw(in: path, angle: -90)
    NSShadow().set()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [.white.withAlphaComponent(0.20), .white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let bird = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let b = bird.size
        bird.draw(in: NSRect(x: (s - b.width) / 2, y: (s - b.height) / 2 - s * 0.01, width: b.width, height: b.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
extension NSShadow { func then(_ f: (NSShadow) -> Void) -> NSShadow { f(self); return self } }
var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png"
        try! render(pt * sc).write(to: URL(fileURLWithPath: out + "/" + name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(sc)x", "filename": name])
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["version": 1, "author": "xcode"]], options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: out + "/Contents.json"))
print("icon written")
