//! Everything read from the Windows desktop: monitors, windows (event-driven), the taskbar, full
//! screen, the mouse. All results in global DIPs (physical pixels ÷ the primary monitor's scale).
//! Reads only: no permissions, nothing written.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Dwm::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::model::Rect;
use crate::snowpack::TrackedWindow;

/// A monitor: physical rect and DPI scale.
pub struct Monitor { pub rect: RECT, pub scale: f32 }

pub fn monitors() -> Vec<Monitor> {
    unsafe extern "system" fn each(hmon: HMONITOR, _: HDC, _: *mut RECT, data: LPARAM) -> BOOL {
        let list = unsafe { &mut *(data.0 as *mut Vec<Monitor>) };
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if unsafe { GetMonitorInfoW(hmon, &mut info) }.as_bool() {
            let (mut dx, mut dy) = (96u32, 96u32);
            let _ = unsafe { GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, &mut dx, &mut dy) };
            // Primary first: the global coordinate scale comes from it.
            let primary = info.dwFlags & MONITORINFOF_PRIMARY != 0;
            let m = Monitor { rect: info.rcMonitor, scale: dx as f32 / 96.0 };
            if primary { list.insert(0, m) } else { list.push(m) }
        }
        TRUE
    }
    let mut list: Vec<Monitor> = Vec::new();
    unsafe { let _ = EnumDisplayMonitors(None, None, Some(each), LPARAM(&mut list as *mut _ as isize)); }
    list
}

pub fn to_dip(r: RECT, scale: f32) -> Rect {
    Rect { x: r.left as f32 / scale, y: r.top as f32 / scale, w: (r.right - r.left) as f32 / scale, h: (r.bottom - r.top) as f32 / scale }
}

/// DIPs per centimetre on the primary monitor, from its physical size (EDID).
pub fn dips_per_cm(primary: &Monitor) -> f32 {
    unsafe {
        let hdc = GetDC(None);
        let mm = GetDeviceCaps(hdc, HORZSIZE);
        ReleaseDC(None, hdc);
        let dips = (primary.rect.right - primary.rect.left) as f32 / primary.scale;
        if mm > 0 { dips / (mm as f32 / 10.0) } else { 38.0 }   // 96 DPI ≈ 37.8 per cm
    }
}

/// The taskbar's rect if it's at the bottom and not auto-hidden.
pub fn taskbar(scale: f32) -> Option<Rect> {
    let mut abd = APPBARDATA { cbSize: std::mem::size_of::<APPBARDATA>() as u32, ..Default::default() };
    unsafe {
        if SHAppBarMessage(ABM_GETSTATE, &mut abd) as u32 & ABS_AUTOHIDE != 0 { return None; }
        if SHAppBarMessage(ABM_GETTASKBARPOS, &mut abd) == 0 || abd.uEdge != ABE_BOTTOM { return None; }
    }
    Some(to_dip(abd.rc, scale))
}

/// True while an app runs in full screen (the shell's own notion: games, videos, presentations).
pub fn full_screen() -> bool {
    match unsafe { SHQueryUserNotificationState() } {
        Ok(s) => s == QUNS_BUSY || s == QUNS_RUNNING_D3D_FULL_SCREEN || s == QUNS_PRESENTATION_MODE,
        Err(_) => false,
    }
}

pub fn screensaver_running() -> bool {
    let mut on = BOOL(0);
    unsafe { let _ = SystemParametersInfoW(SPI_GETSCREENSAVERRUNNING, 0, Some(&mut on as *mut _ as *mut _), SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0)); }
    on.as_bool()
}

/// Energy saver (battery saver) is on.
pub fn energy_saver() -> bool {
    let mut s = windows::Win32::System::Power::SYSTEM_POWER_STATUS::default();
    unsafe { windows::Win32::System::Power::GetSystemPowerStatus(&mut s).is_ok() && s.SystemStatusFlag == 1 }
}

pub fn mouse(scale: f32) -> ((f32, f32), bool) {
    let mut p = POINT::default();
    unsafe { let _ = GetCursorPos(&mut p); }
    let down = unsafe { GetAsyncKeyState(VK_LBUTTON.0 as i32) } as u16 & 0x8000 != 0;
    ((p.x as f32 / scale, p.y as f32 / scale), down)
}

// MARK: Windows

/// Set by the event hook whenever a window moves, appears, hides, minimizes or changes order.
static DIRTY: AtomicBool = AtomicBool::new(true);

unsafe extern "system" fn on_event(_: HWINEVENTHOOK, _: u32, _: HWND, id_object: i32, id_child: i32, _: u32, _: u32) {
    if id_object == OBJID_WINDOW.0 && id_child == CHILDID_SELF as i32 { DIRTY.store(true, Ordering::Relaxed); }
}

/// Window positions, read only when something changed (event-driven), while the mouse button is
/// down (windows are dragged with it) or as a 4 Hz fallback.
pub struct Tracker {
    hooks: Vec<HWINEVENTHOOK>,
    last: HashMap<isize, (Rect, f32, f32)>,
    windows: Vec<TrackedWindow>,
    last_poll: f64,
    own_pid: u32,
    pub include_own: bool,              // tests only: track this process's own windows
}

impl Tracker {
    pub fn new() -> Tracker {
        // Out-of-context hooks: delivered through this thread's message loop; nothing is injected.
        let ranges = [
            (EVENT_OBJECT_CREATE, EVENT_OBJECT_HIDE),           // create, destroy, show, hide
            (EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE),
            (EVENT_OBJECT_CLOAKED, EVENT_OBJECT_UNCLOAKED),     // virtual desktops
            (EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND), // z-order
            (EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND),
        ];
        let hooks = ranges.iter().map(|(a, b)| unsafe {
            SetWinEventHook(*a, *b, None, Some(on_event), 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS)
        }).collect();
        Tracker { hooks, last: HashMap::new(), windows: Vec::new(), last_poll: -1.0, own_pid: unsafe { GetCurrentProcessId() }, include_own: false }
    }

    /// The windows, front to back, in global DIPs, with smoothed speeds.
    pub fn poll(&mut self, now: f64, mouse_down: bool, scale: f32) -> &[TrackedWindow] {
        let dirty = DIRTY.swap(false, Ordering::Relaxed);
        if !(dirty || mouse_down || now - self.last_poll >= 0.25) { return &self.windows; }
        let dt = (now - self.last_poll) as f32;
        self.last_poll = now;

        let mut found: Vec<(isize, Rect)> = Vec::new();
        let ctx = (&mut found as *mut Vec<(isize, Rect)>, self.own_pid, self.include_own, scale);
        unsafe { let _ = EnumWindows(Some(each_window), LPARAM(&ctx as *const _ as isize)); }

        let mut next = HashMap::with_capacity(found.len());
        self.windows.clear();
        for (id, r) in found {
            let (mut vx, mut vy) = (0.0, 0.0);
            if let Some((prev, pvx, pvy)) = self.last.get(&id) {
                // Two polls close together would divide by ~0: keep the last speed then.
                if (0.005..0.1).contains(&dt) {
                    vx = pvx * 0.5 + (r.x - prev.x) / dt * 0.5;
                    vy = pvy * 0.5 + (r.y - prev.y) / dt * 0.5;
                } else if dt < 0.005 { vx = *pvx; vy = *pvy; }
            }
            if vx.abs() + vy.abs() > 1.0 { DIRTY.store(true, Ordering::Relaxed); }   // moving: keep reading
            next.insert(id, (r, vx, vy));
            self.windows.push(TrackedWindow { id, frame: r, vx, vy });
        }
        self.last = next;
        &self.windows
    }
}

impl Drop for Tracker {
    fn drop(&mut self) { for h in &self.hooks { unsafe { let _ = UnhookWinEvent(*h); } } }
}

/// Top-level windows only: their parent is the desktop, which is always visible on a real desktop
/// (IsWindowVisible would also check it, and it's hidden in a service session, breaking tests).
fn shown(hwnd: HWND) -> bool { unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) as u32 & WS_VISIBLE.0 != 0 } }

/// EnumWindows callback (top to bottom = front to back): keeps the windows Alt+Tab would show.
unsafe extern "system" fn each_window(hwnd: HWND, data: LPARAM) -> BOOL {
    let (list, own_pid, include_own, scale) = unsafe { *(data.0 as *const (*mut Vec<(isize, Rect)>, u32, bool, f32)) };
    unsafe {
        if !shown(hwnd) || IsIconic(hwnd).as_bool() { return TRUE; }
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32;
        if ex & WS_EX_TOOLWINDOW.0 != 0 || ex & WS_EX_NOACTIVATE.0 != 0 { return TRUE; }
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == own_pid && !include_own { return TRUE; }
        // Hidden on another virtual desktop, or a suspended app: DWM "cloaks" it.
        let mut cloaked = 0u32;
        if DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut cloaked as *mut _ as *mut _, 4).is_ok() && cloaked != 0 { return TRUE; }
        // Alt+Tab's rule: the window must be the last active popup of its root owner.
        if ex & WS_EX_APPWINDOW.0 == 0 {
            let mut walk = GetAncestor(hwnd, GA_ROOTOWNER);
            loop {
                let popup = GetLastActivePopup(walk);
                if popup == walk || shown(popup) { walk = popup; break; }
                walk = popup;
            }
            if walk != hwnd { return TRUE; }
        }
        let mut class = [0u16; 32];
        let len = GetClassNameW(hwnd, &mut class) as usize;
        let class = String::from_utf16_lossy(&class[..len]);
        if matches!(class.as_str(), "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd") { return TRUE; }
        // The visible frame (DWM), not the window rect with its invisible resize borders.
        let mut r = RECT::default();
        if DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut _ as *mut _, std::mem::size_of::<RECT>() as u32).is_err() {
            let _ = GetWindowRect(hwnd, &mut r);
        }
        let rect = to_dip(r, scale);
        if rect.w < 40.0 || rect.h < 40.0 || !rect.x.is_finite() || !rect.y.is_finite() { return TRUE; }
        (*list).push((hwnd.0 as isize, rect));
    }
    TRUE
}
