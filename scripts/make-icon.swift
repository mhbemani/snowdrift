// Draws the app icon (snowflake on a night-blue rounded square) into Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: the rounded square fills ~80% of the canvas.
    let inset = s * 0.1, rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.18, blue: 0.36, alpha: 1),
                        NSColor(red: 0.30, green: 0.52, blue: 0.80, alpha: 1)])!.draw(in: shape, angle: 90)
    // A soft snow drift along the bottom.
    let drift = NSBezierPath()
    drift.move(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.18))
    drift.curve(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.22),
                controlPoint1: NSPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.32),
                controlPoint2: NSPoint(x: rect.minX + rect.width * 0.6, y: rect.minY + rect.height * 0.10))
    drift.line(to: NSPoint(x: rect.maxX, y: rect.minY)); drift.line(to: NSPoint(x: rect.minX, y: rect.minY)); drift.close()
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    NSColor(white: 0.97, alpha: 1).setFill(); drift.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // The snowflake (SF Symbol), white.
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium)
    if let flake = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: flake.size, flipped: false) { r in
            flake.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let sz = tinted.size
        tinted.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2 + s * 0.04, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("wrote \(out.path); now: iconutil -c icns \(out.path)")
