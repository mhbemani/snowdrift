import AppKit

/// Coordinates the snow on every surface: which surfaces exist this frame (windows, Dock, ground),
/// their piles, window motion, the mouse plow, growth, falling lumps, and the landing maps the GPU
/// uses to stop flakes. The per-pile physics lives on `Pile`; the tunables in `Physics`.
///
/// Cost model (it runs all day):
/// - Falling flakes stay on the GPU. Piles grow from the known landing *rate* (flakes/sec are
///   fixed at startup), as random bumps on whichever surface is exposed at a random x.
/// - Slumping runs at 20 Hz and only on piles still changing; full piles stop growing.
/// - Window physics is a few float operations per window per frame.
/// - The landing map is rebuilt only when something changed.
@MainActor
final class Snowpack {
    private let tracker: WindowTracker
    private let dock: DockInfo
    private let lead: Double
    private let rateScale: Float
    private let pointsPerCm: Float

    private(set) var screens: [ScreenInfo]
    private(set) var surfaces: [Surface] = []
    private(set) var piles: [SurfaceKey: Pile] = [:]
    private(set) var clumps: [Clump] = []
    private(set) var dockRect: CGRect?
    /// Per screen, screen-local: [0, mapSize) = top of the first surface below (landing flakes stop),
    /// [mapSize, 2*mapSize) = ground top (all flakes stop).
    private(set) var maps: [[Float]] = []
    private var owner: [[Int32]] = []         // per screen, index into `mapSurfaces` per landing-map entry
    private var mapSurfaces: [Surface] = []   // surfaces as they were when the maps were built

    private var lastFrame: CFTimeInterval = 0
    private var simTime: Double = 0
    private var lastSurfaces: [SurfaceKey: Surface] = [:]
    private var mapsDirty = true
    private var lastMouse: SIMD2<Float>?
    private var mouseWasDown = false

    /// --log / --debug: print why snow leaves a window.
    var debugLog = false
    private func log(_ msg: @autoclosure () -> String) {
        if debugLog { print(String(format: "[%.2f] ", CACurrentMediaTime()) + msg()) }
    }

    init(tracker: WindowTracker, dock: DockInfo, screens: [ScreenInfo], lead: Double, rateScale: Float, pointsPerCm: Float) {
        self.tracker = tracker; self.dock = dock; self.screens = []
        self.lead = lead; self.rateScale = rateScale; self.pointsPerCm = pointsPerCm
        resetScreens(screens)
    }

    // MARK: Screens and settings

    func dockChanged() { dockRect = dock.platter(on: screens); mapsDirty = true }

    func setLandingRate(_ rate: Float, screen i: Int) {
        if screens.indices.contains(i) { screens[i].landingRate = rate }
    }

    /// Menu bar / Dock sizes changed on the same displays.
    func updateScreenMetrics(_ new: [ScreenInfo]) {
        guard new.count == screens.count else { return resetScreens(new) }
        for i in screens.indices {
            screens[i].menuBar = new[i].menuBar
            screens[i].dockThickness = new[i].dockThickness
        }
        dockChanged()
    }

    /// Displays were added, removed or rearranged. Window snow is kept (global coordinates);
    /// ground and Dock snow start over, since their screens changed.
    func resetScreens(_ new: [ScreenInfo]) {
        let rates = screens.map(\.landingRate)
        screens = new
        for i in screens.indices where i < rates.count { screens[i].landingRate = rates[i] }
        maps = screens.map { _ in Array(repeating: 0, count: 2 * Physics.mapSize) }
        owner = screens.map { _ in Array(repeating: -1, count: Physics.mapSize) }
        for key in piles.keys { if case .window = key { continue }; piles[key] = nil; lastSurfaces[key] = nil }
        surfaces = []; mapSurfaces = []
        dockRect = dock.platter(on: screens)
        mapsDirty = true
    }

    /// Menu: Clear All Snow.
    func clearAll() {
        for p in piles.values { p.clear() }
        clumps.removeAll()
        mapsDirty = true
    }

    // MARK: Frame

    /// Advance to `now`. Every screen's renderer calls this; only the first call per frame works.
    func frame(now: CFTimeInterval) {
        let dt = now - lastFrame
        guard dt > 0.004, !screens.isEmpty else { return }
        lastFrame = now
        let fdt = Float(min(dt, 0.05))

        // Windows are dragged with the mouse: poll them fast from the moment a button goes down.
        let mouseDown = CGEventSource.buttonState(.combinedSessionState, button: .left)   // ~free
        if mouseDown && !mouseWasDown { tracker.mouseWentDown() }
        mouseWasDown = mouseDown

        let (windows, sampled) = tracker.snapshot()
        buildSurfaces(windows: windows, sampled: sampled, now: now)
        syncPiles()
        moveWindowSnow(fdt)
        plow(fdt)
        simTime += min(dt, 0.25)
        while simTime >= Physics.tick {
            simTime -= Physics.tick
            accumulate(Float(Physics.tick))
            slumpAll()
        }
        if !clumps.isEmpty {
            if mapsDirty { buildMaps(); mapsDirty = false }     // lumps must see piles that just lifted off
            stepClumps(fdt)
        }
        if mapsDirty { buildMaps(); mapsDirty = false }
    }

    // MARK: Surfaces

    private func buildSurfaces(windows: [TrackedWindow], sampled: CFTimeInterval, now: CFTimeInterval) {
        let ahead = min(now - sampled, 0.1) + lead
        var next: [Surface] = []
        next.reserveCapacity(windows.count + screens.count + 1)
        let n = Float(max(windows.count, 1))
        // An app in full screen has a window spanning the screen's width from the menu bar line (or
        // the very top) down to the bottom edge, i.e. over the Dock's area. With the Dock showing, no
        // normal window can be sized like that (maximized ones stop above the Dock). Measured on a
        // notched MacBook: full screen = (0, 33, 1470, 923), maximized = (0, 33, 1470, 844).
        let fullScreen = Set(screens.indices.filter { i in
            let s = screens[i]
            return windows.contains { w in
                w.frame.minX <= s.frame.minX + 1 && w.frame.maxX >= s.frame.maxX - 1 &&
                w.frame.maxY >= s.frame.maxY - 1 && w.frame.minY <= s.frame.minY + s.menuBar + 1
            }
        })
        for (i, w) in windows.enumerated() {
            let f = w.frame.offsetBy(dx: w.velocity.dx * ahead, dy: w.velocity.dy * ahead)
            // Skip tops hidden under the menu bar (maximized / full-screen windows).
            guard let s = screens.first(where: { $0.frame.contains(CGPoint(x: f.midX, y: max(f.minY, $0.frame.minY))) }),
                  f.minY > s.frame.minY + s.menuBar + 1 else {
                if piles[.window(w.id)] != nil { log("window \(w.id) skipped as a surface: frame \(f) (no screen / top under menu bar)") }
                continue
            }
            next.append(Surface(key: .window(w.id), x: f.minX, y: f.minY, width: f.width, height: f.height,
                                depth: 0.2 + 0.7 * Float(i) / n, dropsAtEdges: true, maxHeight: Physics.windowMax,
                                radius: Physics.cornerRadius, vx: Float(w.velocity.dx), vy: Float(w.velocity.dy)))
        }
        if let d = dockRect, let ds = screens.firstIndex(where: { $0.dockThickness > 0 }), !fullScreen.contains(ds) {
            next.append(Surface(key: .dock, x: d.minX, y: d.minY, width: d.width, height: d.height, depth: 0.1,
                                dropsAtEdges: true, maxHeight: Physics.dockMax, radius: dock.cornerRadius(on: screens)))
        }
        for (i, s) in screens.enumerated() {
            next.append(Surface(key: .ground(i), x: s.frame.minX, y: s.frame.maxY, width: s.frame.width, height: 0,
                                depth: 0.95, dropsAtEdges: false, maxHeight: Physics.groundMax))
        }
        if next.count != surfaces.count || zip(next, surfaces).contains(where: { $0.key != $1.key || $0.x != $1.x || $0.y != $1.y || $0.width != $1.width }) {
            mapsDirty = true
        }
        surfaces = next
    }

    private func syncPiles() {
        var seen = Set<SurfaceKey>()
        for s in surfaces {
            seen.insert(s.key)
            let cols = Int(Float(s.width) / Physics.colW)
            if let p = piles[s.key] {
                let before = p.h.count
                let cut = p.resize(to: cols)                     // shrunk: the cut-off part falls
                if cut > 0 {
                    spawnClumps(mass: cut, x0: Float(s.x) + Float(p.h.count) * Physics.colW,
                                width: Float(before - p.h.count) * Physics.colW, y: Float(s.y))
                }
                if before != p.h.count { mapsDirty = true }
            } else {
                piles[s.key] = Pile(columns: cols)
            }
            lastSurfaces[s.key] = s
        }
        // Window closed, minimized or moved to another Space: its snow falls.
        for key in piles.keys where !seen.contains(key) {
            guard case .window = key else { continue }              // Dock hidden in full screen keeps its snow
            if let p = piles[key], let s = lastSurfaces[key] {
                log("window \(key) no longer a surface: \(Int(p.mass)) pt² of snow falls")
                spawnClumps(mass: p.mass, x0: Float(s.x), width: Float(p.h.count) * Physics.colW, y: Float(s.y))
            }
            piles[key] = nil; lastSurfaces[key] = nil; mapsDirty = true
        }
    }

    // MARK: Window motion

    private func moveWindowSnow(_ dt: Float) {
        let maxThrowSpeed = (2 * Physics.slabGravity * Physics.maxThrowCm * pointsPerCm).squareRoot()
        for s in surfaces {
            guard case .window = s.key, let p = piles[s.key] else { continue }
            let wasLifted = p.lift > 0
            if p.stepSlab(yw: Float(s.y), vw: s.vy, dt: dt, maxThrowSpeed: maxThrowSpeed) == nil {
                log("window \(s.key) slab broke: lift \(Int(p.lift)) pt, slab speed \(Int(p.slabV)) pt/s, window speed \(Int(s.vy)) pt/s")
                breakApart(p, s)
            }
            if wasLifted || p.lift > 0 { mapsDirty = true }
            if p.contact { p.slideOffset += p.stepSideways(vx: s.vx, dt: dt) }
            if p.applySlide() {
                log("window \(s.key) snow slid (snow speed \(Int(p.us)), window \(Int(s.vx)) pt/s)")
                mapsDirty = true
                spillEdges(p, s, vx: p.us)
            }
        }
    }

    /// A broken slab becomes lumps, each a little different so they spread apart. Lumps fall under
    /// lighter gravity than the slab, so their upward speed is capped to what's left of maxThrowCm.
    private func breakApart(_ p: Pile, _ s: Surface) {
        let room = max(0, Physics.maxThrowCm * pointsPerCm - p.lift)
        let minVy = -(2 * Physics.gravity * room).squareRoot()
        let (vx, vy) = (p.us, p.slabV)
        let budget = max(1, Physics.maxClumps - clumps.count)
        let group = max(3, Int((Float(p.h.count) / Float(budget)).rounded(.up)))
        for c in p.breakIntoChunks(on: s, group: group) {
            addClump(x: c.x, y: c.y, vx: vx + Float.random(in: -30...30), vy: max(minVy, vy + Float.random(in: -25...5)),
                     mass: c.mass, gk: Float.random(in: 0.75...1.25))
        }
        mapsDirty = true
    }

    /// Snow gathered past a pile's ends becomes a falling lump once there's enough of it.
    private func spillEdges(_ p: Pile, _ s: Surface, vx: Float) {
        if p.edgeLoss.left > Physics.clumpMass {
            addClump(x: Float(s.x) - 2, y: Float(s.y) - p.lift - 3, vx: min(0, vx), vy: 0, mass: p.edgeLoss.left)
            p.edgeLoss.left = 0
        }
        if p.edgeLoss.right > Physics.clumpMass {
            addClump(x: Float(s.x + s.width) + 2, y: Float(s.y) - p.lift - 3, vx: max(0, vx), vy: 0, mass: p.edgeLoss.right)
            p.edgeLoss.right = 0
        }
    }

    // MARK: Mouse plow

    /// Costs one mouse read per frame; nothing else unless the cursor's circle moved through snow.
    private func plow(_ dt: Float) {
        let loc = NSEvent.mouseLocation                       // Cocoa: bottom-left origin of the primary screen
        let m = SIMD2(Float(loc.x), Float(screens[0].frame.height - loc.y))
        defer { lastMouse = m }
        guard let prev = lastMouse, abs(m.x - prev.x) > 0.01 else { return }
        let r = Physics.plowRadius

        // Front to back: the Dock, then windows, then the ground. A window or the Dock under the
        // cursor hides any snow behind it, so stop there.
        let order = surfaces.filter { $0.key == .dock } + surfaces.filter { $0.key != .dock }
        for s in order {
            let sx = Float(s.x), w = Float(s.width), sy = Float(s.y)
            if s.height > 0 && m.x >= sx && m.x < sx + w && m.y >= sy && m.y < sy + Float(s.height) { return }
            guard m.x + r >= sx, m.x - r < sx + w, let p = piles[s.key] else { continue }
            guard m.y - r <= sy - p.lift,                            // the circle reaches above the base
                  let result = p.plow(on: s, fromX: prev.x, fromY: prev.y, toX: m.x, toY: m.y) else { continue }
            mapsDirty = true
            if result.spill > 0 {                                   // pushed off an end: lumps keep some swing
                let vx = max(-300, min(300, (m.x - prev.x) / max(dt, 0.001) * 0.6))
                let lumps = min(6, max(1, Int(result.spill / (2 * Physics.clumpMass))))
                for _ in 0..<lumps {
                    addClump(x: result.rightEnd ? sx + w + 2 : sx - 2, y: sy - p.lift - 3,
                             vx: vx + Float.random(in: -30...30), vy: Float.random(in: -40 ... -10),
                             mass: result.spill / Float(lumps), gk: Float.random(in: 0.75...1.25))
                }
            }
            return
        }
    }

    // MARK: Growth and slumping (20 Hz)

    private func accumulate(_ dt: Float) {
        for (si, s) in screens.enumerated() where s.landingRate > 0 {
            // Volume per landing chosen so exposed snow rises 10 pt in `fillTime` seconds.
            let volume = (10 / Physics.fillTime) * Float(s.frame.width) / s.landingRate
            let expected = s.landingRate * dt * rateScale
            var count = Int(expected)
            if Float.random(in: 0..<1) < expected - Float(count) { count += 1 }
            for _ in 0..<count {
                let j = Int.random(in: 0..<Physics.mapSize)
                let k = Int(owner[si][j])
                guard k >= 0, k < mapSurfaces.count, let pile = piles[mapSurfaces[k].key] else { continue }
                // Full = average height reached (not every column at the cap, which looks flat).
                guard pile.mean < Physics.fullAt * mapSurfaces[k].maxHeight else { continue }
                let x = Float(s.frame.minX) + (Float(j) + Float.random(in: 0..<1)) * Float(s.frame.width) / Float(Physics.mapSize)
                pile.deposit(col: Int((x - Float(mapSurfaces[k].x)) / Physics.colW), mass: volume)
                mapsDirty = true
            }
        }
    }

    private func slumpAll() {
        for s in surfaces {
            guard let p = piles[s.key], p.awake else { continue }
            if p.slump(on: s) { mapsDirty = true }
            if s.dropsAtEdges { spillEdges(p, s, vx: 0) }
        }
    }

    // MARK: Lumps

    private func spawnClumps(mass: Float, x0: Float, width: Float, y: Float) {
        guard mass > 1 else { return }
        let n = max(1, min(24, Int(mass / Physics.clumpMass)))
        for i in 0..<n {
            addClump(x: x0 + (Float(i) + Float.random(in: 0..<1)) * width / Float(n), y: y - 3, mass: mass / Float(n))
        }
    }

    private func addClump(x: Float, y: Float, vx: Float = 0, vy: Float = 0, mass: Float, gk: Float = 1) {
        guard clumps.count < Physics.maxClumps, x.isFinite, y.isFinite else { return }
        clumps.append(Clump(x: x, y: y, vx: vx, vy: vy, mass: mass, size: min(8, max(2.5, sqrt(mass) * 0.9)), gk: gk,
                            reach: Float.random(in: Physics.lumpReachCm) * pointsPerCm))
    }

    private func stepClumps(_ dt: Float) {
        var i = 0
        while i < clumps.count {
            var c = clumps[i]
            c.vy = min(c.vy + Physics.gravity * c.gk * dt, Physics.maxFall)
            c.vx *= 1 - min(1, 1.5 * dt)                            // air drag
            c.x += c.vx * dt
            c.y += c.vy * dt
            if c.vy > 0 { c.fallen += c.vy * dt }
            clumps[i] = c
            var done = true
            if c.fallen >= c.reach {
                // faded out before reaching anything
            } else if let si = screens.firstIndex(where: { Float($0.frame.minX) <= c.x && c.x < Float($0.frame.maxX) }) {
                let s = screens[si]
                let j = min(Physics.mapSize - 1, max(0, Int((c.x - Float(s.frame.minX)) / Float(s.frame.width) * Float(Physics.mapSize))))
                let landY = maps[si][j] + Float(s.frame.minY)
                // Land only when falling onto a surface from just above it. A lump that's deep below a
                // surface line is in front of that window's face, so it keeps falling.
                if c.vy > 0 && c.y >= landY && c.y - landY < max(20, c.vy * dt * 2) {
                    let k = Int(owner[si][j])
                    if k >= 0, k < mapSurfaces.count, let pile = piles[mapSurfaces[k].key] {
                        pile.deposit(col: Int((c.x - Float(mapSurfaces[k].x)) / Physics.colW), mass: c.mass * c.alpha)
                        mapsDirty = true
                    }
                } else if c.y < Float(s.frame.maxY) + 20 {
                    done = false
                }
            }
            if done { clumps.swapAt(i, clumps.count - 1); clumps.removeLast() } else { i += 1 }
        }
    }

    // MARK: Landing maps

    private func buildMaps() {
        mapSurfaces = surfaces
        for (si, s) in screens.enumerated() {
            let step = Float(s.frame.width) / Float(Physics.mapSize)
            let left = Float(s.frame.minX), top = Float(s.frame.minY)
            for j in 0..<Physics.mapSize { maps[si][j] = .infinity; owner[si][j] = -1 }
            for (k, surf) in surfaces.enumerated() {
                if case .ground(let g) = surf.key, g != si { continue }
                guard let p = piles[surf.key] else { continue }
                let sx = Float(surf.x), sw = Float(surf.width)
                let j0 = max(0, Int(ceil((sx - left) / step - 0.5)))
                let j1 = min(Physics.mapSize - 1, Int(floor((sx + sw - left) / step - 0.5)))
                guard j0 <= j1 else { continue }
                let isGround = { if case .ground = surf.key { return true } else { return false } }()
                for j in j0...j1 {
                    let x = left + (Float(j) + 0.5) * step
                    let col = min(p.h.count - 1, max(0, Int((x - sx) / Physics.colW)))
                    let y = Float(surf.y) + surf.drop(column: col) - p.lift - p.h[col] - top
                    if y < maps[si][j] { maps[si][j] = y; owner[si][j] = Int32(k) }
                    if isGround { maps[si][Physics.mapSize + j] = y }
                }
            }
        }
    }
}
