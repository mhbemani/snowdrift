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
}

/// Snow height in columns of `Snowpack.colW` points, anchored to the surface's left edge,
/// so piles ride along with windows for free.
final class Pile {
    var h: [Float]
    var awake = true
    var edgeLoss: (left: Float, right: Float) = (0, 0)
    init(columns: Int) { h = Array(repeating: 0, count: columns) }
}

/// A falling lump of snow (from a pile's edge, or a closed window). CPU particle: there are
/// usually none, and never more than `maxClumps`.
struct Clump { var x, y, vy, mass, size: Float }

/// Owns the piles and does all snow-on-surface physics.
///
/// Cost model (it runs all day):
/// - Falling flakes stay on the GPU. Instead of tracking which flake landed where, piles grow
///   from the known landing *rate* (flakes/sec are fixed at startup), as random bumps on whichever
///   surface is exposed at a random x. Cost scales with landings (~10/s), not with flakes.
/// - Piles are height maps; slumping is a cheap sand-pile rule, run at 20 Hz, and only on piles
///   that are still changing. Settled piles cost nothing.
/// - Growth slows as a pile nears its max height, so full piles stop changing (and stop costing).
/// - The landing map the GPU uses to stop flakes is rebuilt only when something changed.
@MainActor
final class Snowpack {
    static let colW: Float = 2
    static let mapSize = 512                  // landing map entries per screen (GPU limit: 4 KB for both maps)
    static let maxClumps = 120
    private let tick: Double = 1.0 / 20
    private let fillTime: Float = 180         // seconds for an exposed window top to fill (before slowdown)
    private let maxSlope: Float = 1.0         // max height difference between neighbour columns
    private let clumpMass: Float = 8          // pt² of snow that leaves an edge as one clump

    private let tracker: WindowTracker
    private let dock: DockInfo
    private let lead: Double
    private let rateScale: Float

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

    init(tracker: WindowTracker, dock: DockInfo, screens: [ScreenInfo], lead: Double, rateScale: Float) {
        self.tracker = tracker; self.dock = dock; self.screens = screens
        self.lead = lead; self.rateScale = rateScale
        maps = screens.map { _ in Array(repeating: 0, count: 2 * Self.mapSize) }
        owner = screens.map { _ in Array(repeating: -1, count: Self.mapSize) }
        dockRect = dock.platter(on: screens)
    }

    func dockChanged() { dockRect = dock.platter(on: screens); mapsDirty = true }

    /// Advance to `now`. Every screen's renderer calls this; only the first call per frame works.
    func frame(now: CFTimeInterval) {
        let dt = now - lastFrame
        guard dt > 0.004 else { return }
        lastFrame = now

        buildSurfaces(now: now)
        syncPiles()
        simTime += min(dt, 0.25)
        while simTime >= tick {
            simTime -= tick
            accumulate(Float(tick))
            slump()
        }
        if !clumps.isEmpty { stepClumps(Float(min(dt, 0.05))) }
        if mapsDirty { buildMaps(); mapsDirty = false }
    }

    // MARK: Surfaces

    private func buildSurfaces(now: CFTimeInterval) {
        let (windows, sampled) = tracker.snapshot()
        let ahead = min(now - sampled, 0.1) + lead
        var next: [Surface] = []
        next.reserveCapacity(windows.count + screens.count + 1)
        let n = Float(max(windows.count, 1))
        for (i, w) in windows.enumerated() {
            let f = w.frame.offsetBy(dx: w.velocity.dx * ahead, dy: w.velocity.dy * ahead)
            // Skip tops hidden under the menu bar (maximized / full-screen windows).
            guard let s = screens.first(where: { $0.frame.contains(CGPoint(x: f.midX, y: max(f.minY, $0.frame.minY))) }),
                  f.minY > s.frame.minY + s.menuBar + 1 else { continue }
            next.append(Surface(key: .window(w.id), x: f.minX, y: f.minY, width: f.width, height: f.height,
                                depth: 0.2 + 0.7 * Float(i) / n, dropsAtEdges: true, maxHeight: 10))
        }
        if let d = dockRect {
            next.append(Surface(key: .dock, x: d.minX, y: d.minY, width: d.width, height: d.height, depth: 0.1, dropsAtEdges: true, maxHeight: 8))
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
                    p.h.removeLast(p.h.count - cols); p.awake = true; mapsDirty = true
                } else if p.h.count < cols {
                    p.h.append(contentsOf: repeatElement(0, count: cols - p.h.count)); p.awake = true; mapsDirty = true
                }
            } else {
                piles[s.key] = Pile(columns: cols)
            }
            lastSurfaces[s.key] = s
        }
        // Window closed, minimized or moved to another Space: its snow falls.
        for key in piles.keys where !seen.contains(key) {
            if let p = piles[key], let s = lastSurfaces[key] {
                spawnClumps(mass: p.h.reduce(0, +) * Self.colW, x0: Float(s.x), width: Float(p.h.count) * Self.colW, y: Float(s.y))
            }
            piles[key] = nil; lastSurfaces[key] = nil; mapsDirty = true
        }
    }

    // MARK: Growth and slumping (20 Hz)

    private func accumulate(_ dt: Float) {
        for (si, s) in screens.enumerated() where s.landingRate > 0 {
            // Volume per landing chosen so an exposed surface rises ~10 pt in `fillTime` seconds.
            let volume = (10 / fillTime) * Float(s.frame.width) / s.landingRate
            let expected = s.landingRate * dt * rateScale
            var count = Int(expected)
            if Float.random(in: 0..<1) < expected - Float(count) { count += 1 }
            for _ in 0..<count {
                let j = Int.random(in: 0..<Self.mapSize)
                let k = Int(owner[si][j])
                guard k >= 0, let pile = piles[mapSurfaces[k].key] else { continue }
                let x = Float(s.frame.minX) + (Float(j) + Float.random(in: 0..<1)) * Float(s.frame.width) / Float(Self.mapSize)
                let col = Int((x - Float(mapSurfaces[k].x)) / Self.colW)
                let fill = pile.h[max(0, min(col, pile.h.count - 1))] / mapSurfaces[k].maxHeight
                deposit(pile, col: col, mass: volume * max(0, 1 - fill))
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
                for i in 0..<(n - 1) {
                    let d = p.h[i] - p.h[i + 1]
                    if abs(d) > maxSlope {
                        let t = (abs(d) - maxSlope) * 0.25 * (d > 0 ? 1 : -1)
                        p.h[i] -= t; p.h[i + 1] += t; moved += abs(t)
                    }
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
            p.awake = moved > 0.001     // stays asleep until something lands on it
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

    private func addClump(x: Float, y: Float, mass: Float) {
        guard clumps.count < Self.maxClumps else { return }
        clumps.append(Clump(x: x, y: y, vy: 0, mass: mass, size: min(8, max(2.5, sqrt(mass) * 0.9))))
    }

    private func stepClumps(_ dt: Float) {
        var i = 0
        while i < clumps.count {
            clumps[i].vy = min(clumps[i].vy + 600 * dt, 260)      // gravity, capped at a fall speed
            clumps[i].y += clumps[i].vy * dt
            let c = clumps[i]
            var done = true
            if let si = screens.firstIndex(where: { Float($0.frame.minX) <= c.x && c.x < Float($0.frame.maxX) }) {
                let s = screens[si]
                let j = min(Self.mapSize - 1, max(0, Int((c.x - Float(s.frame.minX)) / Float(s.frame.width) * Float(Self.mapSize))))
                let landY = maps[si][j] + Float(s.frame.minY)
                if c.y < landY { done = false }
                else if owner[si][j] >= 0, let pile = piles[mapSurfaces[Int(owner[si][j])].key] {
                    deposit(pile, col: Int((c.x - Float(mapSurfaces[Int(owner[si][j])].x)) / Self.colW), mass: c.mass)
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
                    let y = Float(surf.y) - p.h[col] - top
                    if y < maps[si][j] { maps[si][j] = y; owner[si][j] = Int32(k) }
                    if isGround { maps[si][Self.mapSize + j] = y }
                }
            }
        }
    }
}
