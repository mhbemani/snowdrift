import AppKit
import MetalKit
import ServiceManagement

/// Menu bar, settings, pause rules, displays and the Dock.
///
/// Pausing: drawing *and* window polling stop entirely (0 CPU) while any reason holds: snow turned
/// off, displays asleep, screen locked, screensaver running, no display. Low Power Mode halves the
/// frame rate.
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

    enum PauseReason: Hashable { case off, asleep, locked, screensaver, noDisplay }

    private let gpu: GPU
    private let dock: DockInfo
    private let snowpack: Snowpack
    private let tracker: WindowTracker
    private let baseFPS: Int
    private let screens: () -> [ScreenInfo]
    private var overlays: [(panel: NSPanel, view: MTKView, renderer: SnowRenderer)] = []
    private var pauseReasons: Set<PauseReason> = []
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

    init(gpu: GPU, dock: DockInfo, snowpack: Snowpack, tracker: WindowTracker, fps: Int,
         screens: @escaping () -> [ScreenInfo]) throws {
        self.gpu = gpu; self.dock = dock; self.snowpack = snowpack; self.tracker = tracker
        self.baseFPS = fps; self.screens = screens
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
        let infos = screens()
        snowpack.resetScreens(infos)
        // NSScreen.screens can be momentarily empty while displays reconfigure: wait for the next change.
        if infos.isEmpty { pauseReasons.insert(.noDisplay) } else { pauseReasons.remove(.noDisplay) }
        for (i, screen) in NSScreen.screens.enumerated() where i < infos.count {
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

        let view = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size), device: gpu.device)
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
        view.depthStencilPixelFormat = GPU.depthFormat
        view.depthStencilStorageMode = gpu.device.supportsFamily(.apple1) ? .memoryless : .private
        view.clearDepth = 1

        let renderer = try SnowRenderer(gpu: gpu, size: screen.frame.size, screenIndex: index,
                                        snowpack: snowpack, tracker: tracker,
                                        density: snowfall.density, wind: wind.speed)
        snowpack.setLandingRate(renderer.landingRate, screen: index)
        view.delegate = renderer
        panel.contentView = view
        panel.orderFrontRegardless()
        return (panel, view, renderer)
    }

    // MARK: Pause rules

    private var currentFPS: Int { ProcessInfo.processInfo.isLowPowerModeEnabled ? min(baseFPS, 30) : baseFPS }

    private func setPaused(_ reason: PauseReason, _ on: Bool) {
        if on { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        applyPause()
    }

    private func applyPause() {
        let paused = !pauseReasons.isEmpty
        for o in overlays {
            o.view.isPaused = paused
            o.view.preferredFramesPerSecond = currentFPS
            if pauseReasons.contains(.off) { o.panel.orderOut(nil) } else { o.panel.orderFrontRegardless() }
        }
        tracker.setRunning(!paused)
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(.asleep, true) }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setPaused(.asleep, false) }
        }
        // Lock screen and screensaver are only announced as distributed notifications.
        let dn = DistributedNotificationCenter.default()
        // Anyone can post these, but the worst a fake one can do is pause or resume the snow.
        let events: [(String, PauseReason, Bool)] = [
            ("com.apple.screenIsLocked", .locked, true), ("com.apple.screenIsUnlocked", .locked, false),
            ("com.apple.screensaver.didstart", .screensaver, true), ("com.apple.screensaver.didstop", .screensaver, false)]
        for (name, reason, on) in events {
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
        // The Dock's width changes with its items: running apps get icons (launch/quit), and pinning or
        // unpinning only shows up in its preferences, so those are re-read every 10 s (one small file read).
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDock() }
            }
        }
        dockTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDock() }
        }
    }

    private var dockTimer: Timer?

    private func refreshDock() {
        if dock.refresh() { snowpack.dockChanged() }
    }

    private func screensChanged() {
        let new = screens()
        if !new.isEmpty, new.map(\.frame) == snowpack.screens.map(\.frame) {
            snowpack.updateScreenMetrics(new)                  // same displays: just Dock / menu bar sizes
        } else {
            do { try buildOverlays() } catch { NSLog("Snowdrift: rebuilding overlays failed: \(error)") }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        let snow = item("Snow", #selector(toggleSnow(_:)))
        snow.state = pauseReasons.contains(.off) ? .off : .on
        menu.addItem(snow)
        menu.addItem(.separator())
        menu.addItem(submenu("Snowfall", Snowfall.allCases.map { ($0.title, $0.rawValue, $0 == snowfall) }, #selector(pickSnowfall(_:))))
        menu.addItem(submenu("Wind", Wind.allCases.map { ($0.title, $0.rawValue, $0 == wind) }, #selector(pickWind(_:))))
        menu.addItem(item("Clear All Snow", #selector(clearSnow)))
        let hide = item("Hide from Screen Sharing", #selector(toggleHide(_:)))
        hide.state = hideFromSharing ? .on : .off
        menu.addItem(hide)
        // Login items are only allowed for a real app bundle (not `swift run`).
        if Bundle.main.bundleURL.pathExtension == "app" {
            let login = item("Launch at Login", #selector(toggleLogin(_:)))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
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
        setPaused(.off, sender.state == .on)
        sender.state = pauseReasons.contains(.off) ? .off : .on
    }

    @objc private func pickSnowfall(_ sender: NSMenuItem) {
        guard let choice = Snowfall(rawValue: sender.tag) else { return }
        snowfall = choice
        for (i, o) in overlays.enumerated() { snowpack.setLandingRate(o.renderer.setDensity(choice.density), screen: i) }
        buildMenu()
    }

    @objc private func pickWind(_ sender: NSMenuItem) {
        guard let choice = Wind(rawValue: sender.tag) else { return }
        wind = choice
        for o in overlays { o.renderer.wind = choice.speed }
        buildMenu()
    }

    @objc private func clearSnow() { snowpack.clearAll() }

    /// Registers / removes Snowdrift as a login item (macOS shows it in System Settings → General →
    /// Login Items, where it can also be turned off).
    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSLog("Snowdrift: launch at login failed: \(error)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        buildMenu()
    }

    @objc private func toggleHide(_ sender: NSMenuItem) {
        hideFromSharing.toggle()
        for o in overlays { o.panel.sharingType = hideFromSharing ? .none : .readOnly }
        buildMenu()
    }
}
