#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
//! Snowdrift for Windows: snow that falls over the desktop and piles up on windows and the taskbar.
//! Run: snowdrift.exe [options]
//!   --seconds N        quit after N seconds (safety net for test runs)
//!   --fps F            frame rate cap, 1–120 (default 60)
//!   --lead L           predict window positions L frames ahead, 0–5 (default 1)
//!   --snowrate R       pile growth speed multiplier, 0–100 (default 1; 20 to see piles quickly)
//!   --log              print why snow leaves a window
//!   --selftest         check the physics invariants (same scenarios as macOS) and exit
//!   --render-test P    draw a few seconds of snow off-screen, save the last frame as a BMP, exit
//!   --track-test       move and minimize two test windows, print what the tracker sees, exit
//!   --bench S          run the whole frame pipeline off-screen for S seconds, print CPU and memory
//! The last four work without a desktop (e.g. over SSH).

mod desktop;
mod gpu;
mod model;
mod overlay;
mod physics;
mod selftest;
mod settings;
mod shaders;
mod snowpack;
mod tray;

use std::sync::atomic::Ordering;
use std::time::Instant;
use windows::core::{w, Result};
use windows::Win32::Foundation::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::*;
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use gpu::{Gpu, Occ, Offscreen, PileDraw, Scene, ScreenRenderer};
use model::{Rect, ScreenInfo, SurfaceKey};
use overlay::Overlay;
use settings::{Settings, SNOWFALL, WIND};
use snowpack::{FrameInput, Snowpack, TrackedWindow};

/// Command-line options, clamped to safe ranges.
struct Options {
    seconds: Option<f64>, fps: u32, lead: f32, snow_rate: f32, log: bool,
    selftest: bool, render_test: Option<String>, track_test: bool, bench: Option<f64>,
}

impl Options {
    fn parse() -> Options {
        let args: Vec<String> = std::env::args().collect();
        let value = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
        let num = |name: &str| value(name).and_then(|v| v.parse::<f64>().ok()).filter(|v| v.is_finite());
        let flag = |name: &str| args.iter().any(|a| a == name);
        Options {
            seconds: num("--seconds").map(|s| s.max(0.0)),
            fps: num("--fps").map(|f| f.clamp(1.0, 120.0) as u32).unwrap_or(60),
            lead: num("--lead").map(|l| l.clamp(0.0, 5.0) as f32).unwrap_or(1.0),
            snow_rate: num("--snowrate").map(|r| r.clamp(0.0, 100.0) as f32).unwrap_or(1.0),
            log: flag("--log"), selftest: flag("--selftest"), render_test: value("--render-test"), track_test: flag("--track-test"),
            bench: num("--bench").map(|s| s.clamp(1.0, 600.0)),
        }
    }
}

/// What one screen draws: occluders, piles, lumps and its landing map, in its local DIPs.
fn build_scene(sp: &Snowpack, index: usize, scene: &mut Scene) {
    scene.occluders.clear(); scene.piles.clear(); scene.heights.clear(); scene.clumps.clear();
    let Some(screen) = sp.screens.get(index).map(|s| s.frame) else { return };
    let (ox, oy) = (screen.x, screen.y);
    for s in &sp.surfaces {
        if let SurfaceKey::Ground(g) = s.key { if g != index { continue; } } else {
            scene.occluders.push(Occ { r: [s.x - ox, s.y - oy, s.width, s.height], depth: s.depth, pad: [0.0; 3] });
        }
        if s.x >= screen.max_x() || s.x + s.width <= screen.x { continue; }
        let Some(p) = sp.piles.get(&s.key) else { continue };
        let offset = scene.heights.len() as u32;
        scene.heights.extend_from_slice(&p.h);
        scene.piles.push(PileDraw {
            origin: [s.x - ox, s.y - oy - p.lift], col_w: physics::COL_W, depth: s.depth - 0.001, radius: s.radius,
            start_x: 0.0, width: s.width, count: p.h.len() as u32, offset, pad: [0.0; 3],
        });
    }
    for c in &sp.clumps {
        if c.x < screen.x || c.x >= screen.max_x() { continue; }
        let a = c.alpha();
        scene.clumps.push([c.x - ox, c.y - oy, c.size * (0.6 + 0.4 * a), 0.95 * a]);
    }
    scene.maps.clear();
    scene.maps.extend_from_slice(&sp.maps[index]);
}

/// Off-screen check: 5 s of snow on a 640×400 scene with a ledge, saved as a BMP.
fn render_test(path: &str) -> Result<()> {
    let mut gpu = Gpu::new()?;
    println!("device: {}", if gpu.software { "software (WARP)" } else { "graphics card" });
    let target = Offscreen::new(&gpu, 640, 400)?;
    let renderer = ScreenRenderer::new(&gpu, [640.0, 400.0], 1.0, 6.0, 42)?;
    let mut maps = vec![400.0f32; 1024];
    for m in maps.iter_mut().take(256) { *m = 250.0; }
    let scene = Scene { maps, ..Default::default() };
    let dt = 1.0 / 60.0;
    for frame in 0..300 { renderer.draw(&mut gpu, &target.rtv, &target.dsv, target.px, frame as f32 * dt, dt, &scene)?; }
    target.save_bmp(&gpu, path, [40, 60, 90])?;
    println!("saved {path} (landing rate {:.1}/s)", renderer.landing_rate);
    Ok(())
}

/// CPU and memory of the full per-frame work: the snow model with a window sliding back and forth
/// and the pointer plowing, plus drawing a 1920×1080 screen on the GPU, paced at `fps`. (The live
/// overlay adds only DirectComposition's Present.)
fn bench(seconds: f64, fps: u32) -> Result<()> {
    use windows::Win32::System::ProcessStatus::*;
    let cpu = || unsafe {
        let (mut a, mut b, mut k, mut u) = Default::default();
        let _ = GetProcessTimes(GetCurrentProcess(), &mut a, &mut b, &mut k, &mut u);
        let v = |f: FILETIME| ((f.dwHighDateTime as u64) << 32 | f.dwLowDateTime as u64) as f64 / 1e7;
        v(k) + v(u)
    };
    let mut gpu = Gpu::new()?;
    let target = Offscreen::new(&gpu, 1920, 1080)?;
    let renderer = ScreenRenderer::new(&gpu, [1920.0, 1080.0], 1.0, 6.0, 7)?;
    let screen = ScreenInfo { frame: Rect { x: 0.0, y: 0.0, w: 1920.0, h: 1080.0 }, landing_rate: renderer.landing_rate };
    let mut sp = Snowpack::new(vec![screen], 1.0 / fps as f32, 20.0, 38.0);
    let timer = unsafe { CreateWaitableTimerExW(None, None, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS.0)? };
    let mut scene = Scene::default();
    let start = Instant::now();
    let (cpu0, mut frames, mut last) = (cpu(), 0u32, 0.0f64);
    let taskbar = Some(Rect { x: 0.0, y: 1032.0, w: 1920.0, h: 48.0 });
    trim_memory();
    loop {
        unsafe { SetWaitableTimer(timer, &-(10_000_000i64 / fps as i64), 0, None, None, false)?; WaitForSingleObject(timer, INFINITE); }
        let t = start.elapsed().as_secs_f64();
        if t >= seconds { break; }
        let dt = (t - last) as f32; last = t;
        let x = 300.0 + 200.0 * (t * 0.5).sin() as f32;
        let windows = [
            TrackedWindow { id: 1, frame: Rect { x, y: 420.0, w: 700.0, h: 500.0 }, vx: 100.0 * (t * 0.5).cos() as f32, vy: 0.0 },
            TrackedWindow { id: 2, frame: Rect { x: 1150.0, y: 260.0, w: 600.0, h: 600.0 }, vx: 0.0, vy: 0.0 },
        ];
        let mouse = (1150.0 + 600.0 * ((t * 0.3).fract() as f32), 255.0);
        sp.frame(t, &FrameInput { windows: &windows, taskbar, full_screen_hint: false, mouse });
        build_scene(&sp, 0, &mut scene);
        renderer.draw(&mut gpu, &target.rtv, &target.dsv, target.px, t as f32, dt.min(0.1), &scene)?;
        frames += 1;
    }
    let wall = start.elapsed().as_secs_f64();
    let mut m = PROCESS_MEMORY_COUNTERS_EX { cb: std::mem::size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32, ..Default::default() };
    unsafe { let _ = K32GetProcessMemoryInfo(GetCurrentProcess(), &mut m as *mut _ as *mut _, m.cb); }
    println!("{frames} frames in {wall:.1} s ({:.0} fps); CPU {:.2}% of one core; memory: working set {:.1} MB (peak {:.1}), private {:.1} MB",
             frames as f64 / wall, (cpu() - cpu0) / wall * 100.0, m.WorkingSetSize as f64 / 1e6, m.PeakWorkingSetSize as f64 / 1e6, m.PrivateUsage as f64 / 1e6);
    Ok(())
}

/// Drops the pages only setup touched (driver init, shader compiler) from the working set: measured
/// 47 → 16 MB steady with no CPU cost. Pages still in use come straight back.
fn trim_memory() { unsafe { let _ = SetProcessWorkingSetSize(GetCurrentProcess(), usize::MAX, usize::MAX); } }

fn pump() -> bool {
    let mut msg = MSG::default();
    while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
        if msg.message == WM_QUIT { return false; }
        unsafe { let _ = TranslateMessage(&msg); DispatchMessageW(&msg); }
    }
    true
}

/// Tracker check without a desktop: two windows of our own, one moved down, one minimized.
fn track_test() -> Result<()> {
    unsafe {
        let hinstance: HINSTANCE = GetModuleHandleW(None)?.into();
        unsafe extern "system" fn proc(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT { unsafe { DefWindowProcW(h, m, w, l) } }
        let class = WNDCLASSW { lpfnWndProc: Some(proc), hInstance: hinstance, lpszClassName: w!("SnowdriftTest"), ..Default::default() };
        RegisterClassW(&class);
        let make = |x: i32| CreateWindowExW(WINDOW_EX_STYLE(0), w!("SnowdriftTest"), w!("test"), WS_OVERLAPPEDWINDOW,
                                            x, 200, 400, 300, None, None, hinstance, None);
        let a = make(100)?;
        let b = make(600)?;
        for h in [a, b] { SetWindowPos(h, None, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW)?; }
        let mut tracker = desktop::Tracker::new();
        tracker.include_own = true;
        let start = Instant::now();
        let mut fails = Vec::new();
        pump();
        let n0 = tracker.poll(0.0, false, 1.0).len();
        if n0 < 2 { fails.push(format!("saw {n0} windows, expected our 2")); }
        let mut max_vy = 0.0f32;
        for i in 1..=30 {
            SetWindowPos(a, None, 100, 200 + i * 8, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)?;
            pump();
            std::thread::sleep(std::time::Duration::from_millis(16));
            let t = start.elapsed().as_secs_f64();
            let ws = tracker.poll(t, true, 1.0).to_vec();
            if let Some(w) = ws.iter().find(|w| w.id == a.0 as isize) { max_vy = max_vy.max(w.vy); }
        }
        // 8 px per ~16 ms ≈ 500 px/s (sleep granularity makes it lower; just require clearly moving down).
        if max_vy < 150.0 { fails.push(format!("moving window's speed {max_vy:.0}/s, expected clearly downward")); }
        let _ = ShowWindow(b, SW_MINIMIZE);
        pump();
        std::thread::sleep(std::time::Duration::from_millis(50));
        let ws = tracker.poll(start.elapsed().as_secs_f64() + 1.0, false, 1.0).to_vec();
        if ws.iter().any(|w| w.id == b.0 as isize) { fails.push("minimized window still tracked".into()); }
        println!("tracked {n0} windows; moving window peaked at {max_vy:.0}/s down; after minimizing: {} tracked", ws.len());
        let _ = DestroyWindow(a); let _ = DestroyWindow(b);
        if fails.is_empty() { println!("track-test: OK"); Ok(()) } else { println!("track-test FAILED:\n{}", fails.join("\n")); std::process::exit(1) }
    }
}

fn main() -> Result<()> {
    // A GUI app (no console window); when started from a console, print there.
    unsafe { let _ = windows::Win32::System::Console::AttachConsole(windows::Win32::System::Console::ATTACH_PARENT_PROCESS); }
    let opts = Options::parse();
    unsafe { let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2); }
    if let Some(path) = &opts.render_test { return render_test(path); }
    if opts.track_test { return track_test(); }
    if let Some(s) = opts.bench { return bench(s, opts.fps); }
    if opts.selftest {
        let screen = ScreenInfo { frame: Rect { x: 0.0, y: 0.0, w: 1920.0, h: 1080.0 }, landing_rate: 9.0 };
        let mut sp = Snowpack::new(vec![screen], 1.0 / 60.0, 1.0, 38.0);
        let failures = selftest::run(&mut sp);
        if failures.is_empty() { println!("selftest: OK"); } else { println!("selftest FAILED:\n{}", failures.join("\n")); }
        std::process::exit(if failures.is_empty() { 0 } else { 1 });
    }

    run(&opts)
}

/// The live app: an overlay per monitor, the snow model, window tracking, the tray and pausing.
struct App {
    gpu: Option<Gpu>, overlays: Vec<Overlay>, layout: Vec<(RECT, f32)>, scale: f32,
    snowpack: Snowpack, settings: Settings, snow_on: bool, last_error: String,
}

impl App {
    /// (Re)creates the overlays for the current monitors. Called at start, when monitors, resolution
    /// or scaling change, when the snowfall changes and after the graphics device was lost.
    fn rebuild(&mut self) {
        self.overlays.clear();
        let monitors = desktop::monitors();
        self.layout = monitors.iter().map(|m| (m.rect, m.scale)).collect();
        // ponytail: one global scale (the primary monitor's); on mixed-DPI setups the other monitors'
        // snow sits slightly off. Per-monitor coordinate spaces if that's ever needed.
        self.scale = monitors.first().map(|m| m.scale).unwrap_or(1.0);
        let mut screens = Vec::new();
        if let Err(e) = self.make_overlays(&monitors, &mut screens) {
            let msg = e.to_string();
            if msg != self.last_error { eprintln!("snowdrift: can't draw yet ({msg}); retrying every second"); self.last_error = msg; }
            self.overlays.clear(); screens.clear();
            self.gpu = None;
        }
        // Same screens (only the snowfall changed): keep the ground snow, update the landing rates.
        let same = screens.len() == self.snowpack.screens.len() && screens.iter().zip(&self.snowpack.screens).all(|(a, b)| a.frame == b.frame);
        if same { for (dst, src) in self.snowpack.screens.iter_mut().zip(&screens) { dst.landing_rate = src.landing_rate; } }
        else { self.snowpack.reset_screens(screens); }
        for o in &self.overlays { o.set_visible(self.snow_on); }
        trim_memory();
    }

    fn make_overlays(&mut self, monitors: &[desktop::Monitor], screens: &mut Vec<ScreenInfo>) -> Result<()> {
        if monitors.is_empty() { return Ok(()); }
        if self.gpu.is_none() { self.gpu = Some(Gpu::new()?); }
        let gpu = self.gpu.as_ref().unwrap();
        let (density, wind) = (SNOWFALL[self.settings.snowfall].1, WIND[self.settings.wind].1);
        for (i, m) in monitors.iter().enumerate() {
            let o = Overlay::new(gpu, m.rect, self.scale, density, wind, 1000 + i as u64, self.settings.hide_from_sharing)?;
            screens.push(ScreenInfo { frame: desktop::to_dip(m.rect, self.scale), landing_rate: o.renderer.landing_rate });
            self.overlays.push(o);
        }
        Ok(())
    }

    /// A menu choice. False = quit.
    fn apply(&mut self, pick: tray::Pick) -> bool {
        use tray::Pick::*;
        match pick {
            Snow => { self.snow_on = !self.snow_on; for o in &self.overlays { o.set_visible(self.snow_on); } }
            Snowfall(i) => { self.settings.snowfall = i; self.rebuild(); }
            Wind(i) => { self.settings.wind = i; for o in &mut self.overlays { o.renderer.wind = WIND[i].1; } }
            Clear => self.snowpack.clear_all(),
            Hide => { self.settings.hide_from_sharing ^= true; for o in &self.overlays { o.set_hidden_from_capture(self.settings.hide_from_sharing); } }
            Login => settings::set_launch_at_login(!settings::launch_at_login()),
            Quit => return false,
        }
        self.settings.save();
        true
    }
}

fn run(opts: &Options) -> Result<()> {
    // One instance per session: two would draw two snowfalls.
    let _single = unsafe { CreateMutexW(None, true, w!("Local\\SnowdriftSingleInstance"))? };
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS { eprintln!("Snowdrift is already running"); return Ok(()); }

    let monitors = desktop::monitors();
    let per_cm = monitors.first().map(desktop::dips_per_cm).unwrap_or(38.0);
    let mut snowpack = Snowpack::new(Vec::new(), opts.lead / opts.fps as f32, opts.snow_rate, per_cm);
    snowpack.debug_log = opts.log;
    let mut app = App { gpu: None, overlays: Vec::new(), layout: Vec::new(), scale: 1.0, snowpack, settings: Settings::load(), snow_on: true, last_error: String::new() };
    app.rebuild();
    let tray = tray::Tray::new()?;
    let mut tracker = desktop::Tracker::new();
    if let Some(g) = &app.gpu { println!("{} screen(s) at {:.2}x, device: {}", app.overlays.len(), app.scale, if g.software { "software (WARP)" } else { "graphics card" }); }

    // Frame pacing: a high-resolution waitable timer (no global timer-resolution change); between
    // frames the thread sleeps in MsgWaitForMultipleObjects. Paused: no timer, a 1 s check only.
    let timer = unsafe { CreateWaitableTimerExW(None, None, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS.0)? };
    let start = Instant::now();
    let mut last = start;
    let (mut taskbar, mut full_screen, mut screensaver, mut saver, mut last_check) = (None, false, false, false, -10.0f64);
    let mut scene = Scene::default();
    let mut paused = false;
    loop {
        if paused {
            unsafe { MsgWaitForMultipleObjectsEx(None, 1000, QS_ALLINPUT, MWMO_INPUTAVAILABLE); }
            if !pump() { return Ok(()); }
        } else {
            // Energy saver: 30 fps at most.
            let fps = if saver { opts.fps.min(30) } else { opts.fps };
            unsafe { SetWaitableTimer(timer, &-(10_000_000i64 / fps as i64), 0, None, None, false)?; }
            loop {
                let r = unsafe { MsgWaitForMultipleObjectsEx(Some(&[timer]), INFINITE, QS_ALLINPUT, MWMO_INPUTAVAILABLE) };
                if !pump() { return Ok(()); }
                if r == WAIT_OBJECT_0 { break; }
            }
        }
        let now = Instant::now();
        let t = (now - start).as_secs_f64();
        if let Some(limit) = opts.seconds { if t >= limit { return Ok(()); } }
        let dt = (now - last).as_secs_f32().min(0.1);
        last = now;

        if t - last_check >= 1.0 {
            last_check = t;
            taskbar = desktop::taskbar(app.scale); full_screen = desktop::full_screen();
            screensaver = desktop::screensaver_running(); saver = desktop::energy_saver();
            let layout: Vec<(RECT, f32)> = desktop::monitors().iter().map(|m| (m.rect, m.scale)).collect();
            if layout != app.layout || (app.overlays.is_empty() && !layout.is_empty()) { app.rebuild(); }
        }
        if let Some(pick) = tray.poll(&app.settings, app.snow_on) { if !app.apply(pick) { return Ok(()); } }

        paused = !app.snow_on || app.overlays.is_empty() || screensaver
            || tray::LOCKED.load(Ordering::Relaxed) || tray::DISPLAY_OFF.load(Ordering::Relaxed);
        if paused { continue; }

        let (mouse, down) = desktop::mouse(app.scale);
        let windows = tracker.poll(t, down, app.scale).to_vec();
        app.snowpack.frame(t, &FrameInput { windows: &windows, taskbar, full_screen_hint: full_screen, mouse });
        let time = (t % 3600.0) as f32;          // wraps hourly: f32 keeps sub-ms precision
        let gpu = app.gpu.as_mut().unwrap();
        let mut lost = None;
        for (i, o) in app.overlays.iter().enumerate() {
            build_scene(&app.snowpack, i, &mut scene);
            if let Err(e) = o.present(gpu, time, dt, &scene) { lost = Some(e); break; }
        }
        // Device lost (driver update, GPU reset): start over with a new device at the next check.
        if let Some(e) = lost { eprintln!("snowdrift: drawing failed ({e}); restarting graphics"); app.overlays.clear(); app.gpu = None; }
    }
}
