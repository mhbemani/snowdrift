import AppKit

/// One screen, in global top-left coordinates (points, y down).
struct ScreenInfo {
    var frame: CGRect
    var menuBar: CGFloat          // height of the menu bar strip at the top
    var dockThickness: CGFloat    // Dock area at the bottom (0 if hidden or on the side)
    var landingRate: Float = 0    // landing flakes per second reaching the ground line (set by renderer)
}

enum SurfaceKey: Hashable { case window(CGWindowID), dock, ground(Int) }

/// Something snow can sit on, this frame. Snow sits *above* `y`.
struct Surface {
    var key: SurfaceKey
    var x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat   // global; y = top edge
    var depth: Float                             // 0 = nearest; windows front to back
    var dropsAtEdges: Bool                       // ground is held by the screen edges
    var maxHeight: Float
    var radius: Float = 0                        // rounded top corners: the edge curves down
    var vx: Float = 0, vy: Float = 0             // window velocity (pt/s, smoothed by the tracker)

    /// How far the top edge has curved down at local x (0 in the flat middle).
    func drop(_ x: Float) -> Float {
        let d = min(x, Float(width) - x)
        guard d < radius else { return 0 }
        let e = radius - max(0, d)
        return radius - (radius * radius - e * e).squareRoot()
    }
    func drop(column c: Int) -> Float { drop((Float(c) + 0.5) * Snowpack.colW) }
}

/// Snow height in columns of `Snowpack.colW` points, anchored to the surface's left edge,
/// so piles ride along with windows for free.
final class Pile {
    var h: [Float]
    var awake = true
    var edgeLoss: (left: Float, right: Float) = (0, 0)
    var slideOffset: Float = 0     // sub-column slide not yet applied
    // Window piles move as one slab (see Snowpack.stepSlab):
    var contact = true             // resting on its window
    var slabReady = false
    var ghostY: Float = 0, ghostV: Float = 0   // where free-flying snow would be now (y down)
    var slabY: Float = 0, slabV: Float = 0     // the slab's own position/speed while in the air
    var lift: Float = 0            // how far above the window top the slab is (drawn and landed on)
    // Sideways friction (see Snowpack.stepSideways):
    var us: Float = 0              // the snow's own sideways speed
    var wvx: Float = 0             // the window's sideways speed, smoothed (jitter-free)
    var sliding = false            // static friction broke; kinetic friction is slowing the slide
    var sideReady = false
    /// Compaction per column, 0…1, from the mouse plow. Empty until the pile is first pushed
    /// (most piles never are), and emptied again once it has settled.
    var packed: [Float] = []
    init(columns: Int) { h = Array(repeating: 0, count: columns) }
}

/// A free-flying lump of snow: thrown off a window, slid off an edge, or left by a closed window.
/// CPU particle; there are none most of the time, and never more than `maxClumps`.
struct Clump {
    var x, y, vx, vy, mass, size, gk: Float    // gk: per-lump gravity factor (air drag varies)
    var fallen: Float = 0                       // downward distance travelled
    var reach: Float                            // fully gone after falling this far (pt)
    /// Lumps thin out as they fall and are gone after `reach`; each has its own reach, so they
    /// vanish one by one rather than together.
    var alpha: Float {
        let t = max(0, min(1, (fallen - 0.35 * reach) / (0.65 * reach)))
        return 1 - t * t * (3 - 2 * t)
    }
}

/// Owns the piles and does all snow-on-surface physics.
///
/// Cost model (it runs all day):
/// - Falling flakes stay on the GPU. Piles grow from the known landing *rate* (flakes/sec are
///   fixed at startup), as random bumps on whichever surface is exposed at a random x.
/// - Piles are height maps; slumping is a cheap sand-pile rule at 20 Hz, only on piles still changing.
/// - A pile stops growing once its average height reaches `fullAt` of its max (it stays lumpy, not
///   flat), so full piles stop changing (and stop costing).
/// - Window physics is a few float operations per window per frame.
/// - The landing map the GPU uses to stop flakes is rebuilt only when something changed.
///
/// Physics: a window's snow is one slab. It rests on the window until the window gets ahead of
/// where free-flying snow could be (window dropped away, or stopped while carrying the snow up).
/// Then it flies on its own and lands back; only a big lift (a fast flick) breaks it into lumps.
/// This is position-based on purpose: window position samples are jittery (measured: a steady
/// 400 pt/s move reads as 3, 10, 6, 7, 3, 11 pt per 60 Hz sample), so velocity differences
/// (acceleration) swing ±10,000 pt/s² and can't be trusted. A gap only counts once it exceeds one
/// sample's worth of motion. Sideways, friction pulls the snow's speed toward the window's.
@MainActor
final class Snowpack {
    nonisolated static let colW: Float = 2
    static let mapSize = 512                  // landing map entries per screen (GPU limit: 4 KB for both maps)
    static let maxClumps = 800
    private let tick: Double = 1.0 / 20
    private let fillTime: Float = 1067        // seconds for exposed snow to rise 10 pt (≈ 11 min to a window's full cover)
    private let fullAt: Float = 0.6           // a pile stops growing at this share of its max height, *on average*:
                                              // it stays lumpy instead of filling every column up to a flat top
    private let maxSlope: Float = 1.0         // max height difference between neighbour columns
    private let clumpMass: Float = 8          // pt² of snow that leaves an edge as one clump
    // Calibration knobs for the feel of the physics:
    private let gravity: Float = 900          // pt/s², falling lumps (loose snow, slowed by air)
    private let slabGravity: Float = 3000     // pt/s², snow resting on a window: hop = speed²/(2·this),
                                              // so stopping at 400 pt/s throws it ~27 pt
    private let breakLift: Float = 40         // a slab lifted higher than this breaks into lumps
    private let maxThrowCm: Float = 10        // snow thrown up by a stopping window rises at most this high
    private let staticFriction: Float = 0.7   // sideways: snow sticks while the window accelerates ≤ this·g
    private let kineticFriction: Float = 0.5  // once slipping, the slide slows at this·g
    private let sideSmoothing: Float = 0.08   // s; window speed is smoothed this much first (sample jitter)
    private let plowRadius: Float = 10        // the cursor pushes snow with a circle this big (pt)
    private let packedHeight: Float = 1.4     // pushed snow can stand this much taller than a normal pile
    private let packedSettle: Float = 0.995   // per 20 Hz tick: packed snow loosens over ~10 s
    // ponytail: one radius for every window. macOS 26 uses ~16 pt (plain) to ~26 pt (toolbar);
    // the real radius isn't exposed without reading pixels.
    static let cornerRadius: Float = 20

    private let tracker: WindowTracker
    private let dock: DockInfo
    private let lead: Double
    private let rateScale: Float
    private let pointsPerCm: Float

    var screens: [ScreenInfo]
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
    /// --debug: print why snow leaves a window (removed window, broken slab, slide).
    var debugLog = false
    private func log(_ msg: @autoclosure () -> String) {
        if debugLog { print(String(format: "[%.2f] ", CACurrentMediaTime()) + msg()) }
    }

    init(tracker: WindowTracker, dock: DockInfo, screens: [ScreenInfo], lead: Double, rateScale: Float, pointsPerCm: Float) {
        self.tracker = tracker; self.dock = dock; self.screens = screens
        self.lead = lead; self.rateScale = rateScale; self.pointsPerCm = pointsPerCm
        maps = screens.map { _ in Array(repeating: 0, count: 2 * Self.mapSize) }
        owner = screens.map { _ in Array(repeating: -1, count: Self.mapSize) }
        dockRect = dock.platter(on: screens)
    }

    func dockChanged() { dockRect = dock.platter(on: screens); mapsDirty = true }

    /// Menu bar / Dock sizes changed. Same screens only: a display added or removed needs a restart.
    // ponytail: no hot-plugging of displays yet (M5).
    func updateScreenMetrics(_ new: [ScreenInfo]) {
        guard new.count == screens.count else { return }
        for i in screens.indices {
            screens[i].menuBar = new[i].menuBar
            screens[i].dockThickness = new[i].dockThickness
        }
        dockChanged()
    }

    /// Advance to `now`. Every screen's renderer calls this; only the first call per frame works.
    func frame(now: CFTimeInterval) {
        let dt = now - lastFrame
        guard dt > 0.004 else { return }
        lastFrame = now
        let fdt = Float(min(dt, 0.05))

        let (windows, sampled) = tracker.snapshot()
        buildSurfaces(windows: windows, sampled: sampled, now: now)
        syncPiles()
        moveSlabs(fdt)
        slide()
        plow(fdt)
        simTime += min(dt, 0.25)
        while simTime >= tick {
            simTime -= tick
            accumulate(Float(tick))
            slump()
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
                                depth: 0.2 + 0.7 * Float(i) / n, dropsAtEdges: true, maxHeight: 10, radius: Self.cornerRadius,
                                vx: Float(w.velocity.dx), vy: Float(w.velocity.dy)))
        }
        if let d = dockRect, let ds = screens.firstIndex(where: { $0.dockThickness > 0 }), !fullScreen.contains(ds) {
            next.append(Surface(key: .dock, x: d.minX, y: d.minY, width: d.width, height: d.height, depth: 0.1,
                                dropsAtEdges: true, maxHeight: 8, radius: dock.cornerRadius(on: screens)))
        }
        for (i, s) in screens.enumerated() {
            next.append(Surface(key: .ground(i), x: s.frame.minX, y: s.frame.maxY, width: s.frame.width, height: 0,
                                depth: 0.95, dropsAtEdges: false, maxHeight: 24))
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
            let cols = max(1, Int(Float(s.width) / Self.colW))
            if let p = piles[s.key] {
                if p.h.count > cols {                         // shrunk: the cut-off part falls
                    let cut = p.h[cols...].reduce(0, +) * Self.colW
                    spawnClumps(mass: cut, x0: Float(s.x) + Float(cols) * Self.colW, width: Float(p.h.count - cols) * Self.colW,
                                y: Float(s.y))
                    p.h.removeLast(p.h.count - cols); p.packed = []; p.awake = true; mapsDirty = true
                } else if p.h.count < cols {
                    p.h.append(contentsOf: repeatElement(0, count: cols - p.h.count)); p.packed = []; p.awake = true; mapsDirty = true
                }
            } else {
                piles[s.key] = Pile(columns: cols)
            }
            lastSurfaces[s.key] = s
        }
        // Window closed, minimized or moved to another Space: its snow falls.
        for key in piles.keys where !seen.contains(key) {
            guard case .window = key else { continue }              // Dock hidden in full screen keeps its snow
            if let p = piles[key], let s = lastSurfaces[key] {
                log("window \(key) no longer a surface: \(Int(p.h.reduce(0, +) * Self.colW)) pt² of snow falls")
                spawnClumps(mass: p.h.reduce(0, +) * Self.colW, x0: Float(s.x), width: Float(p.h.count) * Self.colW, y: Float(s.y))
            }
            piles[key] = nil; lastSurfaces[key] = nil; mapsDirty = true
        }
    }

    // MARK: Window motion

    /// One step of a window's snow slab. Returns the lift (pt above the window top), or nil if the
    /// slab broke apart. `yw` = window top (y down), `vw` = its vertical speed, both from the tracker.
    func stepSlab(_ p: Pile, yw: Float, vw: Float, dt: Float) -> Float? {
        if !p.slabReady { p.ghostY = yw; p.ghostV = vw; p.slabReady = true }
        if p.contact {
            // Where the snow would be if nothing held it. While the window is at or above that
            // path it's still carrying the snow; reset the path to the window.
            p.ghostV = min(p.ghostV + slabGravity * dt, 2000)
            p.ghostY += p.ghostV * dt
            if yw <= p.ghostY {
                p.ghostY = yw; p.ghostV = vw
            } else if yw - p.ghostY > 3 + 1.2 * abs(vw) / 60 {      // more than one sample of jitter
                p.contact = false
                p.slabY = yw
                // Leaves with the snow's speed, but never fast enough to rise more than maxThrowCm.
                p.slabV = max(p.ghostV, -(2 * slabGravity * maxThrowCm * pointsPerCm).squareRoot())
            }
            p.lift = 0
            return 0
        }
        p.slabV = min(p.slabV + slabGravity * dt, 2000)
        p.slabY += p.slabV * dt
        if p.slabY >= yw {                                          // landed back on the window
            p.contact = true; p.ghostY = yw; p.ghostV = vw; p.lift = 0
            return 0
        }
        p.lift = yw - p.slabY
        return p.lift > breakLift ? nil : p.lift
    }

    private func moveSlabs(_ dt: Float) {
        for s in surfaces {
            guard case .window = s.key, let p = piles[s.key] else { continue }
            let wasLifted = p.lift > 0
            if stepSlab(p, yw: Float(s.y), vw: s.vy, dt: dt) == nil {
                log("window \(s.key) slab broke: lift \(Int(p.lift)) pt, slab speed \(Int(p.slabV)) pt/s, window speed \(Int(s.vy)) pt/s")
                breakApart(p, s, velocity: [p.us, p.slabV])
            }
            if wasLifted || p.lift > 0 { mapsDirty = true }

            if p.contact { p.slideOffset += stepSideways(p, vx: s.vx, dt: dt) }
        }
    }

    /// Sideways friction for a window's snow; returns how far the snow slid along the window (pt).
    /// Static friction: the snow moves with the window until the window accelerates harder than
    /// `staticFriction`·g. Then kinetic friction: the snow keeps its own speed, slowed by
    /// `kineticFriction`·g, so a sudden start leaves it behind a little and a sudden stop lets it
    /// slide on. Replayed on measured window jitter: no slip; stop at 500 pt/s slides ~48 pt.
    func stepSideways(_ p: Pile, vx: Float, dt: Float) -> Float {
        if !p.sideReady { p.wvx = vx; p.us = vx; p.sideReady = true }
        let before = p.wvx
        p.wvx += (vx - p.wvx) * min(1, dt / sideSmoothing)
        let accel = (p.wvx - before) / dt
        if !p.sliding {
            if abs(accel) > staticFriction * slabGravity { p.sliding = true; p.us = before }   // breaks loose
            else { p.us = p.wvx; return 0 }
        }
        let rel = p.us - p.wvx
        let brake = kineticFriction * slabGravity * dt
        if abs(rel) <= brake && abs(accel) <= staticFriction * slabGravity {
            p.sliding = false; p.us = p.wvx                                                // grips again
            return rel * dt
        }
        p.us -= rel > 0 ? brake : -brake
        return (p.us - p.wvx) * dt
    }

    /// The slab breaks into lumps (one per few columns), each a little different so they spread apart.
    private func breakApart(_ p: Pile, _ s: Surface, velocity: SIMD2<Float>) {
        let n = p.h.count
        // Lumps fall under lighter gravity than the slab, so cap their upward speed to what's left
        // of the maxThrowCm height (measured from the window top).
        let room = max(0, maxThrowCm * pointsPerCm - p.lift)
        let minVy = -(2 * gravity * room).squareRoot()
        let budget = max(1, Self.maxClumps - clumps.count)
        let group = max(3, Int((Float(n) / Float(budget)).rounded(.up)))
        var i = 0
        while i < n {
            let end = min(i + group, n)
            let sum = p.h[i..<end].reduce(0, +)
            if sum * Self.colW > 0.5 {
                let avg = sum / Float(end - i)
                addClump(x: Float(s.x) + (Float(i + end) / 2) * Self.colW,
                         y: Float(s.y) + s.drop(column: (i + end) / 2) - p.lift - avg * 0.5,
                         vx: velocity.x + Float.random(in: -30...30), vy: max(minVy, velocity.y + Float.random(in: -25...5)),
                         mass: sum * Self.colW, gk: Float.random(in: 0.75...1.25))
            }
            i = end
        }
        for j in 0..<n { p.h[j] = 0 }
        p.edgeLoss = (0, 0); p.slideOffset = 0; p.packed = []
        p.contact = true; p.slabReady = false; p.lift = 0; p.sliding = false; p.sideReady = false
        p.awake = true; mapsDirty = true
    }

    /// Snow sliding sideways on its window: shift whole columns; what passes an edge falls off.
    private func slide() {
        for s in surfaces {
            guard case .window = s.key, let p = piles[s.key], abs(p.slideOffset) >= Self.colW else { continue }
            log("window \(s.key) snow slides \(Int(p.slideOffset)) pt (snow speed \(Int(p.us)), window \(Int(s.vx)) pt/s)")
            p.packed = []
            let n = p.h.count
            while abs(p.slideOffset) >= Self.colW && n > 1 {
                let right = p.slideOffset > 0
                let lost = right ? p.h[n - 1] : p.h[0]
                if right { for i in stride(from: n - 1, to: 0, by: -1) { p.h[i] = p.h[i - 1] }; p.h[0] = 0 }
                else { for i in 0..<(n - 1) { p.h[i] = p.h[i + 1] }; p.h[n - 1] = 0 }
                if right { p.edgeLoss.right += lost * Self.colW } else { p.edgeLoss.left += lost * Self.colW }
                p.slideOffset -= right ? Self.colW : -Self.colW
                p.awake = true; mapsDirty = true
            }
            if p.edgeLoss.right > clumpMass {
                addClump(x: Float(s.x + s.width) + 2, y: Float(s.y) - 3, vx: max(0, p.us), vy: 0, mass: p.edgeLoss.right)
                p.edgeLoss.right = 0
            }
            if p.edgeLoss.left > clumpMass {
                addClump(x: Float(s.x) - 2, y: Float(s.y) - 3, vx: min(0, p.us), vy: 0, mass: p.edgeLoss.left)
                p.edgeLoss.left = 0
            }
        }
    }

    // MARK: Mouse plow

    /// The cursor pushes snow with a circle of `plowRadius` around it. Moving sideways, the circle
    /// sweeps a band; snow above the circle's lower edge in that band is cut loose and packed up
    /// just ahead, up to `packedHeight` times a normal pile. What doesn't fit moves further ahead;
    /// past a window or Dock end it falls; against the screen edge it stays.
    /// Costs one mouse read per frame; nothing else unless the circle moved through snow.
    private func plow(_ dt: Float) {
        let loc = NSEvent.mouseLocation                       // Cocoa: bottom-left origin
        let m = SIMD2(Float(loc.x), Float(screens[0].frame.height - loc.y))
        defer { lastMouse = m }
        guard let prev = lastMouse, abs(m.x - prev.x) > 0.01 else { return }
        let r = plowRadius

        // Front to back: the Dock, then windows, then the ground. A window or the Dock under the
        // cursor hides any snow behind it, so stop there.
        let order = surfaces.filter { $0.key == .dock } + surfaces.filter { $0.key != .dock }
        for s in order {
            let sx = Float(s.x), w = Float(s.width), sy = Float(s.y)
            if s.height > 0 && m.x >= sx && m.x < sx + w && m.y >= sy && m.y < sy + Float(s.height) { return }
            guard m.x + r >= sx, m.x - r < sx + w, let p = piles[s.key] else { continue }
            // Quick vertical reject: the circle must reach into the band where this snow can be.
            let top = sy - p.lift - s.maxHeight * packedHeight
            guard m.y + r >= top, m.y - r <= sy - p.lift else { continue }
            if push(p, s, fromX: prev.x, toX: m.x, cursorY: m.y, vx: (m.x - prev.x) / max(dt, 0.001)) { return }
        }
    }

    /// Returns true if any snow was moved.
    @discardableResult
    func push(_ p: Pile, _ s: Surface, fromX: Float, toX: Float, cursorY: Float, vx: Float) -> Bool {
        let n = p.h.count, sx = Float(s.x), r = plowRadius
        let dir = toX > fromX ? 1 : -1
        let lo = min(fromX, toX), hi = max(fromX, toX)
        func col(_ x: Float) -> Int { min(n - 1, max(0, Int((x - sx) / Self.colW))) }

        // Cut: every column the circle swept, down to the circle's lower edge there.
        var carried: Float = 0
        for c in col(lo - r)...col(hi + r) {
            let x = sx + (Float(c) + 0.5) * Self.colW
            let dx = x - max(lo, min(hi, x))                      // distance to the swept segment
            guard abs(dx) <= r else { continue }
            let circleBottom = cursorY + (r * r - dx * dx).squareRoot()
            let keep = max(0, Float(s.y) + s.drop(column: c) - p.lift - circleBottom)   // snow below the circle stays
            let cut = max(0, p.h[c] - keep)
            if cut > 0 { p.h[c] -= cut; carried += cut * Self.colW }
        }
        guard carried > 0.01 else { return false }

        // Pack it ahead of the circle; overflow travels on; falls off an end, or stops at a wall.
        if p.packed.count != n { p.packed = Array(repeating: 0, count: n) }
        let cap = s.maxHeight * packedHeight
        var a = col(toX + Float(dir) * r) + dir
        while carried > 0.01 {
            if a < 0 || a >= n, s.dropsAtEdges {
                let x = dir > 0 ? sx + Float(s.width) + 2 : sx - 2
                let lumps = min(6, max(1, Int(carried / (2 * clumpMass))))
                for _ in 0..<lumps {
                    addClump(x: x, y: Float(s.y) - p.lift - 3, vx: max(-300, min(300, vx * 0.6)) + Float.random(in: -30...30),
                             vy: Float.random(in: -40 ... -10), mass: carried / Float(lumps), gk: Float.random(in: 0.75...1.25))
                }
                break
            }
            if a < 0 || a >= n {                                    // the screen edge holds what's left
                p.h[a < 0 ? 0 : n - 1] += carried / Self.colW
                break
            }
            let put = min(max(0, cap - p.h[a]) * Self.colW, carried)
            p.h[a] += put / Self.colW
            p.packed[a] = min(1, p.packed[a] + 0.3 + put / (cap * Self.colW))
            carried -= put
            a += dir
        }
        p.awake = true
        mapsDirty = true
        return true
    }

    // MARK: Growth and slumping (20 Hz)

    private func accumulate(_ dt: Float) {
        for (si, s) in screens.enumerated() where s.landingRate > 0 {
            // Volume per landing chosen so exposed snow rises 10 pt in `fillTime` seconds.
            let volume = (10 / fillTime) * Float(s.frame.width) / s.landingRate
            let expected = s.landingRate * dt * rateScale
            var count = Int(expected)
            if Float.random(in: 0..<1) < expected - Float(count) { count += 1 }
            for _ in 0..<count {
                let j = Int.random(in: 0..<Self.mapSize)
                let k = Int(owner[si][j])
                guard k >= 0, let pile = piles[mapSurfaces[k].key] else { continue }
                // Full = average height reached (not every column at the cap, which looks flat).
                let mean = pile.h.reduce(0, +) / Float(pile.h.count)
                guard mean < fullAt * mapSurfaces[k].maxHeight else { continue }
                let x = Float(s.frame.minX) + (Float(j) + Float.random(in: 0..<1)) * Float(s.frame.width) / Float(Self.mapSize)
                deposit(pile, col: Int((x - Float(mapSurfaces[k].x)) / Self.colW), mass: volume)
            }
        }
    }

    private func deposit(_ pile: Pile, col: Int, mass: Float) {
        guard mass > 0 else { return }
        // Spread over 5 columns so landings look like soft lumps.
        let weights: [Float] = [0.1, 0.2, 0.4, 0.2, 0.1]
        let height = mass / Self.colW
        for (o, w) in weights.enumerated() {
            let c = col + o - 2
            if c >= 0 && c < pile.h.count { pile.h[c] += height * w }
        }
        pile.awake = true
        mapsDirty = true
    }

    private func slump() {
        for s in surfaces {
            guard let p = piles[s.key], p.awake else { continue }
            var moved: Float = 0
            let n = p.h.count
            if n > 1 {
                // Compare snow *tops* (height minus the corner curve), so snow slides down rounded corners.
                var bi = s.drop(column: 0)
                let packed = !p.packed.isEmpty
                for i in 0..<(n - 1) {
                    let bj = s.drop(column: i + 1)
                    let d = (p.h[i] - bi) - (p.h[i + 1] - bj)
                    // Packed snow holds up to 3x steeper sides.
                    let slope = packed ? maxSlope * (1 + 2 * max(p.packed[i], p.packed[i + 1])) : maxSlope
                    if abs(d) > slope {
                        var t = (abs(d) - slope) * 0.25
                        t = min(t, d > 0 ? p.h[i] : p.h[i + 1])
                        if d < 0 { t = -t }
                        p.h[i] -= t; p.h[i + 1] += t; moved += abs(t)
                    }
                    bi = bj
                }
            }
            if s.dropsAtEdges {
                // Treat outside the edge as height 0: steep snow slides off into a clump.
                if p.h[0] > maxSlope {
                    let t = (p.h[0] - maxSlope) * 0.25
                    p.h[0] -= t; p.edgeLoss.left += t * Self.colW; moved += t
                }
                if p.h[n - 1] > maxSlope {
                    let t = (p.h[n - 1] - maxSlope) * 0.25
                    p.h[n - 1] -= t; p.edgeLoss.right += t * Self.colW; moved += t
                }
                if p.edgeLoss.left > clumpMass {
                    addClump(x: Float(s.x) - 2, y: Float(s.y) - 2, mass: p.edgeLoss.left); p.edgeLoss.left = 0
                }
                if p.edgeLoss.right > clumpMass {
                    addClump(x: Float(s.x + s.width) + 2, y: Float(s.y) - 2, mass: p.edgeLoss.right); p.edgeLoss.right = 0
                }
            }
            if moved > 0.001 { mapsDirty = true }
            if !p.packed.isEmpty {
                var still = false
                for i in p.packed.indices { p.packed[i] *= packedSettle; if p.packed[i] > 0.05 { still = true } }
                if !still { p.packed = [] }
            }
            p.awake = moved > 0.001 || !p.packed.isEmpty    // asleep until something lands on it
        }
    }

    // MARK: Clumps

    private func spawnClumps(mass: Float, x0: Float, width: Float, y: Float) {
        guard mass > 1 else { return }
        let n = max(1, min(24, Int(mass / clumpMass)))
        for i in 0..<n {
            addClump(x: x0 + (Float(i) + Float.random(in: 0..<1)) * width / Float(n), y: y - 3, mass: mass / Float(n))
        }
    }

    private func addClump(x: Float, y: Float, vx: Float = 0, vy: Float = 0, mass: Float, gk: Float = 1) {
        guard clumps.count < Self.maxClumps else { return }
        // Each lump is gone after falling 6–7 cm on this screen (if it hasn't landed by then).
        clumps.append(Clump(x: x, y: y, vx: vx, vy: vy, mass: mass, size: min(8, max(2.5, sqrt(mass) * 0.9)), gk: gk,
                            reach: Float.random(in: 6...7) * pointsPerCm))
    }

    private func stepClumps(_ dt: Float) {
        var i = 0
        while i < clumps.count {
            var c = clumps[i]
            c.vy = min(c.vy + gravity * c.gk * dt, 350)             // gravity, capped at a fall speed
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
                let j = min(Self.mapSize - 1, max(0, Int((c.x - Float(s.frame.minX)) / Float(s.frame.width) * Float(Self.mapSize))))
                let landY = maps[si][j] + Float(s.frame.minY)
                // Land only when falling onto a surface from just above it. A lump that's deep below a
                // surface line is in front of that window's face, so it keeps falling.
                if c.vy > 0 && c.y >= landY && c.y - landY < max(20, c.vy * dt * 2) {
                    let k = Int(owner[si][j])
                    if k >= 0, let pile = piles[mapSurfaces[k].key] {
                        deposit(pile, col: Int((c.x - Float(mapSurfaces[k].x)) / Self.colW), mass: c.mass * c.alpha)
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
            let step = Float(s.frame.width) / Float(Self.mapSize)
            let left = Float(s.frame.minX), top = Float(s.frame.minY)
            for j in 0..<Self.mapSize { maps[si][j] = .infinity; owner[si][j] = -1 }
            for (k, surf) in surfaces.enumerated() {
                if case .ground(let g) = surf.key, g != si { continue }
                guard let p = piles[surf.key] else { continue }
                let sx = Float(surf.x), sw = Float(surf.width)
                let j0 = max(0, Int(ceil((sx - left) / step - 0.5)))
                let j1 = min(Self.mapSize - 1, Int(floor((sx + sw - left) / step - 0.5)))
                guard j0 <= j1 else { continue }
                let isGround = { if case .ground = surf.key { return true } else { return false } }()
                for j in j0...j1 {
                    let x = left + (Float(j) + 0.5) * step
                    let col = min(p.h.count - 1, max(0, Int((x - sx) / Self.colW)))
                    let y = Float(surf.y) + surf.drop(column: col) - p.lift - p.h[col] - top
                    if y < maps[si][j] { maps[si][j] = y; owner[si][j] = Int32(k) }
                    if isGround { maps[si][Self.mapSize + j] = y }
                }
            }
        }
    }
}

// MARK: - Self-check (run: Snowdrift --selftest)

extension Snowpack {
    /// Pushes synthetic piles with the real plow and checks the invariants. Returns failures.
    func selfTest() -> [String] {
        var fail: [String] = []
        func total(_ p: Pile) -> Float { p.h.reduce(0, +) * Self.colW }
        let clumpMass0 = clumps.reduce(0) { $0 + $1.mass }

        // 1. Window top, push right through the middle: mass is conserved, ridge is capped,
        //    swept columns are cut down to the cursor.
        let win = Surface(key: .window(999_999), x: 100, y: 500, width: 200, height: 300, depth: 0.5,
                          dropsAtEdges: true, maxHeight: 10)
        let p = Pile(columns: 100)
        for i in p.h.indices { p.h[i] = 8 }
        let before = total(p)
        push(p, win, fromX: 140, toX: 200, cursorY: 497, vx: 600)    // cursor 3 pt above the base
        let spilled1 = clumps.reduce(0) { $0 + $1.mass } - clumpMass0
        if abs(total(p) + spilled1 - before) > 0.01 { fail.append("window: mass \(before) -> \(total(p)) + \(spilled1) lumps") }
        if let m = p.h.max(), m > 10 * packedHeight + 0.001 { fail.append("window: ridge \(m) above cap") }
        for c in 20...49 where p.h[c] > 3.001 { fail.append("window: column \(c) not cut (\(p.h[c]))"); break }

        // 2. Push into the right end: what passes the end becomes falling lumps, nothing is lost.
        let q = Pile(columns: 100)
        for i in q.h.indices { q.h[i] = 8 }
        let qBefore = total(q)
        let clumpMass1 = clumps.reduce(0) { $0 + $1.mass }
        push(q, win, fromX: 120, toX: 299, cursorY: 499, vx: 900)
        let spilled = clumps.reduce(0) { $0 + $1.mass } - clumpMass1
        if spilled <= 0 { fail.append("edge: nothing fell off") }
        if abs(total(q) + spilled - qBefore) > 0.01 { fail.append("edge: mass \(qBefore) -> \(total(q)) + \(spilled) lumps") }

        // 3. Ground (held by the screen edge): pushing into the wall keeps all the snow.
        let ground = Surface(key: .ground(99), x: 0, y: 900, width: 100, height: 0, depth: 0.95,
                             dropsAtEdges: false, maxHeight: 24)
        let g = Pile(columns: 50)
        for i in g.h.indices { g.h[i] = 20 }
        let gBefore = total(g)
        push(g, ground, fromX: 10, toX: 99, cursorY: 895, vx: 900)
        if abs(total(g) - gBefore) > 0.01 { fail.append("ground: mass \(gBefore) -> \(total(g))") }

        // 5. Slab on a window, fed the jittery positions measured from a steady 400 pt/s move up
        //    (3–11 pt per 60 Hz sample): it must never lift. Then the window stops: a small hop
        //    that lands back without breaking. Then a fast downward flick: it breaks.
        let slab = Pile(columns: 10)
        let steps: [Float] = [-4, -10, -6, -7, -3, -11, -6, -7, -3, -10, -7, -7, -3, -10, -6, -7, -3, -11, -6, -7]
        var y: Float = 600, v: Float = 0, maxLift: Float = 0
        for _ in 0..<3 { for d in steps { y += d; v = v * 0.5 + d * 60 * 0.5
            maxLift = max(maxLift, stepSlab(slab, yw: y, vw: v, dt: 1.0 / 60) ?? 999) } }
        if maxLift > 0 { fail.append("slab: lifted \(maxLift) pt during a steady upward move") }
        var hop: Float = 0, landed = false
        for i in 0..<90 { v *= 0.5                                     // stopped (smoothed speed decays)
            guard let l = stepSlab(slab, yw: y, vw: v, dt: 1.0 / 60) else { fail.append("slab: broke on a stop"); break }
            hop = max(hop, l); if i > 5 && slab.contact { landed = true; break } }
        if hop < 5 || hop > breakLift { fail.append("slab: hop after stopping was \(hop) pt") }
        if !landed { fail.append("slab: didn't land back after the hop") }
        var broke = false
        for _ in 0..<30 { y += 20; if stepSlab(slab, yw: y, vw: 1200, dt: 1.0 / 60) == nil { broke = true; break } }
        if !broke { fail.append("slab: a 1200 pt/s downward flick didn't break it") }

        // 6. Sideways friction: measured jittery speeds (smoothed tracker samples of a steady move)
        //    must not make the snow slide; a sudden stop from 500 pt/s must slide it onward.
        let side = Pile(columns: 10)
        let jitter: [Float] = [-315, -453, -405, -419, -298, -479, -428, -420, -299, -445, -441, -426, -305, -442, -406, -411, -293, -478, -421, -414]
        var drift: Float = 0
        for _ in 0..<3 { for v in jitter { drift += stepSideways(side, vx: -v, dt: 1.0 / 60) } }
        if abs(drift) > 0.5 { fail.append("sideways: jitter made the snow slide \(drift) pt") }
        let stop = Pile(columns: 10)
        for _ in 0..<20 { _ = stepSideways(stop, vx: 500, dt: 1.0 / 60) }
        var slid: Float = 0
        for _ in 0..<80 { slid += stepSideways(stop, vx: 0, dt: 1.0 / 60) }
        if slid < 20 || slid > 120 { fail.append("sideways: sudden stop at 500 pt/s slid \(slid) pt") }

        // 7. Lumps fade: full at the start, gone at their reach.
        var lump = Clump(x: 0, y: 0, vx: 0, vy: 0, mass: 1, size: 3, gk: 1, reach: 300)
        if lump.alpha < 0.999 { fail.append("lump: not fully visible at start") }
        lump.fallen = 300
        if lump.alpha > 0.001 { fail.append("lump: still visible at its reach") }
        return fail
    }
}
