// Snowdrift: click-through overlay on every screen with Metal-drawn snow that piles up.
// Run: swift run -c release Snowdrift [options]
//   --seconds N   auto-quit after N seconds (safety net for test runs)
//   --fps F       frame rate cap, 1–120 (default 60)
//   --lead L      predict window positions L frames ahead to hide overlay lag, 0–5 (default 1)
//   --snowrate R  pile growth speed multiplier, 0–100 (default 1; 20 to see piles quickly)
//   --debug       outline tracked windows + Dock estimate, print stats on quit (includes --log)
//   --log         print why snow leaves a window
//   --selftest    check the physics invariants and exit
//
// Files: main (startup) · Controller (menu, settings, pause, displays) · Snowpack (snow on surfaces)
// · Model (surfaces, piles, per-pile physics) · Physics (tunables) · WindowTracker · Dock
// · Renderer + Shaders (Metal) · SelfTest.

import AppKit

/// Command-line options, clamped to safe ranges (a bad value can't divide by zero or overflow).
struct Options {
    var seconds: Double?
    var fps = 60
    var leadFrames = 1.0
    var snowRate: Float = 1
    var debug = false, log = false, selfTest = false

    init(_ args: [String]) {
        func value(_ name: String) -> Double? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]), v.isFinite else { return nil }
            return v
        }
        seconds = value("--seconds").map { max(0, $0) }
        fps = Int(min(120, max(1, value("--fps") ?? 60)))
        leadFrames = min(5, max(0, value("--lead") ?? 1))
        snowRate = Float(min(100, max(0, value("--snowrate") ?? 1)))
        debug = args.contains("--debug")
        log = debug || args.contains("--log")
        selfTest = args.contains("--selftest")
    }
}

/// Screens in global top-left coordinates (what the window list uses); Cocoa is bottom-left with
/// the primary screen at the origin. Empty while displays reconfigure.
@MainActor func currentScreens() -> [ScreenInfo] {
    guard let primary = NSScreen.screens.first else { return [] }
    return NSScreen.screens.map { s in
        ScreenInfo(frame: CGRect(x: s.frame.minX, y: primary.frame.height - s.frame.maxY, width: s.frame.width, height: s.frame.height),
                   menuBar: s.frame.maxY - s.visibleFrame.maxY,
                   dockThickness: s.visibleFrame.minY - s.frame.minY)
    }
}

/// Points per centimetre on the main display, from its physical size (EDID), for real-world distances.
@MainActor func pointsPerCentimetre() -> Float {
    let mm = CGDisplayScreenSize(CGMainDisplayID())
    guard let width = NSScreen.screens.first?.frame.width, mm.width > 0 else { return 49 }   // ~13" laptop
    return Float(width / (mm.width / 10))
}

let options = Options(CommandLine.arguments)
let tracker = WindowTracker(debug: options.log)
let dock = DockInfo()
let snowpack = Snowpack(tracker: tracker, dock: dock, screens: currentScreens(),
                        lead: options.leadFrames / Double(options.fps), rateScale: options.snowRate,
                        pointsPerCm: pointsPerCentimetre())
snowpack.debugLog = options.log

if options.selfTest {
    let failures = selfTest(snowpack)
    print(failures.isEmpty ? "selftest: OK" : "selftest FAILED:\n" + failures.joined(separator: "\n"))
    exit(failures.isEmpty ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)             // no Dock icon, no app menu

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Snowdrift needs a Metal GPU") }
let controller: Controller
do {
    controller = try Controller(gpu: try GPU(device: device, debug: options.debug), dock: dock, snowpack: snowpack,
                                tracker: tracker, fps: options.fps, screens: currentScreens)
} catch {
    fatalError("Snowdrift couldn't start the GPU: \(error)")
}

if options.debug {
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        print(tracker.stats())
        MainActor.assumeIsolated {
            let snow = snowpack.piles.values.reduce(0) { $0 + $1.mass }
            print("dock platter:", snowpack.dockRect.map { NSStringFromRect($0) } ?? "none")
            print(String(format: "piles: %d, total snow %.0f pt², awake %d, clumps %d, landing rates %@",
                         snowpack.piles.count, snow, snowpack.piles.values.filter(\.awake).count, snowpack.clumps.count,
                         snowpack.screens.map { String(format: "%.1f/s", $0.landingRate) }.joined(separator: " ")))
        }
    }
}

if let seconds = options.seconds {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { app.terminate(nil) }
}

app.run()
