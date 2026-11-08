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
    var slideV: Float = 0          // snow's sideways speed relative to its window (pt/s)
    var slideOffset: Float = 0     // sub-column slide not yet applied
    init(columns: Int) { h = Array(repeating: 0, count: columns) }
}

/// A free-flying lump of snow: thrown off a window, slid off an edge, or left by a closed window.
/// CPU particle; there are none most of the time, and never more than `maxClumps`.
struct Clump { var x, y, vx, vy, mass, size, gk: Float }   // gk: per-lump gravity factor (air drag varies)

/// Owns the piles and does all snow-on-surface physics.
///
/// Cost model (it runs all day):
/// - Falling flakes stay on the GPU. Piles grow from the known landing *rate* (flakes/sec are
///   fixed at startup), as random bumps on whichever surface is exposed at a random x.
/// - Piles are height maps; slumping is a cheap sand-pile rule at 20 Hz, only on piles still changing.
/// - Growth slows as a pile nears its max height, so full piles stop changing (and stop costing).
/// - Window physics only runs when a window's velocity sample changes, i.e. while it moves.
/// - The landing map the GPU uses to stop flakes is rebuilt only when something changed.
///
/// Physics (game-scaled: real gravity at screen scale would be ~30,000 pt/s²):
/// snow stays on a window unless the window accelerates *down* faster than gravity. Then it lifts
/// off with the speed it had. That one rule gives: drop a window → snow hangs, falls behind,
/// spreads and lands again; stop a window moving up → snow keeps going up a bit, then falls back.
/// Sideways, snow sticks by friction and slides when the window accelerates harder than that.
@MainActor
final class Snowpack {
    nonisolated static let colW: Float = 2
    static let mapSize = 512                  // landing map entries per screen (GPU limit: 4 KB for both maps)
    static let maxClumps = 800
    private let tick: Double = 1.0 / 20
    private let fillTime: Float = 180         // seconds for an exposed window top to fill (before slowdown)
    private let maxSlope: Float = 1.0         // max height difference between neighbour columns
    private let clumpMass: Float = 8          // pt² of snow that leaves an edge as one clump
    // Calibration knobs for the feel of the physics:
    private let gravity: Float = 900          // pt/s²
    private let friction: Float = 1.0         // sideways grip: slides when |ax| > friction * gravity
    private let slideGain: Float = 0.4        // how much of the sideways jolt the snow keeps
    private let throwFactor: Float = 0.35     // share of a window's upward speed kept when it stops
    // ponytail: one radius for every window. macOS 26 uses ~16 pt (plain) to ~26 pt (toolbar);
    // the real radius isn't exposed without reading pixels.
    static let cornerRadius: Float = 20

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
    private var motion: [CGWindowID: (v: SIMD2<Float>, t: CFTimeInterval)] = [:]
    private var mapsDirty = true

    init(tracker: WindowTracker, dock: DockInfo, screens: [ScreenInfo], lead: Double, rateScale: Float) {
        self.tracker = tracker; self.dock = dock; self.screens = screens
        self.lead = lead; self.rateScale = rateScale
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
        applyMotion(windows: windows, sampled: sampled)
        slide(fdt)
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
                  f.minY > s.frame.minY + s.menuBar + 1 else { continue }
            next.append(Surface(key: .window(w.id), x: f.minX, y: f.minY, width: f.width, height: f.height,
                                depth: 0.2 + 0.7 * Float(i) / n, dropsAtEdges: true, maxHeight: 10, radius: Self.cornerRadius))
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
            guard case .window = key else { continue }              // Dock hidden in full screen keeps its snow
            if let p = piles[key], let s = lastSurfaces[key] {
                spawnClumps(mass: p.h.reduce(0, +) * Self.colW, x0: Float(s.x), width: Float(p.h.count) * Self.colW, y: Float(s.y))
            }
            piles[key] = nil; lastSurfaces[key] = nil; mapsDirty = true
        }
    }

    // MARK: Window motion

    /// Uses the tracker's velocity samples; does nothing for windows that aren't moving.
    private func applyMotion(windows: [TrackedWindow], sampled: CFTimeInterval) {
        for w in windows {
            let v = SIMD2(Float(w.velocity.dx), Float(w.velocity.dy))
            guard let m = motion[w.id] else { motion[w.id] = (v, sampled); continue }
            guard sampled > m.t else { continue }                 // no new sample since last frame
            motion[w.id] = (v, sampled)
            let dt = Float(sampled - m.t)
            guard dt < 0.1, v != m.v, let p = piles[.window(w.id)], let s = lastSurfaces[.window(w.id)] else { continue }
            let a = (v - m.v) / dt

            if a.y > gravity {
                // The window drops out from under the snow (or brakes while going up):
                // the snow keeps the speed it had. Upward speed is damped so it's "a little" throw.
                detach(p, s, velocity: [m.v.x * 0.5, m.v.y < 0 ? m.v.y * throwFactor : m.v.y])
            } else if abs(a.x) > friction * gravity {
                // Friction can't hold it: the snow lags behind the window's jolt.
                let excess = abs(a.x) - friction * gravity
                p.slideV -= (a.x > 0 ? 1 : -1) * excess * dt * slideGain
            }
        }
        if motion.count > windows.count + 8 {                     // forget closed windows now and then
            let ids = Set(windows.map(\.id))
            motion = motion.filter { ids.contains($0.key) }
        }
    }

    /// Snow lifts off as lumps (one per few columns), each a little different so they spread apart.
    private func detach(_ p: Pile, _ s: Surface, velocity: SIMD2<Float>) {
        let n = p.h.count
        let budget = max(1, Self.maxClumps - clumps.count)
        let group = max(3, Int((Float(n) / Float(budget)).rounded(.up)))
        var i = 0
        while i < n {
            let end = min(i + group, n)
            let sum = p.h[i..<end].reduce(0, +)
            if sum * Self.colW > 0.5 {
                let avg = sum / Float(end - i)
                addClump(x: Float(s.x) + (Float(i + end) / 2) * Self.colW, y: Float(s.y) + s.drop(column: (i + end) / 2) - avg * 0.5,
                         vx: velocity.x + Float.random(in: -15...15), vy: velocity.y + Float.random(in: -25...5),
                         mass: sum * Self.colW, gk: Float.random(in: 0.8...1.2))
            }
            i = end
        }
        for j in 0..<n { p.h[j] = 0 }
        p.edgeLoss = (0, 0); p.slideV = 0; p.slideOffset = 0
        p.awake = true; mapsDirty = true
    }

    /// Snow sliding sideways on its window: shift whole columns; what passes an edge falls off.
    private func slide(_ dt: Float) {
        for s in surfaces {
            guard case .window = s.key, let p = piles[s.key], p.slideV != 0 else { continue }
            p.slideOffset += p.slideV * dt
            let brake = friction * gravity * dt                    // kinetic friction slows the slide
            p.slideV = abs(p.slideV) <= brake ? 0 : p.slideV - (p.slideV > 0 ? brake : -brake)
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
                addClump(x: Float(s.x + s.width) + 2, y: Float(s.y) - 3, vx: max(0, p.slideV), vy: 0, mass: p.edgeLoss.right)
                p.edgeLoss.right = 0
            }
            if p.edgeLoss.left > clumpMass {
                addClump(x: Float(s.x) - 2, y: Float(s.y) - 3, vx: min(0, p.slideV), vy: 0, mass: p.edgeLoss.left)
                p.edgeLoss.left = 0
            }
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
                // Compare snow *tops* (height minus the corner curve), so snow slides down rounded corners.
                var bi = s.drop(column: 0)
                for i in 0..<(n - 1) {
                    let bj = s.drop(column: i + 1)
                    let d = (p.h[i] - bi) - (p.h[i + 1] - bj)
                    if abs(d) > maxSlope {
                        var t = (abs(d) - maxSlope) * 0.25
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

    private func addClump(x: Float, y: Float, vx: Float = 0, vy: Float = 0, mass: Float, gk: Float = 1) {
        guard clumps.count < Self.maxClumps else { return }
        clumps.append(Clump(x: x, y: y, vx: vx, vy: vy, mass: mass, size: min(8, max(2.5, sqrt(mass) * 0.9)), gk: gk))
    }

    private func stepClumps(_ dt: Float) {
        var i = 0
        while i < clumps.count {
            var c = clumps[i]
            c.vy = min(c.vy + gravity * c.gk * dt, 350)             // gravity, capped at a fall speed
            c.vx *= 1 - min(1, 1.5 * dt)                            // air drag
            c.x += c.vx * dt
            c.y += c.vy * dt
            clumps[i] = c
            var done = true
            if let si = screens.firstIndex(where: { Float($0.frame.minX) <= c.x && c.x < Float($0.frame.maxX) }) {
                let s = screens[si]
                let j = min(Self.mapSize - 1, max(0, Int((c.x - Float(s.frame.minX)) / Float(s.frame.width) * Float(Self.mapSize))))
                let landY = maps[si][j] + Float(s.frame.minY)
                // Land only when falling onto a surface from just above it. A lump that's deep below a
                // surface line is in front of that window's face, so it keeps falling.
                if c.vy > 0 && c.y >= landY && c.y - landY < max(20, c.vy * dt * 2) {
                    let k = Int(owner[si][j])
                    if k >= 0, let pile = piles[mapSurfaces[k].key] {
                        deposit(pile, col: Int((c.x - Float(mapSurfaces[k].x)) / Self.colW), mass: c.mass)
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
                    let y = Float(surf.y) + surf.drop(column: col) - p.h[col] - top
                    if y < maps[si][j] { maps[si][j] = y; owner[si][j] = Int32(k) }
                    if isGround { maps[si][Self.mapSize + j] = y }
                }
            }
        }
    }
}
