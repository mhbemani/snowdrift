import CoreGraphics

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
    func drop(column c: Int) -> Float { drop((Float(c) + 0.5) * Physics.colW) }
}

/// A free-flying lump of snow: thrown off a window, slid off an edge, or left by a closed window.
/// CPU particle; there are none most of the time, and never more than `Physics.maxClumps`.
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

/// Snow on one surface: a height per column of `Physics.colW` points, anchored to the surface's left
/// edge, so piles ride along with windows for free. All the physics that only needs the pile itself
/// lives here; anything that creates falling lumps is reported back to `Snowpack`.
final class Pile {
    var h: [Float]
    var awake = true                             // slumping runs only while something changes
    var edgeLoss: (left: Float, right: Float) = (0, 0)   // snow gone past an edge, not yet a lump
    var slideOffset: Float = 0                   // sub-column slide not yet applied
    // A window's snow moves as one slab (see stepSlab):
    var contact = true                           // resting on its window
    var slabReady = false
    var ghostY: Float = 0, ghostV: Float = 0     // where free-flying snow would be now
    var slabY: Float = 0, slabV: Float = 0       // the slab's own position/speed while in the air
    var lift: Float = 0                          // how far above the window top the slab is
    // Sideways friction (see stepSideways):
    var us: Float = 0                            // the snow's own sideways speed
    var wvx: Float = 0                           // the window's sideways speed, smoothed
    var sliding = false                          // static friction broke; kinetic friction slows it
    var sideReady = false
    /// Compaction per column, 0…1, from the mouse plow. Empty until the pile is first pushed
    /// (most piles never are), and emptied again once it has settled.
    var packed: [Float] = []
    /// The hill the plow is pushing, as a layer on top of the snow: `hillLayer[k]` was added to
    /// column `hillStart + k`. The next push takes back exactly that, so the hill travels whole
    /// without eating or leaving bits of the snow under it.
    var hillStart = 0
    var hillLayer: [Float] = []
    var hill: ClosedRange<Int>? { hillLayer.isEmpty ? nil : hillStart...(hillStart + hillLayer.count - 1) }
    /// Fixed per pile: which spots are stickier (see `cohesion(at:)`).
    private let seed = UInt32.random(in: 1...UInt32.max)

    /// How steep the snow can stand between columns i and i+1, as a multiple of `Physics.maxSlope`:
    /// a stable random value per spot (hashed, no memory), so a pile keeps its bumps.
    func cohesion(at i: Int) -> Float {
        var x = UInt32(truncatingIfNeeded: i) &* 2654435761 ^ seed
        x ^= x >> 15; x = x &* 2246822519; x ^= x >> 13
        let r = Float(x & 0xffff) / 65535
        return Physics.cohesion.lowerBound + r * (Physics.cohesion.upperBound - Physics.cohesion.lowerBound)
    }

    init(columns: Int) { h = Array(repeating: 0, count: max(1, columns)) }

    var mass: Float { h.reduce(0, +) * Physics.colW }
    var mean: Float { h.reduce(0, +) / Float(h.count) }

    func clear() {
        for i in h.indices { h[i] = 0 }
        packed = []; hillLayer = []; edgeLoss = (0, 0); slideOffset = 0
        contact = true; slabReady = false; lift = 0; sliding = false; sideReady = false; awake = true
    }

    /// Change the number of columns (the surface was resized). Returns the snow cut off the right end.
    func resize(to columns: Int) -> Float {
        let cols = max(1, columns)
        guard cols != h.count else { return 0 }
        packed = []; hillLayer = []; awake = true
        if cols < h.count {
            let cut = h[cols...].reduce(0, +) * Physics.colW
            h.removeLast(h.count - cols)
            return cut
        }
        h.append(contentsOf: repeatElement(0, count: cols - h.count))
        return 0
    }

    /// Add snow around a column, spread over 5 columns so landings look like soft lumps.
    func deposit(col: Int, mass: Float) {
        guard mass > 0 else { return }
        let weights: [Float] = [0.1, 0.2, 0.4, 0.2, 0.1]
        let height = mass / Physics.colW
        for (o, w) in weights.enumerated() {
            let c = col + o - 2
            if c >= 0 && c < h.count { h[c] += height * w }
        }
        awake = true
    }

    // MARK: Window motion

    /// One step of a window's snow slab. Returns the lift (pt above the window top), or nil if the
    /// slab broke apart. `yw` = window top (y down), `vw` = its vertical speed (from the tracker).
    ///
    /// The slab rests on the window until the window gets ahead of where free-flying snow could be
    /// (window dropped away, or stopped while carrying the snow up). Then it flies on its own and
    /// lands back; only a big lift (a fast flick) breaks it. Position-based on purpose: window
    /// samples are jittery (a steady 400 pt/s move reads as 3, 10, 6, 7, 3, 11 pt per 60 Hz sample),
    /// so differences of speeds swing ±10,000 pt/s². A gap counts only beyond one sample of motion.
    func stepSlab(yw: Float, vw: Float, dt: Float, maxThrowSpeed: Float) -> Float? {
        if !slabReady { ghostY = yw; ghostV = vw; slabReady = true }
        if contact {
            ghostV = min(ghostV + Physics.slabGravity * dt, 2000)
            ghostY += ghostV * dt
            if yw <= ghostY {                                       // still carrying the snow
                ghostY = yw; ghostV = vw
            } else if yw - ghostY > 3 + 1.2 * abs(vw) / 60 {        // more than one sample of jitter
                contact = false
                slabY = yw
                slabV = max(ghostV, -maxThrowSpeed)                 // never thrown higher than the cap
            }
            lift = 0
            return 0
        }
        slabV = min(slabV + Physics.slabGravity * dt, 2000)
        slabY += slabV * dt
        if slabY >= yw {                                            // landed back on the window
            contact = true; ghostY = yw; ghostV = vw; lift = 0
            return 0
        }
        lift = yw - slabY
        return lift > Physics.breakLift ? nil : lift
    }

    /// Sideways friction; returns how far the snow slid along the window this step (pt).
    /// Static friction: the snow moves with the window until the window accelerates harder than
    /// `staticFriction`·g. Then kinetic friction: the snow keeps its own speed, slowed by
    /// `kineticFriction`·g, so a sudden start leaves it behind a little and a sudden stop lets it
    /// slide on. Replayed on measured window jitter: no slip; stop at 500 pt/s slides ~48 pt.
    func stepSideways(vx: Float, dt: Float) -> Float {
        if !sideReady { wvx = vx; us = vx; sideReady = true }
        let before = wvx
        wvx += (vx - wvx) * min(1, dt / Physics.sideSmoothing)
        let accel = (wvx - before) / dt
        let grip = Physics.staticFriction * Physics.slabGravity
        if !sliding {
            if abs(accel) > grip { sliding = true; us = before }    // breaks loose
            else { us = wvx; return 0 }
        }
        let rel = us - wvx
        let brake = Physics.kineticFriction * Physics.slabGravity * dt
        if abs(rel) <= brake && abs(accel) <= grip {
            sliding = false; us = wvx                               // grips again
            return rel * dt
        }
        us -= rel > 0 ? brake : -brake
        return (us - wvx) * dt
    }

    /// Apply the slide in whole columns; snow pushed past an end goes to `edgeLoss`.
    /// Returns true if anything moved.
    func applySlide() -> Bool {
        let n = h.count
        guard abs(slideOffset) >= Physics.colW, n > 1 else { return false }
        packed = []; hillLayer = []
        while abs(slideOffset) >= Physics.colW {
            let right = slideOffset > 0
            let lost = right ? h[n - 1] : h[0]
            if right { for i in stride(from: n - 1, to: 0, by: -1) { h[i] = h[i - 1] }; h[0] = 0 }
            else { for i in 0..<(n - 1) { h[i] = h[i + 1] }; h[n - 1] = 0 }
            if right { edgeLoss.right += lost * Physics.colW } else { edgeLoss.left += lost * Physics.colW }
            slideOffset -= right ? Physics.colW : -Physics.colW
        }
        awake = true
        return true
    }

    /// The slab breaks: empties the pile and returns lumps (one per `group` columns) at their
    /// positions on `s`, for Snowpack to launch.
    func breakIntoChunks(on s: Surface, group: Int) -> [(x: Float, y: Float, mass: Float)] {
        var chunks: [(x: Float, y: Float, mass: Float)] = []
        var i = 0
        while i < h.count {
            let end = min(i + max(1, group), h.count)
            let sum = h[i..<end].reduce(0, +)
            if sum * Physics.colW > 0.5 {
                chunks.append((Float(s.x) + Float(i + end) / 2 * Physics.colW,
                               Float(s.y) + s.drop(column: (i + end) / 2) - lift - sum / Float(end - i) * 0.5,
                               sum * Physics.colW))
            }
            i = end
        }
        clear()                                                     // what's left rests on the window
        return chunks
    }

    // MARK: Mouse plow

    /// The cursor's circle (radius `plowRadius`) moved from (fromX, fromY) to (toX, toY), global,
    /// y down, through this pile on `s`. It pushes snow into one rounded hill just ahead of it:
    /// - Only what the circle really passed through is touched: in each column, snow above the
    ///   circle's lower edge *along its actual path* is cut. Nothing else on the surface changes.
    /// - The hill already in front is picked up whole and rebuilt ahead, so it travels with the circle.
    /// - The hill is a gentle bell: peak ≤ `hillHeight`·maxHeight, sides ≤ `hillSteepness` per
    ///   column. Once it's full the circle takes no more snow: it passes through, as if the rest
    ///   flows around it to the sides we can't see.
    /// - At a wall (screen edge) the hill stops against it, whole. Past the end of a window or the
    ///   Dock, the part that sticks out spills (returned, for Snowpack to turn into lumps).
    /// Returns nil if no snow was touched.
    func plow(on s: Surface, fromX: Float, fromY: Float, toX: Float, toY: Float) -> (spill: Float, rightEnd: Bool)? {
        let n = h.count, sx = Float(s.x), r = Physics.plowRadius
        let dir = toX > fromX ? 1 : -1
        let lo = min(fromX, toX), hi = max(fromX, toX)
        func col(_ x: Float) -> Int { min(n - 1, max(0, Int((x - sx) / Physics.colW))) }
        // Peak limit; on a narrow surface, also small enough that the whole bell (5σ wide) fits.
        let fits = Float(max(1, n - 1)) / 5 * Physics.hillSteepness * 1.6487
        let maxPeak = min(Physics.hillHeight * s.maxHeight, fits)
        let full = Self.bell(peak: maxPeak).volume

        // 1. Take back the hill in front of the circle (if it's the one being pushed), exactly as laid.
        let lead = col(toX + Float(dir) * r) + dir                  // first column ahead of the circle
        var carried: Float = 0
        if let old = hill {
            let near = dir > 0 ? (old.lowerBound <= lead + 2 && old.upperBound >= lead - 2 * Int(r / Physics.colW))
                               : (old.upperBound >= lead - 2 && old.lowerBound <= lead + 2 * Int(r / Physics.colW))
            if near {
                for (k, amount) in hillLayer.enumerated() {
                    let c = hillStart + k
                    guard c >= 0 && c < n else { continue }
                    let take = min(h[c], amount)                    // slumping may have moved a little
                    h[c] -= take; carried += take * Physics.colW
                }
            }
        }
        hillLayer = []

        // 2. Cut what the circle swept, front first, until the hill is full; then it just passes through.
        let base = Float(s.y) - lift
        var c = dir > 0 ? col(hi + r) : col(lo - r)
        let end = dir > 0 ? col(lo - r) : col(hi + r)
        while carried < full {
            let x = sx + (Float(c) + 0.5) * Physics.colW
            let nearest = max(lo, min(hi, x))                       // closest point of the path (in x)
            let dx = x - nearest
            if abs(dx) <= r {
                let t = hi > lo ? (nearest - fromX) / (toX - fromX) : 1
                let pathY = fromY + (toY - fromY) * max(0, min(1, t))      // the circle's height there
                let circleBottom = pathY + (r * r - dx * dx).squareRoot()
                let keep = max(0, base + s.drop(column: c) - circleBottom) // snow below the circle stays
                let cut = min(max(0, h[c] - keep), (full - carried) / Physics.colW)
                if cut > 0 { h[c] -= cut; carried += cut * Physics.colW }
            }
            if c == end { break }
            c -= dir
        }
        guard carried > 0.01 else { return nil }
        if packed.count != n { packed = Array(repeating: 0, count: n) }

        // 3. Lay the hill ahead: the bell whose volume is exactly `carried` (peak solved by bisection).
        var low: Float = 0, high = maxPeak
        for _ in 0..<24 { let mid = (low + high) / 2; if Self.bell(peak: mid).volume < carried { low = mid } else { high = mid } }
        let b = Self.bell(peak: high)
        let scale = carried / b.volume                              // ≈ 1; makes the volume exact
        var center = lead + dir * b.back                            // the back slope starts at the circle
        if !s.dropsAtEdges {                                        // a wall: the hill stops against it
            if dir > 0 { center = min(center, n - 1 - b.front) } else { center = max(center, b.front) }
        }
        var layer = [Float](repeating: 0, count: n)
        var spill: Float = 0
        for (k, w) in b.weights.enumerated() {
            var a = center + dir * (k - b.back)
            let amount = w * high * scale
            if a < 0 || a >= n {
                if s.dropsAtEdges { spill += amount * Physics.colW; continue }   // sticks out past the end: falls
                a = a < 0 ? min(n - 1, -a - 1) : max(0, 2 * n - 1 - a)          // folds back off a wall
            }
            layer[a] += amount
        }
        if let first = layer.firstIndex(where: { $0 > 0 }), let last = layer.lastIndex(where: { $0 > 0 }) {
            hillStart = first
            hillLayer = Array(layer[first...last])
            for c in first...last { h[c] += layer[c]; packed[c] = 1 }
        }
        awake = true
        return (spill, dir > 0)
    }

    /// A rounded hill (Gaussian) with this peak height: σ grows with the peak so the steepest slope is
    /// always `hillSteepness` per column. Truncated at −2σ (behind) … +3σ (ahead).
    static func bell(peak: Float) -> (weights: [Float], back: Int, front: Int, volume: Float) {
        let sigma = max(1, peak / (Physics.hillSteepness * 1.6487))      // steepest slope = peak / (σ√e)
        let back = Int((2 * sigma).rounded(.up)), front = Int((3 * sigma).rounded(.up))
        let weights = (-back...front).map { j -> Float in let z = Float(j) / sigma; return exp(-z * z / 2) }
        return (weights, back, front, peak * weights.reduce(0, +) * Physics.colW)
    }

    // MARK: Slumping

    /// One 20 Hz step of the sand-pile rule on `s`: steep spots slide down (packed snow holds
    /// steeper), snow past a dropping edge goes to `edgeLoss`. Returns true if anything moved.
    func slump(on s: Surface) -> Bool {
        var moved: Float = 0
        let n = h.count
        if n > 1 {
            // Compare snow *tops* (height minus the corner curve), so snow slides down rounded corners.
            var bi = s.drop(column: 0)
            let isPacked = !packed.isEmpty
            for i in 0..<(n - 1) {
                let bj = s.drop(column: i + 1)
                let d = (h[i] - bi) - (h[i + 1] - bj)
                let sticky = Physics.maxSlope * cohesion(at: i)
                let slope = isPacked ? sticky * (1 + 2 * max(packed[i], packed[i + 1])) : sticky
                if abs(d) > slope {
                    var t = (abs(d) - slope) * 0.25
                    t = min(t, d > 0 ? h[i] : h[i + 1])
                    if d < 0 { t = -t }
                    h[i] -= t; h[i + 1] += t; moved += abs(t)
                }
                bi = bj
            }
        }
        if s.dropsAtEdges {
            // Treat outside the edge as height 0: steep snow slides off.
            let leftHold = Physics.maxSlope * cohesion(at: -1), rightHold = Physics.maxSlope * cohesion(at: n)
            if h[0] > leftHold {
                let t = (h[0] - leftHold) * 0.25
                h[0] -= t; edgeLoss.left += t * Physics.colW; moved += t
            }
            if h[n - 1] > rightHold {
                let t = (h[n - 1] - rightHold) * 0.25
                h[n - 1] -= t; edgeLoss.right += t * Physics.colW; moved += t
            }
        }
        if !packed.isEmpty {
            var still = false
            for i in packed.indices { packed[i] *= Physics.packedSettle; if packed[i] > 0.05 { still = true } }
            if !still { packed = [] }
        }
        awake = moved > 0.001 || !packed.isEmpty                    // asleep until something lands on it
        return moved > 0.001
    }
}
