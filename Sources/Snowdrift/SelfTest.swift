import QuartzCore

/// `Snowdrift --selftest`: checks the physics invariants on synthetic data, including window
/// motion recorded on a real Mac. Returns the failures (empty = all good).
@MainActor
func selfTest(_ snowpack: Snowpack) -> [String] {
    var fail: [String] = []
    let win = Surface(key: .window(999_999), x: 100, y: 500, width: 200, height: 300, depth: 0.5,
                      dropsAtEdges: true, maxHeight: Physics.windowMax)
    let ground = Surface(key: .ground(99), x: 0, y: 900, width: 100, height: 0, depth: 0.95,
                         dropsAtEdges: false, maxHeight: Physics.groundMax)
    func filled(_ columns: Int, _ height: Float) -> Pile {
        let p = Pile(columns: columns)
        for i in p.h.indices { p.h[i] = height }
        return p
    }

    // 1. Plow through a window's snow (8 pt deep): nothing created or lost; a rounded hill forms,
    //    at most hillHeight·maxHeight above the snow, with a peak (not a flat top).
    let maxHill = Physics.hillHeight * Physics.windowMax
    let p = filled(100, 8)
    let before = p.mass
    let r1 = p.plow(on: win, fromX: 140, fromY: 497, toX: 200, toY: 497)    // cursor 3 pt above the base
    if abs(p.mass + (r1?.spill ?? 0) - before) > 0.01 { fail.append("plow: mass \(before) -> \(p.mass) + \(r1?.spill ?? 0) spilled") }
    let top = p.h.max() ?? 0
    if top <= 8.5 { fail.append("plow: no hill formed (max \(top))") }
    if top > 8 + maxHill + 0.01 { fail.append("plow: hill \(top - 8) pt above the snow, limit \(maxHill)") }
    if p.h.filter({ $0 > top - 0.01 }).count > 3 { fail.append("plow: hill has a flat top") }

    // 2. Local: snow away from the circle's path and the hill is untouched.
    let hillEnd = p.hill?.upperBound ?? 99
    if p.h[0..<14].contains(where: { $0 != 8 }) { fail.append("plow: changed snow behind the circle's path") }
    if hillEnd < 99, p.h[(hillEnd + 1)...].contains(where: { $0 != 8 }) { fail.append("plow: changed snow beyond the hill") }
    let diag = filled(100, 8)
    _ = diag.plow(on: win, fromX: 110, fromY: 300, toX: 200, toY: 497)      // came in from high above
    if diag.h[0..<30].contains(where: { $0 != 8 }) { fail.append("plow: cut snow where the pointer was above it") }

    // 3. Keep pushing across: the hill never grows past its limit, snow is kept.
    let long = filled(100, 8)
    let longBefore = long.mass
    var spilled: Float = 0, tallest: Float = 0
    for step in 0..<60 {
        let x0 = 110 + Float(step) * 2
        spilled += long.plow(on: win, fromX: x0, fromY: 497, toX: x0 + 2, toY: 497)?.spill ?? 0
        tallest = max(tallest, long.h.max() ?? 0)
    }
    if tallest > 8 + maxHill + 0.01 { fail.append("plow: long push grew the hill to \(tallest - 8) pt") }
    if abs(long.mass + spilled - longBefore) > 0.05 { fail.append("plow: long push mass \(longBefore) -> \(long.mass) + \(spilled)") }

    // 3b. Into a window's end: the part past the end falls (spill), nothing is lost.
    let q = filled(100, 8)
    let qBefore = q.mass
    let r2 = q.plow(on: win, fromX: 240, fromY: 497, toX: 299, toY: 497)
    if (r2?.spill ?? 0) <= 0 { fail.append("plow: nothing fell off the end") }
    if abs(q.mass + (r2?.spill ?? 0) - qBefore) > 0.01 { fail.append("plow: end mass \(qBefore) -> \(q.mass) + \(r2?.spill ?? 0)") }

    // 3c. Into the screen edge (ground): the hill stops against it, no spike, nothing lost.
    let g = filled(50, 20)
    let gBefore = g.mass
    var gSpill: Float = 0
    for step in 0..<40 { let x0 = 20 + Float(step) * 2; gSpill += g.plow(on: ground, fromX: x0, fromY: 895, toX: x0 + 2, toY: 895)?.spill ?? 0 }
    if abs(g.mass - gBefore) > 0.05 || gSpill > 0 { fail.append("ground: mass \(gBefore) -> \(g.mass)") }
    if (g.h.max() ?? 0) > 20 + Physics.hillHeight * Physics.groundMax + 0.01 { fail.append("ground: spike at the screen edge (\(g.h.max() ?? 0))") }

    // 4. Slab, fed the jittery positions measured from a steady 400 pt/s move up (3–11 pt per
    //    60 Hz sample): it must never lift. Then the window stops: a small hop that lands back
    //    without breaking. Then a fast downward flick: it breaks.
    let throwCap: Float = 1700
    let slab = Pile(columns: 10)
    let steps: [Float] = [-4, -10, -6, -7, -3, -11, -6, -7, -3, -10, -7, -7, -3, -10, -6, -7, -3, -11, -6, -7]
    var y: Float = 600, v: Float = 0, maxLift: Float = 0
    for _ in 0..<3 {
        for d in steps {
            y += d; v = v * 0.5 + d * 60 * 0.5
            maxLift = max(maxLift, slab.stepSlab(yw: y, vw: v, dt: 1.0 / 60, maxThrowSpeed: throwCap) ?? 999)
        }
    }
    if maxLift > 0 { fail.append("slab: lifted \(maxLift) pt during a steady upward move") }
    var hop: Float = 0, landed = false
    for i in 0..<90 {
        v *= 0.5                                                           // stopped (smoothed speed decays)
        guard let l = slab.stepSlab(yw: y, vw: v, dt: 1.0 / 60, maxThrowSpeed: throwCap) else { fail.append("slab: broke on a stop"); break }
        hop = max(hop, l)
        if i > 5 && slab.contact { landed = true; break }
    }
    if hop < 5 || hop > Physics.breakLift { fail.append("slab: hop after stopping was \(hop) pt") }
    if !landed { fail.append("slab: didn't land back after the hop") }
    var broke = false
    for _ in 0..<30 { y += 20; if slab.stepSlab(yw: y, vw: 1200, dt: 1.0 / 60, maxThrowSpeed: throwCap) == nil { broke = true; break } }
    if !broke { fail.append("slab: a 1200 pt/s downward flick didn't break it") }

    // 5. Sideways friction: measured jittery speeds must not make the snow slide; a sudden stop
    //    from 500 pt/s must slide it onward.
    let side = Pile(columns: 10)
    let jitter: [Float] = [315, 453, 405, 419, 298, 479, 428, 420, 299, 445, 441, 426, 305, 442, 406, 411, 293, 478, 421, 414]
    var drift: Float = 0
    for _ in 0..<3 { for v in jitter { drift += side.stepSideways(vx: v, dt: 1.0 / 60) } }
    if abs(drift) > 0.5 { fail.append("sideways: jitter made the snow slide \(drift) pt") }
    let stop = Pile(columns: 10)
    for _ in 0..<20 { _ = stop.stepSideways(vx: 500, dt: 1.0 / 60) }
    var slid: Float = 0
    for _ in 0..<80 { slid += stop.stepSideways(vx: 0, dt: 1.0 / 60) }
    if slid < 20 || slid > 120 { fail.append("sideways: sudden stop at 500 pt/s slid \(slid) pt") }

    // 6. Slumping and sliding keep the snow (edges only move it to edgeLoss).
    let s6 = filled(100, 0)
    for i in 40..<60 { s6.h[i] = 9 }
    let s6Before = s6.mass
    for _ in 0..<200 { _ = s6.slump(on: win) }
    s6.slideOffset = 30
    _ = s6.applySlide()
    if abs(s6.mass + s6.edgeLoss.left + s6.edgeLoss.right - s6Before) > 0.01 { fail.append("slump/slide: snow not conserved") }

    // 6b. Slumping on a rough pile stops by itself (every spot under its own cohesion), never ends
    //     steeper than the stickiest spot allows, and keeps bumps (not a smooth ramp).
    let rough = Pile(columns: 120)
    for i in rough.h.indices { rough.h[i] = Float((i * 37) % 11) }           // jagged 0–10 pt
    let roughBefore = rough.mass
    var ticks = 0
    while rough.awake && ticks < 600 { _ = rough.slump(on: ground); ticks += 1 }   // ground: no edge loss
    if rough.awake { fail.append("slump: still moving after 30 s") }
    var steepest: Float = 0, steepSpots = 0
    for i in 0..<(rough.h.count - 1) {
        let step = abs(rough.h[i] - rough.h[i + 1])
        steepest = max(steepest, step)
        if step > Physics.maxSlope * 1.05 { steepSpots += 1 }       // steeper than one uniform limit allows
    }
    if steepest > Physics.maxSlope * Physics.cohesion.upperBound + 0.01 { fail.append("slump: left a \(steepest) pt step") }
    // Uniform slumping flattens every step to ≤ maxSlope; sticky spots must keep some steeper ones.
    if steepSpots < 10 { fail.append("slump: smoothed out (\(steepSpots) steep spots left)") }
    if abs(rough.mass - roughBefore) > 0.05 { fail.append("slump: snow \(roughBefore) -> \(rough.mass)") }

    // 7. Displays change: two screens, then back to the original one. No crash, maps follow.
    let original = snowpack.screens
    if let first = original.first {
        var second = first
        second.frame = first.frame.offsetBy(dx: first.frame.width, dy: 0)
        snowpack.resetScreens(original + [second])
        snowpack.frame(now: CACurrentMediaTime() + 1)
        if snowpack.maps.count != original.count + 1 { fail.append("displays: maps not resized") }
        snowpack.resetScreens(original)
        snowpack.frame(now: CACurrentMediaTime() + 2)
        if snowpack.maps.count != original.count { fail.append("displays: maps not restored") }
        if snowpack.piles.keys.contains(where: { if case .ground(let i) = $0 { return i >= original.count } else { return false } }) {
            fail.append("displays: ground pile left for a removed screen")
        }
    }
    snowpack.resetScreens([])                                               // no displays at all: no crash
    snowpack.frame(now: CACurrentMediaTime() + 3)
    snowpack.resetScreens(original)

    // 8. Lumps fade: full at the start, gone at their reach.
    var lump = Clump(x: 0, y: 0, vx: 0, vy: 0, mass: 1, size: 3, gk: 1, reach: 300)
    if lump.alpha < 0.999 { fail.append("lump: not fully visible at start") }
    lump.fallen = 300
    if lump.alpha > 0.001 { fail.append("lump: still visible at its reach") }
    return fail
}
