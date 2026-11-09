// Renders the app icon to an .iconset directory: swift scripts/make-icon.swift <out.iconset>
// Two screens side by side, a window crossing the gap and a large pointer grabbing its title bar.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.45, alpha: 1)])!.draw(in: bg, angle: -90)

    // Two screens.
    let screenW = s * 0.34, screenH = s * 0.25, y = s * 0.42
    for x in [s * 0.15, s * 0.51] {
        let r = NSRect(x: x, y: y, width: screenW, height: screenH)
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: r, xRadius: s * 0.02, yRadius: s * 0.02).fill()
        NSColor(calibratedWhite: 1, alpha: 0.85).setStroke()
        let p = NSBezierPath(roundedRect: r, xRadius: s * 0.02, yRadius: s * 0.02)
        p.lineWidth = max(1, s * 0.012)
        p.stroke()
        NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
        NSBezierPath(rect: NSRect(x: x + screenW * 0.42, y: y - s * 0.05, width: screenW * 0.16, height: s * 0.05)).fill()
        NSBezierPath(roundedRect: NSRect(x: x + screenW * 0.3, y: y - s * 0.065, width: screenW * 0.4, height: s * 0.02),
                     xRadius: s * 0.01, yRadius: s * 0.01).fill()
    }

    // Window crossing the gap.
    let win = NSRect(x: s * 0.36, y: s * 0.47, width: s * 0.28, height: s * 0.16)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: win, xRadius: s * 0.015, yRadius: s * 0.015).fill()
    NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: win.minX, y: win.maxY - s * 0.04, width: win.width, height: s * 0.04),
                 xRadius: s * 0.015, yRadius: s * 0.015).fill()

    // Pointer grabbing the title bar (tip at top-left, y up here).
    let tip = NSPoint(x: s * 0.47, y: win.maxY - s * 0.02)
    let u = s * 0.0135
    let shape: [NSPoint] = [.init(x: 0, y: 0), .init(x: 0, y: 16.2), .init(x: 3.9, y: 12.6), .init(x: 6.4, y: 18.6),
                            .init(x: 9.1, y: 17.5), .init(x: 6.6, y: 11.6), .init(x: 11.6, y: 11.6)]
    let arrow = NSBezierPath()
    arrow.move(to: tip)
    for p in shape.dropFirst() { arrow.line(to: NSPoint(x: tip.x + p.x * u, y: tip.y - p.y * u)) }
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 1.6 * u
    NSColor.white.setStroke()
    arrow.stroke()
    NSColor.black.setFill()
    arrow.fill()

    // Motion arrow under the screens.
    let a = NSBezierPath()
    let ay = s * 0.25
    a.move(to: NSPoint(x: s * 0.32, y: ay)); a.line(to: NSPoint(x: s * 0.66, y: ay))
    a.move(to: NSPoint(x: s * 0.60, y: ay + s * 0.05)); a.line(to: NSPoint(x: s * 0.67, y: ay)); a.line(to: NSPoint(x: s * 0.60, y: ay - s * 0.05))
    a.lineWidth = max(1, s * 0.03)
    a.lineCapStyle = .round
    a.lineJoinStyle = .round
    NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.22, alpha: 1).setStroke()
    a.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
