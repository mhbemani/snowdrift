//! The notification-area icon and its menu, plus the system events that pause the snow (screen
//! locked, display off), delivered to one hidden window on the main thread.

use std::sync::atomic::{AtomicBool, Ordering};
use windows::core::{w, Result, PCWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Power::*;
use windows::Win32::System::RemoteDesktop::*;
use windows::Win32::System::SystemServices::GUID_CONSOLE_DISPLAY_STATE;
use windows::Win32::UI::Shell::*;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::settings::{Settings, SNOWFALL, WIND};

pub static LOCKED: AtomicBool = AtomicBool::new(false);
pub static DISPLAY_OFF: AtomicBool = AtomicBool::new(false);
static MENU_WANTED: AtomicBool = AtomicBool::new(false);
static ICON_LOST: AtomicBool = AtomicBool::new(false);

const WM_TRAY: u32 = WM_APP + 1;
const NIN_KEYSELECT: u32 = NIN_SELECT | 1;     // NINF_KEY: Enter on the focused icon
const ICON_ID: u32 = 1;

/// What the user picked in the menu.
pub enum Pick { Snow, Snowfall(usize), Wind(usize), Clear, Hide, Login, Quit }

const ID_SNOW: u32 = 1;
const ID_SNOWFALL: u32 = 10;      // + index
const ID_WIND: u32 = 20;          // + index
const ID_CLEAR: u32 = 30;
const ID_HIDE: u32 = 31;
const ID_LOGIN: u32 = 32;
const ID_QUIT: u32 = 99;

unsafe extern "system" fn tray_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        // NOTIFYICON_VERSION_4: the event is in the low word of lParam.
        WM_TRAY => {
            let event = (lp.0 & 0xffff) as u32;
            if event == WM_CONTEXTMENU || event == NIN_SELECT || event == NIN_KEYSELECT { MENU_WANTED.store(true, Ordering::Relaxed); }
            LRESULT(0)
        }
        WM_WTSSESSION_CHANGE => {
            match wp.0 as u32 { WTS_SESSION_LOCK => LOCKED.store(true, Ordering::Relaxed), WTS_SESSION_UNLOCK => LOCKED.store(false, Ordering::Relaxed), _ => {} }
            LRESULT(0)
        }
        WM_POWERBROADCAST => {
            if wp.0 as u32 == PBT_POWERSETTINGCHANGE {
                let s = unsafe { &*(lp.0 as *const POWERBROADCAST_SETTING) };
                if s.PowerSetting == GUID_CONSOLE_DISPLAY_STATE && s.DataLength >= 1 {
                    DISPLAY_OFF.store(s.Data[0] == 0, Ordering::Relaxed);       // 0 off, 1 on, 2 dimmed
                }
            }
            LRESULT(1)
        }
        _ => {
            // Explorer restarted: the icon has to be added again.
            if msg == taskbar_created() { ICON_LOST.store(true, Ordering::Relaxed); }
            unsafe { DefWindowProcW(hwnd, msg, wp, lp) }
        }
    }
}

fn taskbar_created() -> u32 {
    static ID: std::sync::OnceLock<u32> = std::sync::OnceLock::new();
    *ID.get_or_init(|| unsafe { RegisterWindowMessageW(w!("TaskbarCreated")) })
}

pub struct Tray { hwnd: HWND, icon: HICON, power: Option<HPOWERNOTIFY> }

impl Tray {
    pub fn new() -> Result<Tray> {
        unsafe {
            let hinstance: HINSTANCE = GetModuleHandleW(None)?.into();
            let class = WNDCLASSW { lpfnWndProc: Some(tray_proc), hInstance: hinstance, lpszClassName: w!("SnowdriftTray"), ..Default::default() };
            RegisterClassW(&class);
            taskbar_created();
            // A hidden top-level window (not message-only: those don't get the TaskbarCreated broadcast).
            let hwnd = CreateWindowExW(WINDOW_EX_STYLE(0), w!("SnowdriftTray"), w!("Snowdrift"), WS_POPUP, 0, 0, 0, 0, None, None, hinstance, None)?;
            let _ = WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION);
            let power = RegisterPowerSettingNotification(HANDLE(hwnd.0), &GUID_CONSOLE_DISPLAY_STATE, DEVICE_NOTIFY_WINDOW_HANDLE).ok();
            let size = GetSystemMetrics(SM_CXSMICON);
            let icon = load_icon(size).unwrap_or_else(|| LoadIconW(None, IDI_APPLICATION).unwrap_or_default());
            let tray = Tray { hwnd, icon, power };
            tray.add_icon();
            Ok(tray)
        }
    }

    fn data(&self) -> NOTIFYICONDATAW {
        let mut d = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32, hWnd: self.hwnd, uID: ICON_ID,
            uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP, uCallbackMessage: WM_TRAY, hIcon: self.icon, ..Default::default()
        };
        for (dst, src) in d.szTip.iter_mut().zip("Snowdrift".encode_utf16()) { *dst = src; }
        d.Anonymous.uVersion = NOTIFYICON_VERSION_4;
        d
    }

    fn add_icon(&self) {
        let d = self.data();
        unsafe { let _ = Shell_NotifyIconW(NIM_ADD, &d); let _ = Shell_NotifyIconW(NIM_SETVERSION, &d); }
    }

    /// Call each tick: re-adds the icon after an Explorer restart; shows the menu if it was clicked.
    pub fn poll(&self, settings: &Settings, snow_on: bool) -> Option<Pick> {
        if ICON_LOST.swap(false, Ordering::Relaxed) { self.add_icon(); }
        if !MENU_WANTED.swap(false, Ordering::Relaxed) { return None; }
        // ponytail: the menu runs a modal loop on this thread, so the snow stands still while it's open.
        // A WM_TIMER-driven frame inside the loop if that ever matters.
        unsafe { self.menu(settings, snow_on) }
    }

    unsafe fn menu(&self, s: &Settings, snow_on: bool) -> Option<Pick> {
        unsafe {
            let m = CreatePopupMenu().ok()?;
            let add = |menu: HMENU, id: u32, text: &str, checked: bool| {
                let wide: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
                let _ = AppendMenuW(menu, MF_STRING | if checked { MF_CHECKED } else { MF_UNCHECKED }, id as usize, PCWSTR(wide.as_ptr()));
            };
            let sub = |title: &str, base: u32, names: &[&str], pick: usize| {
                let sm = CreatePopupMenu().unwrap_or_default();
                for (i, n) in names.iter().enumerate() { add(sm, base + i as u32, n, i == pick); }
                let wide: Vec<u16> = title.encode_utf16().chain(Some(0)).collect();
                let _ = AppendMenuW(m, MF_POPUP, sm.0 as usize, PCWSTR(wide.as_ptr()));
            };
            add(m, ID_SNOW, "Snow", snow_on);
            let _ = AppendMenuW(m, MF_SEPARATOR, 0, None);
            sub("Snowfall", ID_SNOWFALL, &SNOWFALL.map(|x| x.0), s.snowfall);
            sub("Wind", ID_WIND, &WIND.map(|x| x.0), s.wind);
            add(m, ID_CLEAR, "Clear All Snow", false);
            add(m, ID_HIDE, "Hide from Screen Sharing", s.hide_from_sharing);
            add(m, ID_LOGIN, "Launch at Login", crate::settings::launch_at_login());
            let _ = AppendMenuW(m, MF_SEPARATOR, 0, None);
            add(m, ID_QUIT, "Quit Snowdrift", false);

            // Foreground first, or the menu won't close when clicking elsewhere (documented quirk).
            let mut pt = POINT::default();
            let _ = GetCursorPos(&mut pt);
            let _ = SetForegroundWindow(self.hwnd);
            let id = TrackPopupMenuEx(m, (TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON).0, pt.x, pt.y, self.hwnd, None).0 as u32;
            let _ = PostMessageW(self.hwnd, WM_NULL, WPARAM(0), LPARAM(0));
            let _ = DestroyMenu(m);      // destroys the submenus too
            match id {
                ID_SNOW => Some(Pick::Snow),
                ID_CLEAR => Some(Pick::Clear),
                ID_HIDE => Some(Pick::Hide),
                ID_LOGIN => Some(Pick::Login),
                ID_QUIT => Some(Pick::Quit),
                i if (ID_SNOWFALL..ID_SNOWFALL + SNOWFALL.len() as u32).contains(&i) => Some(Pick::Snowfall((i - ID_SNOWFALL) as usize)),
                i if (ID_WIND..ID_WIND + WIND.len() as u32).contains(&i) => Some(Pick::Wind((i - ID_WIND) as usize)),
                _ => None,
            }
        }
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &self.data());
            if let Some(p) = self.power { let _ = UnregisterPowerSettingNotification(p); }
            let _ = WTSUnRegisterSessionNotification(self.hwnd);
            let _ = DestroyIcon(self.icon);
            let _ = DestroyWindow(self.hwnd);
        }
    }
}

/// The exe's own icon (resource 1, see build.rs) at the size the tray wants.
fn load_icon(size: i32) -> Option<HICON> {
    unsafe {
        let hinstance = GetModuleHandleW(None).ok()?;
        LoadImageW(hinstance, PCWSTR(1 as *const u16), IMAGE_ICON, size, size, LR_DEFAULTCOLOR).ok().map(|h| HICON(h.0))
    }
}
