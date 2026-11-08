//! Surfaces, lumps, piles and the per-pile physics: a line-for-line port of macOS `Model.swift`.
//! Anything that creates falling lumps is reported back to `Snowpack`.

use crate::physics::*;

/// A rectangle in global DIPs (y down).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect { pub x: f32, pub y: f32, pub w: f32, pub h: f32 }
impl Rect {
    pub fn max_x(&self) -> f32 { self.x + self.w }
    pub fn max_y(&self) -> f32 { self.y + self.h }
}

/// One screen: its rect in global DIPs and its flakes' landing rate (set by the renderer).
#[derive(Clone, Copy, Debug, Default)]
pub struct ScreenInfo { pub frame: Rect, pub landing_rate: f32 }

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SurfaceKey { Window(isize), Dock, Ground(usize) }

/// Something snow can sit on, this frame. Snow sits *above* `y`.
#[derive(Clone, Copy, Debug)]
pub struct Surface {
    pub key: SurfaceKey,
    pub x: f32, pub y: f32, pub width: f32, pub height: f32,
    pub depth: f32,                     // 0 = nearest; windows front to back
    pub drops_at_edges: bool,           // ground is held by the screen edges
    pub max_height: f32,
    pub radius: f32,                    // rounded top corners
    pub vx: f32, pub vy: f32,           // window velocity (DIP/s, smoothed)
}

impl Surface {
    /// How far the top edge has curved down at local x (0 in the flat middle).
    pub fn drop_at(&self, x: f32) -> f32 {
        let d = x.min(self.width - x);
        if d >= self.radius { return 0.0; }
        let e = self.radius - d.max(0.0);
        self.radius - (self.radius * self.radius - e * e).sqrt()
    }
    pub fn drop(&self, c: i32) -> f32 { self.drop_at((c as f32 + 0.5) * COL_W) }
}

/// A free-flying lump of snow. CPU particle; usually there are none.
#[derive(Clone, Copy, Debug)]
pub struct Clump { pub x: f32, pub y: f32, pub vx: f32, pub vy: f32, pub mass: f32, pub size: f32, pub gk: f32, pub fallen: f32, pub reach: f32 }

impl Clump {
    /// Lumps thin out as they fall and are gone after `reach`, each its own, so one by one.
    pub fn alpha(&self) -> f32 {
        let t = ((self.fallen - 0.35 * self.reach) / (0.65 * self.reach)).clamp(0.0, 1.0);
        1.0 - t * t * (3.0 - 2.0 * t)
    }
}

/// Snow on one surface: a height per column, anchored to the surface's left edge.
pub struct Pile {
    pub h: Vec<f32>,
    pub awake: bool,
    pub edge_loss: (f32, f32),
    pub slide_offset: f32,
    pub contact: bool, slab_ready: bool,
    ghost_y: f32, ghost_v: f32,
    slab_y: f32, pub slab_v: f32,
    pub lift: f32,
    pub us: f32, wvx: f32, sliding: bool, side_ready: bool,
    pub packed: Vec<f32>,
    pub hill_start: i32,
    pub hill_layer: Vec<f32>,
    seed: u32,
}

pub struct Bell { pub weights: Vec<f32>, pub back: i32, pub front: i32, pub volume: f32 }

impl Pile {
    pub fn new(columns: i32, seed: u32) -> Pile {
        Pile {
            h: vec![0.0; columns.max(1) as usize], awake: true, edge_loss: (0.0, 0.0), slide_offset: 0.0,
            contact: true, slab_ready: false, ghost_y: 0.0, ghost_v: 0.0, slab_y: 0.0, slab_v: 0.0, lift: 0.0,
            us: 0.0, wvx: 0.0, sliding: false, side_ready: false, packed: Vec::new(),
            hill_start: 0, hill_layer: Vec::new(), seed: seed.max(1),
        }
    }

    pub fn hill(&self) -> Option<(i32, i32)> {
        if self.hill_layer.is_empty() { None } else { Some((self.hill_start, self.hill_start + self.hill_layer.len() as i32 - 1)) }
    }

    /// How steep the snow can stand between columns i and i+1 (× MAX_SLOPE): a stable random value per spot.
    pub fn cohesion(&self, i: i32) -> f32 {
        let mut x = (i as u32).wrapping_mul(2654435761) ^ self.seed;
        x ^= x >> 15; x = x.wrapping_mul(2246822519); x ^= x >> 13;
        let r = (x & 0xffff) as f32 / 65535.0;
        COHESION.0 + r * (COHESION.1 - COHESION.0)
    }

    pub fn mass(&self) -> f32 { self.h.iter().sum::<f32>() * COL_W }
    pub fn mean(&self) -> f32 { self.h.iter().sum::<f32>() / self.h.len() as f32 }
    pub fn n(&self) -> i32 { self.h.len() as i32 }

    pub fn clear(&mut self) {
        self.h.iter_mut().for_each(|v| *v = 0.0);
        self.packed.clear(); self.hill_layer.clear(); self.edge_loss = (0.0, 0.0); self.slide_offset = 0.0;
        self.contact = true; self.slab_ready = false; self.lift = 0.0; self.sliding = false; self.side_ready = false; self.awake = true;
    }

    /// Change the number of columns. Returns the snow cut off the right end.
    pub fn resize(&mut self, columns: i32) -> f32 {
        let cols = columns.max(1) as usize;
        if cols == self.h.len() { return 0.0; }
        self.packed.clear(); self.hill_layer.clear(); self.awake = true;
        if cols < self.h.len() {
            let cut = self.h[cols..].iter().sum::<f32>() * COL_W;
            self.h.truncate(cols);
            return cut;
        }
        self.h.resize(cols, 0.0);
        0.0
    }

    /// Add snow around a column, spread over 5 columns (soft lumps).
    pub fn deposit(&mut self, col: i32, mass: f32) {
        if mass <= 0.0 { return; }
        let weights = [0.1, 0.2, 0.4, 0.2, 0.1];
        let height = mass / COL_W;
        for (o, w) in weights.iter().enumerate() {
            let c = col + o as i32 - 2;
            if c >= 0 && c < self.n() { self.h[c as usize] += height * w; }
        }
        self.awake = true;
    }

    /// One step of a window's snow slab (see macOS `stepSlab`). Returns the lift, or None if it broke.
    pub fn step_slab(&mut self, yw: f32, vw: f32, dt: f32, max_throw_speed: f32) -> Option<f32> {
        if !self.slab_ready { self.ghost_y = yw; self.ghost_v = vw; self.slab_ready = true; }
        if self.contact {
            self.ghost_v = (self.ghost_v + SLAB_GRAVITY * dt).min(2000.0);
            self.ghost_y += self.ghost_v * dt;
            if yw <= self.ghost_y {
                self.ghost_y = yw; self.ghost_v = vw;
            } else if yw - self.ghost_y > 3.0 + 1.2 * vw.abs() / 60.0 {
                self.contact = false;
                self.slab_y = yw;
                self.slab_v = self.ghost_v.max(-max_throw_speed);
            }
            self.lift = 0.0;
            return Some(0.0);
        }
        self.slab_v = (self.slab_v + SLAB_GRAVITY * dt).min(2000.0);
        self.slab_y += self.slab_v * dt;
        if self.slab_y >= yw {
            self.contact = true; self.ghost_y = yw; self.ghost_v = vw; self.lift = 0.0;
            return Some(0.0);
        }
        self.lift = yw - self.slab_y;
        if self.lift > BREAK_LIFT { None } else { Some(self.lift) }
    }

    /// Sideways friction (see macOS `stepSideways`); returns how far the snow slid this step.
    pub fn step_sideways(&mut self, vx: f32, dt: f32) -> f32 {
        if !self.side_ready { self.wvx = vx; self.us = vx; self.side_ready = true; }
        let before = self.wvx;
        self.wvx += (vx - self.wvx) * (dt / SIDE_SMOOTHING).min(1.0);
        let accel = (self.wvx - before) / dt;
        let grip = STATIC_FRICTION * SLAB_GRAVITY;
        if !self.sliding {
            if accel.abs() > grip { self.sliding = true; self.us = before; } else { self.us = self.wvx; return 0.0; }
        }
        let rel = self.us - self.wvx;
        let brake = KINETIC_FRICTION * SLAB_GRAVITY * dt;
        if rel.abs() <= brake && accel.abs() <= grip {
            self.sliding = false; self.us = self.wvx;
            return rel * dt;
        }
        self.us -= if rel > 0.0 { brake } else { -brake };
        (self.us - self.wvx) * dt
    }

    /// Apply the slide in whole columns; snow pushed past an end goes to `edge_loss`.
    pub fn apply_slide(&mut self) -> bool {
        let n = self.h.len();
        if self.slide_offset.abs() < COL_W || n < 2 { return false; }
        self.packed.clear(); self.hill_layer.clear();
        while self.slide_offset.abs() >= COL_W {
            let right = self.slide_offset > 0.0;
            let lost = if right { self.h[n - 1] } else { self.h[0] };
            if right { self.h.rotate_right(1); self.h[0] = 0.0; } else { self.h.rotate_left(1); self.h[n - 1] = 0.0; }
            if right { self.edge_loss.1 += lost * COL_W } else { self.edge_loss.0 += lost * COL_W }
            self.slide_offset -= if right { COL_W } else { -COL_W };
        }
        self.awake = true;
        true
    }

    /// The slab breaks: empties the pile and returns lumps (x, y, mass) on `s`.
    pub fn break_into_chunks(&mut self, s: &Surface, group: usize) -> Vec<(f32, f32, f32)> {
        let mut chunks = Vec::new();
        let mut i = 0;
        while i < self.h.len() {
            let end = (i + group.max(1)).min(self.h.len());
            let sum: f32 = self.h[i..end].iter().sum();
            if sum * COL_W > 0.5 {
                chunks.push((s.x + (i + end) as f32 / 2.0 * COL_W,
                             s.y + s.drop(((i + end) / 2) as i32) - self.lift - sum / (end - i) as f32 * 0.5,
                             sum * COL_W));
            }
            i = end;
        }
        self.clear();
        chunks
    }

    /// A rounded hill (Gaussian) with this peak: σ grows with the peak, truncated at −2σ … +3σ.
    pub fn bell(peak: f32) -> Bell {
        let sigma = (peak / (HILL_STEEPNESS * 1.6487)).max(1.0);
        let back = (2.0 * sigma).ceil() as i32;
        let front = (3.0 * sigma).ceil() as i32;
        let weights: Vec<f32> = (-back..=front).map(|j| { let z = j as f32 / sigma; (-z * z / 2.0).exp() }).collect();
        let volume = peak * weights.iter().sum::<f32>() * COL_W;
        Bell { weights, back, front, volume }
    }

    /// The cursor's circle moved from (fx, fy) to (tx, ty) through this pile on `s` (see macOS `plow`).
    /// Returns Some((spill, right_end)) if any snow moved.
    pub fn plow(&mut self, s: &Surface, fx: f32, fy: f32, tx: f32, ty: f32) -> Option<(f32, bool)> {
        let n = self.n();
        let (sx, r) = (s.x, PLOW_RADIUS);
        let dir: i32 = if tx > fx { 1 } else { -1 };
        let (lo, hi) = (fx.min(tx), fx.max(tx));
        let col = |x: f32| -> i32 { (((x - sx) / COL_W) as i32).clamp(0, n - 1) };
        let fits = (n - 1).max(1) as f32 / 5.0 * HILL_STEEPNESS * 1.6487;
        let max_peak = (HILL_HEIGHT * s.max_height).min(fits);
        let full = Pile::bell(max_peak).volume;

        // 1. Take back the hill in front of the circle, exactly as laid.
        let lead = col(tx + dir as f32 * r) + dir;
        let mut carried = 0.0f32;
        if let Some((first, last)) = self.hill() {
            let reach = 2 * (r / COL_W) as i32;
            let near = if dir > 0 { first <= lead + 2 && last >= lead - reach } else { last >= lead - 2 && first <= lead + reach };
            if near {
                for (k, amount) in self.hill_layer.clone().into_iter().enumerate() {
                    let c = self.hill_start + k as i32;
                    if c < 0 || c >= n { continue; }
                    let take = self.h[c as usize].min(amount);
                    self.h[c as usize] -= take; carried += take * COL_W;
                }
            }
        }
        self.hill_layer.clear();

        // 2. Cut what the circle swept, front first, until the hill is full.
        let base = s.y - self.lift;
        let mut c = if dir > 0 { col(hi + r) } else { col(lo - r) };
        let end = if dir > 0 { col(lo - r) } else { col(hi + r) };
        while carried < full {
            let x = sx + (c as f32 + 0.5) * COL_W;
            let nearest = x.clamp(lo, hi);
            let dx = x - nearest;
            if dx.abs() <= r {
                let t = if hi > lo { (nearest - fx) / (tx - fx) } else { 1.0 };
                let path_y = fy + (ty - fy) * t.clamp(0.0, 1.0);
                let circle_bottom = path_y + (r * r - dx * dx).sqrt();
                let keep = (base + s.drop(c) - circle_bottom).max(0.0);
                let cut = (self.h[c as usize] - keep).max(0.0).min((full - carried) / COL_W);
                if cut > 0.0 { self.h[c as usize] -= cut; carried += cut * COL_W; }
            }
            if c == end { break; }
            c -= dir;
        }
        if carried <= 0.01 { return None; }
        if self.packed.len() != n as usize { self.packed = vec![0.0; n as usize]; }

        // 3. Lay the hill ahead: the bell whose volume is exactly `carried`.
        let (mut low, mut high) = (0.0f32, max_peak);
        for _ in 0..24 { let mid = (low + high) / 2.0; if Pile::bell(mid).volume < carried { low = mid } else { high = mid } }
        let b = Pile::bell(high);
        let scale = carried / b.volume;
        let mut center = lead + dir * b.back;
        if !s.drops_at_edges {
            if dir > 0 { center = center.min(n - 1 - b.front) } else { center = center.max(b.front) }
        }
        let mut layer = vec![0.0f32; n as usize];
        let mut spill = 0.0;
        for (k, w) in b.weights.iter().enumerate() {
            let mut a = center + dir * (k as i32 - b.back);
            let amount = w * high * scale;
            if a < 0 || a >= n {
                if s.drops_at_edges { spill += amount * COL_W; continue; }
                a = if a < 0 { (-a - 1).min(n - 1) } else { (2 * n - 1 - a).max(0) };
            }
            layer[a as usize] += amount;
        }
        if let (Some(first), Some(last)) = (layer.iter().position(|v| *v > 0.0), layer.iter().rposition(|v| *v > 0.0)) {
            self.hill_start = first as i32;
            self.hill_layer = layer[first..=last].to_vec();
            for c in first..=last { self.h[c] += layer[c]; self.packed[c] = 1.0; }
        }
        self.awake = true;
        Some((spill, dir > 0))
    }

    /// One 20 Hz step of the sand-pile rule (see macOS `slump`). Returns true if anything moved.
    pub fn slump(&mut self, s: &Surface) -> bool {
        let mut moved = 0.0f32;
        let n = self.h.len();
        if n > 1 {
            let mut bi = s.drop(0);
            let is_packed = !self.packed.is_empty();
            for i in 0..n - 1 {
                let bj = s.drop(i as i32 + 1);
                let d = (self.h[i] - bi) - (self.h[i + 1] - bj);
                let sticky = MAX_SLOPE * self.cohesion(i as i32);
                let slope = if is_packed { sticky * (1.0 + 2.0 * self.packed[i].max(self.packed[i + 1])) } else { sticky };
                if d.abs() > slope {
                    let mut t = (d.abs() - slope) * 0.25;
                    t = t.min(if d > 0.0 { self.h[i] } else { self.h[i + 1] });
                    if d < 0.0 { t = -t; }
                    self.h[i] -= t; self.h[i + 1] += t; moved += t.abs();
                }
                bi = bj;
            }
        }
        if s.drops_at_edges {
            let left_hold = MAX_SLOPE * self.cohesion(-1);
            let right_hold = MAX_SLOPE * self.cohesion(n as i32);
            if self.h[0] > left_hold {
                let t = (self.h[0] - left_hold) * 0.25;
                self.h[0] -= t; self.edge_loss.0 += t * COL_W; moved += t;
            }
            if self.h[n - 1] > right_hold {
                let t = (self.h[n - 1] - right_hold) * 0.25;
                self.h[n - 1] -= t; self.edge_loss.1 += t * COL_W; moved += t;
            }
        }
        if !self.packed.is_empty() {
            let mut still = false;
            for p in self.packed.iter_mut() { *p *= PACKED_SETTLE; if *p > 0.05 { still = true; } }
            if !still { self.packed.clear(); }
        }
        self.awake = moved > 0.001 || !self.packed.is_empty();
        moved > 0.001
    }
}
