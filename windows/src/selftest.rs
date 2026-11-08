//! `snowdrift.exe --selftest`: the same physics checks as the macOS version, scenario for scenario
//! (including window motion recorded on a real Mac). Returns the failures (empty = all good).

use crate::model::*;
use crate::physics::*;
use crate::snowpack::{FrameInput, Snowpack};

fn surface(key: SurfaceKey, x: f32, y: f32, width: f32, height: f32, drops: bool, max: f32) -> Surface {
    Surface { key, x, y, width, height, depth: 0.5, drops_at_edges: drops, max_height: max, radius: 0.0, vx: 0.0, vy: 0.0 }
}

fn filled(columns: i32, height: f32) -> Pile {
    let mut p = Pile::new(columns, 7);
    p.h.iter_mut().for_each(|v| *v = height);
    p
}

pub fn run(snowpack: &mut Snowpack) -> Vec<String> {
    let mut fail = Vec::new();
    let win = surface(SurfaceKey::Window(999_999), 100.0, 500.0, 200.0, 300.0, true, WINDOW_MAX);
    let ground = surface(SurfaceKey::Ground(99), 0.0, 900.0, 100.0, 0.0, false, GROUND_MAX);

    // 1. Plow through a window's snow (8 deep): nothing lost; a rounded hill, at most
    //    HILL_HEIGHT·max above the snow, with a peak (not a flat top).
    let max_hill = HILL_HEIGHT * WINDOW_MAX;
    let mut p = filled(100, 8.0);
    let before = p.mass();
    let r1 = p.plow(&win, 140.0, 497.0, 200.0, 497.0);
    let spill1 = r1.map(|r| r.0).unwrap_or(0.0);
    if (p.mass() + spill1 - before).abs() > 0.01 { fail.push(format!("plow: mass {before} -> {} + {spill1}", p.mass())); }
    let top = p.h.iter().cloned().fold(0.0, f32::max);
    if top <= 8.5 { fail.push(format!("plow: no hill formed (max {top})")); }
    if top > 8.0 + max_hill + 0.01 { fail.push(format!("plow: hill {} above the snow, limit {max_hill}", top - 8.0)); }
    if p.h.iter().filter(|v| **v > top - 0.01).count() > 3 { fail.push("plow: hill has a flat top".into()); }

    // 2. Local: snow away from the path and the hill is untouched; a pointer coming in from high
    //    above cuts nothing where it was above the snow.
    let hill_end = p.hill().map(|h| h.1).unwrap_or(99) as usize;
    if p.h[0..14].iter().any(|v| *v != 8.0) { fail.push("plow: changed snow behind the circle's path".into()); }
    if hill_end < 99 && p.h[hill_end + 1..].iter().any(|v| *v != 8.0) { fail.push("plow: changed snow beyond the hill".into()); }
    let mut diag = filled(100, 8.0);
    let _ = diag.plow(&win, 110.0, 300.0, 200.0, 497.0);
    if diag.h[0..30].iter().any(|v| *v != 8.0) { fail.push("plow: cut snow where the pointer was above it".into()); }

    // 3. Keep pushing: the hill never grows past its limit, snow is kept.
    let mut long = filled(100, 8.0);
    let long_before = long.mass();
    let (mut spilled, mut tallest) = (0.0f32, 0.0f32);
    for step in 0..60 {
        let x0 = 110.0 + step as f32 * 2.0;
        spilled += long.plow(&win, x0, 497.0, x0 + 2.0, 497.0).map(|r| r.0).unwrap_or(0.0);
        tallest = tallest.max(long.h.iter().cloned().fold(0.0, f32::max));
    }
    if tallest > 8.0 + max_hill + 0.01 { fail.push(format!("plow: long push grew the hill to {}", tallest - 8.0)); }
    if (long.mass() + spilled - long_before).abs() > 0.05 { fail.push(format!("plow: long push mass {long_before} -> {} + {spilled}", long.mass())); }

    // 3b. Into a window's end: the part past the end spills, nothing is lost.
    let mut q = filled(100, 8.0);
    let q_before = q.mass();
    let spill2 = q.plow(&win, 240.0, 497.0, 299.0, 497.0).map(|r| r.0).unwrap_or(0.0);
    if spill2 <= 0.0 { fail.push("plow: nothing fell off the end".into()); }
    if (q.mass() + spill2 - q_before).abs() > 0.01 { fail.push(format!("plow: end mass {q_before} -> {} + {spill2}", q.mass())); }

    // 3c. Into the screen edge (ground): the hill stops against it, no spike, nothing lost.
    let mut g = filled(50, 20.0);
    let g_before = g.mass();
    let mut g_spill = 0.0;
    for step in 0..40 { let x0 = 20.0 + step as f32 * 2.0; g_spill += g.plow(&ground, x0, 895.0, x0 + 2.0, 895.0).map(|r| r.0).unwrap_or(0.0); }
    if (g.mass() - g_before).abs() > 0.05 || g_spill > 0.0 { fail.push(format!("ground: mass {g_before} -> {}", g.mass())); }
    if g.h.iter().cloned().fold(0.0, f32::max) > 20.0 + HILL_HEIGHT * GROUND_MAX + 0.01 { fail.push("ground: spike at the screen edge".into()); }

    // 4. Slab fed the positions measured from a steady 400 pt/s move up (3–11 per 60 Hz sample):
    //    never lifts. Window stops: a small hop that lands back. Fast downward flick: it breaks.
    let throw_cap = 1700.0;
    let mut slab = Pile::new(10, 3);
    let steps = [-4.0, -10.0, -6.0, -7.0, -3.0, -11.0, -6.0, -7.0, -3.0, -10.0, -7.0, -7.0, -3.0, -10.0, -6.0, -7.0, -3.0, -11.0, -6.0, -7.0];
    let (mut y, mut v, mut max_lift) = (600.0f32, 0.0f32, 0.0f32);
    for _ in 0..3 { for d in steps { y += d; v = v * 0.5 + d * 60.0 * 0.5; max_lift = max_lift.max(slab.step_slab(y, v, 1.0 / 60.0, throw_cap).unwrap_or(999.0)); } }
    if max_lift > 0.0 { fail.push(format!("slab: lifted {max_lift} during a steady upward move")); }
    let (mut hop, mut landed) = (0.0f32, false);
    for i in 0..90 {
        v *= 0.5;
        match slab.step_slab(y, v, 1.0 / 60.0, throw_cap) {
            None => { fail.push("slab: broke on a stop".into()); break; }
            Some(l) => { hop = hop.max(l); if i > 5 && slab.contact { landed = true; break; } }
        }
    }
    if hop < 5.0 || hop > BREAK_LIFT { fail.push(format!("slab: hop after stopping was {hop}")); }
    if !landed { fail.push("slab: didn't land back after the hop".into()); }
    let mut broke = false;
    for _ in 0..30 { y += 20.0; if slab.step_slab(y, 1200.0, 1.0 / 60.0, throw_cap).is_none() { broke = true; break; } }
    if !broke { fail.push("slab: a 1200/s downward flick didn't break it".into()); }

    // 5. Sideways friction: measured jitter doesn't slide; a sudden stop from 500/s slides on.
    let mut side = Pile::new(10, 5);
    let jitter = [315.0, 453.0, 405.0, 419.0, 298.0, 479.0, 428.0, 420.0, 299.0, 445.0, 441.0, 426.0, 305.0, 442.0, 406.0, 411.0, 293.0, 478.0, 421.0, 414.0];
    let mut drift = 0.0;
    for _ in 0..3 { for v in jitter { drift += side.step_sideways(v, 1.0 / 60.0); } }
    if drift.abs() > 0.5 { fail.push(format!("sideways: jitter made the snow slide {drift}")); }
    let mut stop = Pile::new(10, 6);
    for _ in 0..20 { stop.step_sideways(500.0, 1.0 / 60.0); }
    let mut slid = 0.0;
    for _ in 0..80 { slid += stop.step_sideways(0.0, 1.0 / 60.0); }
    if !(20.0..=120.0).contains(&slid) { fail.push(format!("sideways: sudden stop at 500/s slid {slid}")); }

    // 6. Slumping and sliding keep the snow; slumping stops by itself, keeps steeper (sticky)
    //    spots, and never leaves a step steeper than the stickiest allows.
    let mut s6 = filled(100, 0.0);
    for i in 40..60 { s6.h[i] = 9.0; }
    let s6_before = s6.mass();
    for _ in 0..200 { s6.slump(&win); }
    s6.slide_offset = 30.0;
    s6.apply_slide();
    if (s6.mass() + s6.edge_loss.0 + s6.edge_loss.1 - s6_before).abs() > 0.01 { fail.push("slump/slide: snow not conserved".into()); }
    let mut rough = Pile::new(120, 11);
    for i in 0..120 { rough.h[i] = ((i * 37) % 11) as f32; }
    let rough_before = rough.mass();
    let mut ticks = 0;
    while rough.awake && ticks < 600 { rough.slump(&ground); ticks += 1; }
    if rough.awake { fail.push("slump: still moving after 30 s".into()); }
    let (mut steepest, mut steep_spots) = (0.0f32, 0);
    for i in 0..rough.h.len() - 1 {
        let step = (rough.h[i] - rough.h[i + 1]).abs();
        steepest = steepest.max(step);
        if step > MAX_SLOPE * 1.05 { steep_spots += 1; }
    }
    if steepest > MAX_SLOPE * COHESION.1 + 0.01 { fail.push(format!("slump: left a {steepest} step")); }
    if steep_spots < 10 { fail.push(format!("slump: smoothed out ({steep_spots} steep spots left)")); }
    if (rough.mass() - rough_before).abs() > 0.05 { fail.push("slump: snow not conserved".into()); }

    // 7. Displays change, and no displays at all: no crash, maps follow.
    let original = snowpack.screens.clone();
    let input = FrameInput { windows: &[], taskbar: None, full_screen_hint: false, mouse: (0.0, 0.0) };
    if let Some(first) = original.first() {
        let mut second = *first;
        second.frame.x += first.frame.w;
        let mut two = original.clone(); two.push(second);
        snowpack.reset_screens(two);
        snowpack.frame(1.0, &input);
        if snowpack.maps.len() != original.len() + 1 { fail.push("displays: maps not resized".into()); }
        snowpack.reset_screens(original.clone());
        snowpack.frame(2.0, &input);
        if snowpack.maps.len() != original.len() { fail.push("displays: maps not restored".into()); }
        if snowpack.piles.keys().any(|k| matches!(k, SurfaceKey::Ground(i) if *i >= original.len())) { fail.push("displays: ground pile left for a removed screen".into()); }
    }
    snowpack.reset_screens(Vec::new());
    snowpack.frame(3.0, &input);
    snowpack.reset_screens(original);

    // 8. Lumps fade: full at the start, gone at their reach.
    let mut lump = Clump { x: 0.0, y: 0.0, vx: 0.0, vy: 0.0, mass: 1.0, size: 3.0, gk: 1.0, fallen: 0.0, reach: 300.0 };
    if lump.alpha() < 0.999 { fail.push("lump: not fully visible at start".into()); }
    lump.fallen = 300.0;
    if lump.alpha() > 0.001 { fail.push("lump: still visible at its reach".into()); }

    // 9. Settings file: round trip; bad or unknown values fall back to the defaults.
    use crate::settings::Settings;
    let s = Settings { snowfall: 2, wind: 0, hide_from_sharing: false };
    let text = format!("snowfall={}\nwind={}\nhide_from_sharing={}\n", s.snowfall, s.wind, s.hide_from_sharing as u8);
    if Settings::parse(&text) != s { fail.push("settings: round trip changed them".into()); }
    if Settings::parse("snowfall=9\nwind=-1\njunk\n") != Settings::default() { fail.push("settings: bad values not ignored".into()); }
    fail
}
