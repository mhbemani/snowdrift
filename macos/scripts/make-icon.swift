// Draws the app icon (Cozy Drift, blue cream) into Resources/AppIcon.iconset, then run
//   iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
// It also writes ../windows/assets/snowdrift.ico (tray and exe icon: the tile filling the square).
// Run from macos/: swift scripts/make-icon.swift
//
// Designed on the "Snowdrift App Icon" canvas (concept "Cozy Drift, blue cream"), then tuned for
// contrast here. This script is the source of truth. It draws with Core Graphics in the design's
// 100×100, y-down coordinates (macOS's SVG renderer can't do the soft shadows).
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

/// Contrast: the tile is a clear winter blue so the white snow and the cream window stand out
/// (an all-pale version read as a white square). Small sizes (≤ 64 px: Finder, Spotlight) get a
/// ~1 px outline; larger ones a soft outline that scales with the icon.
func render(_ px: Int, tight: Bool = false) -> Data {
    let s = CGFloat(px)
    let small = px <= 64
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = s / 100
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: k, y: -k)          // SVG units, y down
    // Windows icons fill their square (macOS ones keep a margin): grow the tile to ~1 unit from the edge.
    if tight { ctx.translateBy(x: 50, y: 50); ctx.scaleBy(x: 1.22, y: 1.22); ctx.translateBy(x: -50, y: -50) }
    // Shadow offsets/blur are in device pixels and ignore the transform; y up in device space.
    func shadow(_ dy: CGFloat, _ std: CGFloat, _ c: UInt32, _ a: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * k), blur: 2 * std * k, color: color(c, a))
    }
    func vgradient(_ top: UInt32, _ bottom: UInt32, _ y0: CGFloat, _ y1: CGFloat) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    }
    let tile = CGPath(roundedRect: CGRect(x: 9.8, y: 9.8, width: 80.4, height: 80.4), cornerWidth: 18, cornerHeight: 18, transform: nil)
    let outline = color(0x5F82B4, small ? 1 : 0.55)
    let lineWidth = small ? (px <= 32 ? 1.0 : 1.5) / k : 0.7        // ~1 px small; scales with the icon large

    // Background tile: sky blue at the top to a deeper winter blue at the bottom.
    ctx.saveGState(); shadow(1.4, 1.4, 0x22395C, 0.32)
    ctx.addPath(tile); ctx.setFillColor(color(0x6F98D0)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(tile); ctx.clip(); vgradient(0xB6CFEE, 0x6F98D0, 9.8, 90.2); ctx.restoreGState()

    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    // Falling flakes: white, like snow against a blue sky
    ctx.setFillColor(color(0xFFFFFF, 0.95))
    for (x, y, r) in [(28.0, 20.0, 1.9), (47, 16, 1.5), (70, 20, 2.1), (80, 30, 1.4)] {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    // Window: warm cream, soft shadow, outline
    let window = CGPath(roundedRect: CGRect(x: 21, y: 38, width: 58, height: 40), cornerWidth: 7, cornerHeight: 7, transform: nil)
    ctx.saveGState(); shadow(1.0, 1.0, 0x2E4A72, 0.35); ctx.addPath(window); ctx.setFillColor(color(0xF2DFC4)); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(window); ctx.clip(); vgradient(0xFFF7EA, 0xF2DFC4, 38, 78); ctx.restoreGState()
    ctx.addPath(window); ctx.setStrokeColor(outline); ctx.setLineWidth(lineWidth); ctx.strokePath()
    for (x, c) in [(28.5, 0xEE8A78 as UInt32), (34.5, 0xF0BE5E), (40.5, 0x8CCB94)] {
        ctx.setFillColor(color(c)); ctx.fillEllipse(in: CGRect(x: x - 2, y: 44, width: 4, height: 4))
    }
    for (y, w, c) in [(54.0, 30.0, 0xA9BFDD as UInt32), (61, 44, 0xB6CAE4), (68, 22, 0xC2D2E8)] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 27, y: CGFloat(y), width: CGFloat(w), height: 3), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        ctx.setFillColor(color(c)); ctx.fillPath()
    }
    // Snow cap and drift: pure white with a cool shadow
    ctx.saveGState(); shadow(1.0, 1.0, 0x2E4A72, 0.35)
    let cap = svgPath("M17 39.5 C16 31 23 28 29 30.5 C32 24.5 41 24 45 29 C50 23.5 60 24 63 30 C69 27 81 29 83 37 C84.5 41.5 81 43 77 42.5 C76.5 46.5 72 47.5 70.5 43.5 L23 43 C19 43.5 17 42 17 39.5 Z")
    ctx.addPath(cap); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath(); ctx.restoreGState()
    ctx.addPath(cap); ctx.setStrokeColor(outline); ctx.setLineWidth(lineWidth); ctx.strokePath()
    ctx.saveGState(); shadow(1.0, 1.0, 0x2E4A72, 0.3)
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

// .ico with PNG entries (Vista+): header, one 16-byte entry per size, then the PNGs.
let icoSizes = [16, 20, 24, 32, 40, 48, 64, 256]
let pngs = icoSizes.map { render($0, tight: true) }
var ico = Data()
func le16(_ v: Int) { ico.append(UInt8(v & 0xff)); ico.append(UInt8(v >> 8 & 0xff)) }
func le32(_ v: Int) { le16(v & 0xffff); le16(v >> 16) }
le16(0); le16(1); le16(icoSizes.count)
var offset = 6 + 16 * icoSizes.count
for (size, png) in zip(icoSizes, pngs) {
    ico.append(UInt8(size % 256)); ico.append(UInt8(size % 256)); ico.append(0); ico.append(0)
    le16(1); le16(32); le32(png.count); le32(offset)
    offset += png.count
}
pngs.forEach { ico.append($0) }
let icoURL = URL(fileURLWithPath: "../windows/assets/snowdrift.ico")
try FileManager.default.createDirectory(at: icoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try ico.write(to: icoURL)
print("wrote \(icoURL.path)")
