// Snowdrift: click-through overlay on every screen with Metal-drawn snow that piles up.
// Run: swift run -c release Snowdrift [--seconds N] [--fps F] [--debug] [--lead L] [--snowrate R]
//   --seconds N   auto-quit after N seconds (safety net for test runs)
//   --fps F       frame rate cap (default 60)
//   --debug       outline tracked windows + Dock estimate, print stats on quit
//   --lead L      predict window position L frames ahead to hide overlay lag (default 1)
//   --snowrate R  pile growth speed multiplier (default 1; try 10 to see piles quickly)
//   --selftest    check the plow's invariants (mass kept, ridge capped) and exit
//   --log         print why snow leaves a window (no outlines; --debug includes this)

import AppKit
import MetalKit

func arg(_ name: String) -> Double? {
    CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil }
}
let fps = Int(arg("--fps") ?? 60)
let debug = CommandLine.arguments.contains("--debug")
let eventLog = debug || CommandLine.arguments.contains("--log")
let tracker = WindowTracker(debug: eventLog)
let dock = DockInfo()

// Screens in global top-left coordinates (what the window list uses); Cocoa is bottom-left.
@MainActor func currentScreens() -> [ScreenInfo] {
    let primaryHeight = NSScreen.screens[0].frame.height
    return NSScreen.screens.map { s in
        ScreenInfo(frame: CGRect(x: s.frame.minX, y: primaryHeight - s.frame.maxY, width: s.frame.width, height: s.frame.height),
                   menuBar: s.frame.maxY - s.visibleFrame.maxY,
                   dockThickness: s.visibleFrame.minY - s.frame.minY)
    }
}
let screenInfos = currentScreens()
// Points per centimetre on the main display, from its physical size (EDID), for "6–7 cm" distances.
let pointsPerCm: Float = {
    let mm = CGDisplayScreenSize(CGMainDisplayID())
    let pts = NSScreen.screens[0].frame.width
    return mm.width > 0 ? Float(pts / (mm.width / 10)) : 49
}()
let snowpack = Snowpack(tracker: tracker, dock: dock, screens: screenInfos,
                        lead: (arg("--lead") ?? 1) / Double(fps), rateScale: Float(arg("--snowrate") ?? 1),
                        pointsPerCm: pointsPerCm)
snowpack.debugLog = eventLog

if CommandLine.arguments.contains("--selftest") {
    let failures = snowpack.selfTest()
    print(failures.isEmpty ? "selftest: OK" : "selftest FAILED:\n" + failures.joined(separator: "\n"))
    exit(failures.isEmpty ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)             // no Dock icon, no app menu

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
let controller = try Controller(device: device, snowpack: snowpack, tracker: tracker, fps: fps, debug: debug,
                                screens: currentScreens)

let ws = NSWorkspace.shared.notificationCenter
// The Dock's width changes with its items: running apps get icons (launch/quit), and pinning or
// unpinning only shows up in its preferences, so those are re-read every 10 s (one small file read).
for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
    ws.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { if dock.refresh() { snowpack.dockChanged() } }
    }
}
Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
    MainActor.assumeIsolated { if dock.refresh() { snowpack.dockChanged() } }
}
if debug {
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        print(tracker.stats())
        MainActor.assumeIsolated {
            let snow = snowpack.piles.values.reduce(0) { $0 + $1.h.reduce(0, +) } * Snowpack.colW
            print("dock platter:", snowpack.dockRect.map { NSStringFromRect($0) } ?? "none")
            print(String(format: "piles: %d, total snow %.0f pt², awake %d, clumps %d, landing rates %@",
                         snowpack.piles.count, snow, snowpack.piles.values.filter(\.awake).count, snowpack.clumps.count,
                         snowpack.screens.map { String(format: "%.1f/s", $0.landingRate) }.joined(separator: " ")))
        }
    }
}

if let secs = arg("--seconds") {
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { app.terminate(nil) }
}

app.run()
