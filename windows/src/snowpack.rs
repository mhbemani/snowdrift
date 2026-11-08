//! Coordinates the snow on every surface: a port of macOS `Snowpack.swift`. It takes window
//! positions, the taskbar and the mouse as *inputs* (no OS calls here), so it runs and is tested
//! without a desktop.

use std::collections::HashMap;
use crate::gpu::Rng;
use crate::model::*;
use crate::physics::*;

/// A window from the tracker, front to back.
#[derive(Clone, Copy, Debug)]
pub struct TrackedWindow { pub id: isize, pub frame: Rect, pub vx: f32, pub vy: f32 }

/// What the OS reported this frame (global DIPs).
pub struct FrameInput<'a> {
    pub windows: &'a [TrackedWindow],
    pub taskbar: Option<Rect>,          // None: auto-hidden, or not at the bottom
    pub full_screen_hint: bool,         // the shell says an app is in full screen
    pub mouse: (f32, f32),
}

pub struct Snowpack {
    lead: f32,
    rate_scale: f32,
    pub points_per_cm: f32,
    pub screens: Vec<ScreenInfo>,
    pub surfaces: Vec<Surface>,
    pub piles: HashMap<SurfaceKey, Pile>,
    pub clumps: Vec<Clump>,
    /// Per screen, screen-local: [0, MAP_SIZE) landing map, [MAP_SIZE, 2·MAP_SIZE) ground.
    pub maps: Vec<Vec<f32>>,
    owner: Vec<Vec<i32>>,
    map_surfaces: Vec<Surface>,
    last_surfaces: HashMap<SurfaceKey, Surface>,
    last_frame: f64,
    sim_time: f64,
    maps_dirty: bool,
    last_mouse: Option<(f32, f32)>,
    rng: Rng,
    next_seed: u32,
    pub debug_log: bool,
}

impl Snowpack {
    pub fn new(screens: Vec<ScreenInfo>, lead: f32, rate_scale: f32, points_per_cm: f32) -> Snowpack {
        let mut s = Snowpack {
            lead, rate_scale, points_per_cm, screens: Vec::new(), surfaces: Vec::new(), piles: HashMap::new(),
            clumps: Vec::new(), maps: Vec::new(), owner: Vec::new(), map_surfaces: Vec::new(),
            last_surfaces: HashMap::new(), last_frame: 0.0, sim_time: 0.0, maps_dirty: true, last_mouse: None,
            rng: Rng::new(0x5eed), next_seed: 1, debug_log: false,
        };
        s.reset_screens(screens);
        s
    }

    fn log(&self, msg: impl FnOnce() -> String) { if self.debug_log { println!("{}", msg()); } }

    /// Displays changed. Window snow is kept (global coordinates); ground and taskbar snow start over.
    pub fn reset_screens(&mut self, new: Vec<ScreenInfo>) {
        let rates: Vec<f32> = self.screens.iter().map(|s| s.landing_rate).collect();
        self.screens = new;
        for (i, s) in self.screens.iter_mut().enumerate() { if let Some(r) = rates.get(i) { if s.landing_rate == 0.0 { s.landing_rate = *r; } } }
        self.maps = vec![vec![0.0; 2 * MAP_SIZE]; self.screens.len()];
        self.owner = vec![vec![-1; MAP_SIZE]; self.screens.len()];
        self.piles.retain(|k, _| matches!(k, SurfaceKey::Window(_)));
        self.last_surfaces.retain(|k, _| matches!(k, SurfaceKey::Window(_)));
        self.surfaces.clear(); self.map_surfaces.clear();
        self.maps_dirty = true;
    }

    pub fn clear_all(&mut self) {
        for p in self.piles.values_mut() { p.clear(); }
        self.clumps.clear();
        self.maps_dirty = true;
    }

    /// Advance to `now` (seconds).
    pub fn frame(&mut self, now: f64, input: &FrameInput) {
        let dt = now - self.last_frame;
        if dt <= 0.004 || self.screens.is_empty() { return; }
        self.last_frame = now;
        let fdt = dt.min(0.05) as f32;
        self.build_surfaces(input);
        self.sync_piles();
        self.move_window_snow(fdt);
        self.plow(input.mouse, fdt);
        self.sim_time += dt.min(0.25);
        while self.sim_time >= TICK {
            self.sim_time -= TICK;
            self.accumulate(TICK as f32);
            self.slump_all();
        }
        if !self.clumps.is_empty() {
            if self.maps_dirty { self.build_maps(); self.maps_dirty = false; }
            self.step_clumps(fdt);
        }
        if self.maps_dirty { self.build_maps(); self.maps_dirty = false; }
    }

    // MARK: Surfaces

    fn build_surfaces(&mut self, input: &FrameInput) {
        let ahead = self.lead;
        let n = input.windows.len().max(1) as f32;
        // Full screen: a window covering a whole monitor (maximized ones stop above the taskbar).
        let full_screen = input.full_screen_hint || self.screens.iter().any(|s| input.windows.iter().any(|w| {
            w.frame.x <= s.frame.x + 1.0 && w.frame.max_x() >= s.frame.max_x() - 1.0
                && w.frame.max_y() >= s.frame.max_y() - 1.0 && w.frame.y <= s.frame.y + 1.0
        }));
        let mut next = Vec::with_capacity(input.windows.len() + self.screens.len() + 1);
        for (i, w) in input.windows.iter().enumerate() {
            let f = Rect { x: w.frame.x + w.vx * ahead, y: w.frame.y + w.vy * ahead, ..w.frame };
            // Skip tops at the very top of a screen (maximized windows).
            let mid = f.x + f.w / 2.0;
            let on = self.screens.iter().find(|s| mid >= s.frame.x && mid < s.frame.max_x() && f.y.max(s.frame.y) >= s.frame.y && f.y.max(s.frame.y) < s.frame.max_y());
            match on {
                Some(s) if f.y > s.frame.y + 1.0 => {}
                _ => continue,
            }
            next.push(Surface {
                key: SurfaceKey::Window(w.id), x: f.x, y: f.y, width: f.w, height: f.h,
                depth: 0.2 + 0.7 * i as f32 / n, drops_at_edges: true, max_height: WINDOW_MAX,
                radius: CORNER_RADIUS, vx: w.vx, vy: w.vy,
            });
        }
        if let Some(t) = input.taskbar {
            if !full_screen {
                next.push(Surface { key: SurfaceKey::Dock, x: t.x, y: t.y, width: t.w, height: t.h, depth: 0.1,
                                    drops_at_edges: true, max_height: DOCK_MAX, radius: 0.0, vx: 0.0, vy: 0.0 });
            }
        }
        for (i, s) in self.screens.iter().enumerate() {
            next.push(Surface { key: SurfaceKey::Ground(i), x: s.frame.x, y: s.frame.max_y(), width: s.frame.w, height: 0.0,
                                depth: 0.95, drops_at_edges: false, max_height: GROUND_MAX, radius: 0.0, vx: 0.0, vy: 0.0 });
        }
        if next.len() != self.surfaces.len() || next.iter().zip(&self.surfaces).any(|(a, b)| a.key != b.key || a.x != b.x || a.y != b.y || a.width != b.width) {
            self.maps_dirty = true;
        }
        self.surfaces = next;
    }

    fn sync_piles(&mut self) {
        let mut seen = std::collections::HashSet::new();
        let surfaces = self.surfaces.clone();
        for s in &surfaces {
            seen.insert(s.key);
            let cols = (s.width / COL_W) as i32;
            if let Some(p) = self.piles.get_mut(&s.key) {
                let before = p.n();
                let cut = p.resize(cols);
                let after = p.n();
                if cut > 0.0 { self.spawn_clumps(cut, s.x + after as f32 * COL_W, (before - after) as f32 * COL_W, s.y); }
                if before != after { self.maps_dirty = true; }
            } else {
                self.next_seed = self.next_seed.wrapping_mul(747796405).wrapping_add(2891336453);
                self.piles.insert(s.key, Pile::new(cols, self.next_seed));
            }
            self.last_surfaces.insert(s.key, *s);
        }
        // A window closed, minimized or moved to another desktop: its snow falls.
        let gone: Vec<SurfaceKey> = self.piles.keys().filter(|k| !seen.contains(k) && matches!(k, SurfaceKey::Window(_))).copied().collect();
        for key in gone {
            if let (Some(p), Some(s)) = (self.piles.remove(&key), self.last_surfaces.remove(&key)) {
                self.log(|| format!("{:?} no longer a surface: {} DIP² of snow falls", key, p.mass() as i32));
                self.spawn_clumps(p.mass(), s.x, p.n() as f32 * COL_W, s.y);
            }
            self.maps_dirty = true;
        }
    }

    // MARK: Window motion

    fn move_window_snow(&mut self, dt: f32) {
        let max_throw = (2.0 * SLAB_GRAVITY * MAX_THROW_CM * self.points_per_cm).sqrt();
        let surfaces = self.surfaces.clone();
        for s in &surfaces {
            if !matches!(s.key, SurfaceKey::Window(_)) { continue; }
            let Some(p) = self.piles.get_mut(&s.key) else { continue };
            let was_lifted = p.lift > 0.0;
            let broke = p.step_slab(s.y, s.vy, dt, max_throw).is_none();
            let lifted = p.lift > 0.0;
            if p.contact { p.slide_offset += p.step_sideways(s.vx, dt); }
            let slid = p.apply_slide();
            if was_lifted || lifted || slid { self.maps_dirty = true; }
            if broke {
                self.log(|| format!("{:?} slab broke", s.key));
                self.break_apart(s);
            } else if slid {
                self.spill_edges(s, true);
            }
        }
    }

    fn break_apart(&mut self, s: &Surface) {
        let Some(p) = self.piles.get_mut(&s.key) else { return };
        let room = (MAX_THROW_CM * self.points_per_cm - p.lift).max(0.0);
        let min_vy = -(2.0 * GRAVITY * room).sqrt();
        let (vx, vy) = (p.us, p.slab_v);
        let budget = MAX_CLUMPS.saturating_sub(self.clumps.len()).max(1);
        let group = ((p.h.len() as f32 / budget as f32).ceil() as usize).max(3);
        let chunks = p.break_into_chunks(s, group);
        for (x, y, mass) in chunks {
            let (jx, jy, gk) = (self.rng.range(-30.0, 30.0), self.rng.range(-25.0, 5.0), self.rng.range(0.75, 1.25));
            self.add_clump(x, y, vx + jx, (vy + jy).max(min_vy), mass, gk);
        }
        self.maps_dirty = true;
    }

    /// Snow gathered past a pile's ends becomes a falling lump once there's enough of it. Snow
    /// pushed off by a slide keeps the snow's sideways speed; snow that slumped off has none.
    fn spill_edges(&mut self, s: &Surface, slid: bool) {
        let Some(p) = self.piles.get_mut(&s.key) else { return };
        let (left, right, lift) = (p.edge_loss.0, p.edge_loss.1, p.lift);
        let vx = if slid { p.us } else { 0.0 };
        if left > CLUMP_MASS { p.edge_loss.0 = 0.0; }
        if right > CLUMP_MASS { p.edge_loss.1 = 0.0; }
        if left > CLUMP_MASS { self.add_clump(s.x - 2.0, s.y - lift - 3.0, vx.min(0.0), 0.0, left, 1.0); }
        if right > CLUMP_MASS { self.add_clump(s.x + s.width + 2.0, s.y - lift - 3.0, vx.max(0.0), 0.0, right, 1.0); }
    }

    // MARK: Mouse plow

    fn plow(&mut self, m: (f32, f32), dt: f32) {
        let prev = self.last_mouse.replace(m);
        let Some(prev) = prev else { return };
        if (m.0 - prev.0).abs() <= 0.01 { return; }
        let r = PLOW_RADIUS;
        // Front to back: the taskbar, then windows, then the ground. A window or the taskbar under
        // the cursor hides any snow behind it.
        let mut order: Vec<Surface> = self.surfaces.iter().filter(|s| s.key == SurfaceKey::Dock).copied().collect();
        order.extend(self.surfaces.iter().filter(|s| s.key != SurfaceKey::Dock).copied());
        for s in order {
            if s.height > 0.0 && m.0 >= s.x && m.0 < s.x + s.width && m.1 >= s.y && m.1 < s.y + s.height { return; }
            if m.0 + r < s.x || m.0 - r >= s.x + s.width { continue; }
            let Some(p) = self.piles.get_mut(&s.key) else { continue };
            if m.1 - r > s.y - p.lift { continue; }
            let Some((spill, right_end)) = p.plow(&s, prev.0, prev.1, m.0, m.1) else { continue };
            let lift = p.lift;
            self.maps_dirty = true;
            if spill > 0.0 {
                let vx = ((m.0 - prev.0) / dt.max(0.001) * 0.6).clamp(-300.0, 300.0);
                let lumps = ((spill / (2.0 * CLUMP_MASS)) as usize).clamp(1, 6);
                for _ in 0..lumps {
                    let (jx, vy, gk) = (self.rng.range(-30.0, 30.0), self.rng.range(-40.0, -10.0), self.rng.range(0.75, 1.25));
                    let x = if right_end { s.x + s.width + 2.0 } else { s.x - 2.0 };
                    self.add_clump(x, s.y - lift - 3.0, vx + jx, vy, spill / lumps as f32, gk);
                }
            }
            return;
        }
    }

    // MARK: Growth and slumping (20 Hz)

    fn accumulate(&mut self, dt: f32) {
        for si in 0..self.screens.len() {
            let s = self.screens[si];
            if s.landing_rate <= 0.0 { continue; }
            let volume = (10.0 / FILL_TIME) * s.frame.w / s.landing_rate;
            let expected = s.landing_rate * dt * self.rate_scale;
            let mut count = expected as usize;
            if self.rng.next() < expected - count as f32 { count += 1; }
            for _ in 0..count {
                let j = ((self.rng.next() * MAP_SIZE as f32) as usize).min(MAP_SIZE - 1);
                let k = self.owner[si][j];
                if k < 0 || k as usize >= self.map_surfaces.len() { continue; }
                let surf = self.map_surfaces[k as usize];
                let x = s.frame.x + (j as f32 + self.rng.next()) * s.frame.w / MAP_SIZE as f32;
                let Some(pile) = self.piles.get_mut(&surf.key) else { continue };
                if pile.mean() >= FULL_AT * surf.max_height { continue; }
                pile.deposit(((x - surf.x) / COL_W) as i32, volume);
                self.maps_dirty = true;
            }
        }
    }

    fn slump_all(&mut self) {
        let surfaces = self.surfaces.clone();
        for s in &surfaces {
            let Some(p) = self.piles.get_mut(&s.key) else { continue };
            if !p.awake { continue; }
            if p.slump(s) { self.maps_dirty = true; }
            if s.drops_at_edges { self.spill_edges(s, false); }
        }
    }

    // MARK: Lumps

    fn spawn_clumps(&mut self, mass: f32, x0: f32, width: f32, y: f32) {
        if mass <= 1.0 { return; }
        let n = ((mass / CLUMP_MASS) as usize).clamp(1, 24);
        for i in 0..n {
            let x = x0 + (i as f32 + self.rng.next()) * width / n as f32;
            self.add_clump(x, y - 3.0, 0.0, 0.0, mass / n as f32, 1.0);
        }
    }

    fn add_clump(&mut self, x: f32, y: f32, vx: f32, vy: f32, mass: f32, gk: f32) {
        if self.clumps.len() >= MAX_CLUMPS || !x.is_finite() || !y.is_finite() { return; }
        let reach = self.rng.range(LUMP_REACH_CM.0, LUMP_REACH_CM.1) * self.points_per_cm;
        self.clumps.push(Clump { x, y, vx, vy, mass, size: (mass.sqrt() * 0.9).clamp(2.5, 8.0), gk, fallen: 0.0, reach });
    }

    fn step_clumps(&mut self, dt: f32) {
        let mut i = 0;
        while i < self.clumps.len() {
            let mut c = self.clumps[i];
            c.vy = (c.vy + GRAVITY * c.gk * dt).min(MAX_FALL);
            c.vx *= 1.0 - (1.5 * dt).min(1.0);
            c.x += c.vx * dt;
            c.y += c.vy * dt;
            if c.vy > 0.0 { c.fallen += c.vy * dt; }
            self.clumps[i] = c;
            let mut done = true;
            if c.fallen < c.reach {
                if let Some(si) = self.screens.iter().position(|s| s.frame.x <= c.x && c.x < s.frame.max_x()) {
                    let s = self.screens[si];
                    let j = (((c.x - s.frame.x) / s.frame.w * MAP_SIZE as f32) as usize).min(MAP_SIZE - 1);
                    let land_y = self.maps[si][j] + s.frame.y;
                    if c.vy > 0.0 && c.y >= land_y && c.y - land_y < (c.vy * dt * 2.0).max(20.0) {
                        let k = self.owner[si][j];
                        if k >= 0 && (k as usize) < self.map_surfaces.len() {
                            let surf = self.map_surfaces[k as usize];
                            if let Some(p) = self.piles.get_mut(&surf.key) {
                                p.deposit(((c.x - surf.x) / COL_W) as i32, c.mass * c.alpha());
                                self.maps_dirty = true;
                            }
                        }
                    } else if c.y < s.frame.max_y() + 20.0 {
                        done = false;
                    }
                }
            }
            if done { self.clumps.swap_remove(i); } else { i += 1; }
        }
    }

    // MARK: Landing maps

    fn build_maps(&mut self) {
        self.map_surfaces = self.surfaces.clone();
        for (si, s) in self.screens.iter().enumerate() {
            let step = s.frame.w / MAP_SIZE as f32;
            let (left, top) = (s.frame.x, s.frame.y);
            for j in 0..MAP_SIZE { self.maps[si][j] = f32::INFINITY; self.owner[si][j] = -1; }
            for (k, surf) in self.surfaces.iter().enumerate() {
                if let SurfaceKey::Ground(g) = surf.key { if g != si { continue; } }
                let Some(p) = self.piles.get(&surf.key) else { continue };
                let j0 = ((surf.x - left) / step - 0.5).ceil().max(0.0) as usize;
                let j1f = ((surf.x + surf.width - left) / step - 0.5).floor();
                if j1f < 0.0 { continue; }
                let j1 = (j1f as usize).min(MAP_SIZE - 1);
                if j0 > j1 { continue; }
                let is_ground = matches!(surf.key, SurfaceKey::Ground(_));
                for j in j0..=j1 {
                    let x = left + (j as f32 + 0.5) * step;
                    let col = (((x - surf.x) / COL_W) as i32).clamp(0, p.n() - 1);
                    let y = surf.y + surf.drop(col) - p.lift - p.h[col as usize] - top;
                    if y < self.maps[si][j] { self.maps[si][j] = y; self.owner[si][j] = k as i32; }
                    if is_ground { self.maps[si][MAP_SIZE + j] = y; }
                }
            }
        }
    }
}
