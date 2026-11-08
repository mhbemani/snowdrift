import AppKit
import MetalKit

/// Menu bar, settings, pause rules and displays.
///
/// Pausing: drawing *and* window polling stop entirely (0 CPU) while any reason holds: snow turned
/// off, displays asleep, screen locked, screensaver running. Low Power Mode halves the frame rate.
@MainActor
final class Controller: NSObject {
    enum Snowfall: Int, CaseIterable { case light, medium, heavy
        var title: String { ["Light", "Medium", "Heavy"][rawValue] }
        var density: Float { [0.5, 1, 1.8][rawValue] }
    }
    enum Wind: Int, CaseIterable { case calm, breeze, windy
        var title: String { ["Calm", "Breeze", "Windy"][rawValue] }
        var speed: Float { [0, 6, 24][rawValue] }       // pt/s sideways
    }

    private let device: MTLDevice
    private let snowpack: Snowpack
    private let tracker: WindowTracker
    private let baseFPS: Int
    private let debug: Bool
    private let screens: () -> [ScreenInfo]
    private var overlays: [(panel: NSPanel, view: MTKView, renderer: SnowRenderer)] = []
    private var pauseReasons: Set<String> = []
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let defaults = UserDefaults.standard

    private var snowfall: Snowfall {
        get { Snowfall(rawValue: defaults.object(forKey: "snowfall") as? Int ?? 1) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "snowfall") }
    }
    private var wind: Wind {
        get { Wind(rawValue: defaults.object(forKey: "wind") as? Int ?? 1) ?? .breeze }
        set { defaults.set(newValue.rawValue, forKey: "wind") }
    }
    /// Keep the snow out of screen shares and recordings (on by default).
    private var hideFromSharing: Bool {
        get { defaults.object(forKey: "hideFromSharing") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hideFromSharing") }
    }

    init(device: MTLDevice, snowpack: Snowpack, tracker: WindowTracker, fps: Int, debug: Bool,
         screens: @escaping () -> [ScreenInfo]) throws {
        self.device = device; self.snowpack = snowpack; self.tracker = tracker
        self.baseFPS = fps; self.debug = debug; self.screens = screens
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowdrift")
        try buildOverlays()
        buildMenu()
        observeSystem()
    }

    // MARK: Overlays (one per display)

    private func buildOverlays() throws {
        for o in overlays { o.view.isPaused = true; o.view.delegate = nil; o.panel.orderOut(nil); o.panel.close() }
        overlays = []
        snowpack.resetScreens(screens())
        for (i, screen) in NSScreen.screens.enumerated() {
            overlays.append(try makeOverlay(on: screen, index: i))
        }
        applyPause()
    }

    private func makeOverlay(on screen: NSScreen, index: Int) throws -> (NSPanel, MTKView, SnowRenderer) {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar                    // above normal windows and the Dock
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true             // safety: never catch a click
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = hideFromSharing ? .none : .readOnly
        panel.isReleasedWhenClosed = false

        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = currentFPS
        // Render at 1x instead of Retina 2x: flakes are soft dots, so it looks the same,
        // but each drawable is 4x smaller (GPU memory + compositor work).
        view.autoResizeDrawable = false
        view.drawableSize = screen.frame.size
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2     // one fewer full-screen buffer
        // Depth buffer for window occlusion: memoryless on Apple GPUs = lives in tile memory, no RAM.
        view.depthStencilPixelFormat = SnowRenderer.depthFormat
        view.depthStencilStorageMode = device.supportsFamily(.apple1) ? .memoryless : .private
        view.clearDepth = 1

        let renderer = try SnowRenderer(device: device, size: screen.frame.size, screenIndex: index,
                                        snowpack: snowpack, tracker: tracker,
                                        density: snowfall.density, wind: wind.speed, debug: debug)
        snowpack.screens[index].landingRate = renderer.landingRate
        view.delegate = renderer
        panel.contentView = view
        panel.orderFrontRegardless()
        return (panel, view, renderer)
    }

    // MARK: Pause rules

    private var currentFPS: Int { ProcessInfo.processInfo.isLowPowerModeEnabled ? min(baseFPS, 30) : baseFPS }

    private func setPaused(_ reason: String, _ on: Bool) {
        if on { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        applyPause()
    }

    private func applyPause() {
        let paused = !pauseReasons.isEmpty
        for o in overlays {
            o.view.isPaused = paused
            o.view.preferredFramesPerSecond = currentFPS
            if pauseReasons.contains("off") { o.panel.orderOut(nil) } else { o.panel.orderFrontRegardless() }
        }
        tracker.setRunning(!paused)
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused("asleep", true) }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused("asleep", false) }
        }
        // Lock screen and screensaver are only announced as distributed notifications.
        let dn = DistributedNotificationCenter.default()
        for (name, reason, on) in [("com.apple.screenIsLocked", "locked", true), ("com.apple.screenIsUnlocked", "locked", false),
                                   ("com.apple.screensaver.didstart", "screensaver", true),
                                   ("com.apple.screensaver.didstop", "screensaver", false)] {
            dn.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(reason, on) }
            }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPause() }
        }
        // Displays: plugged in, removed, rearranged, or a menu bar / Dock size change.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func screensChanged() {
        let new = screens()
        if new.map(\.frame) == snowpack.screens.map(\.frame) {
            snowpack.updateScreenMetrics(new)                  // same displays: just Dock / menu bar sizes
        } else {
            do { try buildOverlays() } catch { NSLog("Snowdrift: rebuilding overlays failed: \(error)") }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        let snow = item("Snow", #selector(toggleSnow(_:)))
        snow.state = pauseReasons.contains("off") ? .off : .on
        menu.addItem(snow)
        menu.addItem(.separator())
        menu.addItem(submenu("Snowfall", Snowfall.allCases.map { ($0.title, $0.rawValue, $0 == snowfall) }, #selector(pickSnowfall(_:))))
        menu.addItem(submenu("Wind", Wind.allCases.map { ($0.title, $0.rawValue, $0 == wind) }, #selector(pickWind(_:))))
        menu.addItem(item("Clear All Snow", #selector(clearSnow)))
        let hide = item("Hide from Screen Sharing", #selector(toggleHide(_:)))
        hide.state = hideFromSharing ? .on : .off
        menu.addItem(hide)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snowdrift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ choices: [(String, Int, Bool)], _ action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (name, tag, selected) in choices {
            let i = item(name, action)
            i.tag = tag
            i.state = selected ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func toggleSnow(_ sender: NSMenuItem) {
        setPaused("off", sender.state == .on)
        sender.state = pauseReasons.contains("off") ? .off : .on
    }

    @objc private func pickSnowfall(_ sender: NSMenuItem) {
        guard let choice = Snowfall(rawValue: sender.tag) else { return }
        snowfall = choice
        for (i, o) in overlays.enumerated() where i < snowpack.screens.count {
            snowpack.screens[i].landingRate = o.renderer.setDensity(choice.density)
        }
        buildMenu()
    }

    @objc private func pickWind(_ sender: NSMenuItem) {
        guard let choice = Wind(rawValue: sender.tag) else { return }
        wind = choice
        for o in overlays { o.renderer.wind = choice.speed }
        buildMenu()
    }

    @objc private func clearSnow() { snowpack.clearAll() }

    @objc private func toggleHide(_ sender: NSMenuItem) {
        hideFromSharing.toggle()
        for o in overlays { o.panel.sharingType = hideFromSharing ? .none : .readOnly }
        buildMenu()
    }
}
