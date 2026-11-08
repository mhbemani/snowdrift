// Draws the app icon (Cozy Drift, blue cream) into Resources/AppIcon.iconset, then run
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
// Run from the repo root: swift scripts/make-icon.swift
//
// The design source is Resources/AppIcon.svg (made on the design canvas). macOS's SVG renderer
// doesn't support its soft shadows (feDropShadow), so the same shapes are drawn here with Core
// Graphics in the SVG's own 100×100, y-down coordinates.
import AppKit

let out = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// SVG path data with absolute M, L, C, Z (all the design uses).
func svgPath(_ d: String) -> CGPath {
    let p = CGMutablePath()
    // Split commands from numbers ("M17" → "M", "17"), then on whitespace and commas.
    let spaced = d.replacingOccurrences(of: "([MLCZ])", with: " $1 ", options: .regularExpression)
    let t = spaced.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
    var i = 0, cmd = ""
    func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(t[i])!) }
    while i < t.count {
        if let c = t[i].first, c.isLetter { cmd = String(c); i += 1; if cmd == "Z" { p.closeSubpath() }; continue }
        switch cmd {
        case "M": p.move(to: CGPoint(x: n(), y: n()))
        case "L": p.addLine(to: CGPoint(x: n(), y: n()))
        case "C":
            let c1 = CGPoint(x: n(), y: n()), c2 = CGPoint(x: n(), y: n()), e = CGPoint(x: n(), y: n())
            p.addCurve(to: e, control1: c1, control2: c2)
        default: i += 1
        }
    }
    return p
}

/// Small sizes (≤ 64 px: Finder lists, Spotlight) get more contrast: a deeper blue tile, deeper
/// flakes and lines, and a ~1 px outline around the window and the snow cap. Large sizes are the
/// design exactly as approved.
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let small = px <= 64
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = s / 100
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: k, y: -k)          // SVG units, y down
    // Shadow offsets/blur are in device pixels and ignore the transform; y up in device space.
    func shadow(_ dy: CGFloat, _ std: CGFloat, _ c: UInt32, _ a: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * k), blur: 2 * std * k, color: color(c, a))
    }
    func vgradient(_ top: UInt32, _ bottom: UInt32, _ y0: CGFloat, _ y1: CGFloat) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    }
    let tile = CGPath(roundedRect: CGRect(x: 9.8, y: 9.8, width: 80.4, height: 80.4), cornerWidth: 18, cornerHeight: 18, transform: nil)

    // Background tile with its shadow.
    ctx.saveGState(); shadow(1.2, 1.2, 0x3F5A80, 0.22)
    let (bgTop, bgBottom): (UInt32, UInt32) = small ? (0xE1ECF8, 0xB3CAE8) : (0xF5F9FE, 0xD6E4F4)
    ctx.addPath(tile); ctx.setFillColor(color(bgBottom)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(tile); ctx.clip(); vgradient(bgTop, bgBottom, 9.8, 90.2); ctx.restoreGState()
    let outline = color(0x7F9CC4)
    let hairline = (px <= 32 ? 1.0 : 1.5) / k                     // ~1 px whatever the size

    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    // Falling flakes
    ctx.setFillColor(color(small ? 0x8EADD6 : 0xAFC7E4))
    for (x, y, r) in [(28.0, 20.0, 1.8), (47, 16, 1.4), (70, 20, 2.0), (80, 30, 1.3)] {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    // Window (cream), soft shadow
    let window = CGPath(roundedRect: CGRect(x: 21, y: 38, width: 58, height: 40), cornerWidth: 7, cornerHeight: 7, transform: nil)
    ctx.saveGState(); shadow(0.8, 0.8, 0x5A7398, 0.25); ctx.addPath(window); ctx.setFillColor(color(0xF5E8D6)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(window); ctx.clip(); vgradient(0xFFFAF2, 0xF5E8D6, 38, 78); ctx.restoreGState()
    if small { ctx.addPath(window); ctx.setStrokeColor(outline); ctx.setLineWidth(hairline); ctx.strokePath() }
    for (x, c) in [(28.5, 0xF2A091 as UInt32), (34.5, 0xF3CC80), (40.5, 0xA6D8AC)] {
        ctx.setFillColor(color(c)); ctx.fillEllipse(in: CGRect(x: x - 2, y: 44, width: 4, height: 4))
    }
    let lines: [(CGFloat, CGFloat, UInt32)] = small ? [(54, 30, 0xB4C8E2), (61, 44, 0xBFD0E7), (68, 22, 0xC8D7EB)]
                                                    : [(54, 30, 0xD3DFEE), (61, 44, 0xDCE6F2), (68, 22, 0xE3EBF5)]
    for (y, w, c) in lines {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 27, y: y, width: w, height: 3), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        ctx.setFillColor(color(c)); ctx.fillPath()
    }
    // Snow cap, highlight, drift
    ctx.saveGState(); shadow(0.8, 0.8, 0x5A7398, 0.25)
    let cap = svgPath("M17 39.5 C16 31 23 28 29 30.5 C32 24.5 41 24 45 29 C50 23.5 60 24 63 30 C69 27 81 29 83 37 C84.5 41.5 81 43 77 42.5 C76.5 46.5 72 47.5 70.5 43.5 L23 43 C19 43.5 17 42 17 39.5 Z")
    ctx.addPath(cap); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath(); ctx.restoreGState()
    if small { ctx.addPath(cap); ctx.setStrokeColor(outline); ctx.setLineWidth(hairline); ctx.strokePath() }
    ctx.setFillColor(color(0xFFFFFF, 0.9)); ctx.fillEllipse(in: CGRect(x: 29, y: 29.9, width: 10, height: 3.2))
    ctx.saveGState(); shadow(0.8, 0.8, 0x5A7398, 0.25)
    ctx.addPath(svgPath("M4 88 C20 80 36 85 50 83 C64 81 80 78 96 85 L96 100 L4 100 Z"))
    ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath(); ctx.restoreGState()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("wrote \(out.path)")
