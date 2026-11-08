// Snowdrift: click-through overlay on every screen with Metal-drawn snow.
// Run: swift run -c release Snowdrift [--seconds N] [--fps F] [--debug] [--lead FRAMES]
//   --seconds N   auto-quit after N seconds (safety net for test runs)
//   --fps F       frame rate cap (default 60)
//   --debug       outline tracked windows (cyan top edge = snow surface), print stats on quit
//   --lead L      predict window position L frames ahead to hide overlay lag (default 1)

import AppKit
import MetalKit

func arg(_ name: String) -> Double? {
    CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil }
}
let fps = Int(arg("--fps") ?? 60)
let debug = CommandLine.arguments.contains("--debug")
let lead = (arg("--lead") ?? 1) / Double(fps)
let tracker = WindowTracker()

@MainActor
func makeOverlay(on screen: NSScreen, device: MTLDevice) throws -> (NSPanel, MTKView, SnowRenderer) {
    let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.level = .statusBar                    // above normal windows and the Dock
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true             // safety: never catch a click
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.layer?.isOpaque = false
    view.preferredFramesPerSecond = fps         // never ProMotion 120
    // Render at 1x instead of Retina 2x: flakes are soft dots, so it looks the same,
    // but each drawable is 4x smaller (GPU memory + compositor work).
    view.autoResizeDrawable = false
    view.drawableSize = screen.frame.size
    (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2     // one fewer full-screen buffer

    // Window bounds use a global top-left origin at the primary screen; Cocoa uses bottom-left.
    let primaryHeight = NSScreen.screens[0].frame.height
    let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
    let renderer = try SnowRenderer(device: device, size: screen.frame.size, screenOrigin: origin,
                                    tracker: tracker, lead: lead, debug: debug)
    view.delegate = renderer
    panel.contentView = view
    panel.orderFrontRegardless()
    return (panel, view, renderer)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)             // no Dock icon, no app menu

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
let overlays = try NSScreen.screens.map { try makeOverlay(on: $0, device: device) }

// Menu bar snowflake: toggle + quit
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowdrift")

final class Actions: NSObject {
    @MainActor @objc func toggle(_ item: NSMenuItem) {
        let on = item.state == .off
        item.state = on ? .on : .off
        for (panel, view, _) in overlays { view.isPaused = !on; on ? panel.orderFrontRegardless() : panel.orderOut(nil) }
        tracker.setRunning(on)
    }
}
let actions = Actions()
let menu = NSMenu()
let toggleItem = NSMenuItem(title: "Snow", action: #selector(Actions.toggle(_:)), keyEquivalent: "")
toggleItem.target = actions
toggleItem.state = .on
menu.addItem(toggleItem)
menu.addItem(.separator())
menu.addItem(NSMenuItem(title: "Quit Snowdrift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
statusItem.menu = menu

// Stop drawing (and window polling) while the displays sleep
let ws = NSWorkspace.shared.notificationCenter
ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { overlays.forEach { $0.1.isPaused = true } }
    tracker.setRunning(false)
}
ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated {
        let on = toggleItem.state == .on
        overlays.forEach { $0.1.isPaused = !on }
        tracker.setRunning(on)
    }
}

if debug {
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        print(tracker.stats())
    }
}

if let secs = arg("--seconds") {
    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { app.terminate(nil) }
}

app.run()
