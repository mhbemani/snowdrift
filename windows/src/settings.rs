//! Settings: a small `snowdrift.ini` next to the exe (portable: nothing in AppData), and the
//! "Launch at Login" entry (HKCU Run), written only when the user ticks it in the menu.

use std::path::PathBuf;
use windows::core::{w, HSTRING};
use windows::Win32::System::Registry::*;

pub const SNOWFALL: [(&str, f32); 3] = [("Light", 0.5), ("Medium", 1.0), ("Heavy", 1.8)];    // flake density
pub const WIND: [(&str, f32); 3] = [("Calm", 0.0), ("Breeze", 6.0), ("Windy", 24.0)];        // DIP/s sideways

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Settings { pub snowfall: usize, pub wind: usize, pub hide_from_sharing: bool }

impl Default for Settings {
    fn default() -> Settings { Settings { snowfall: 1, wind: 1, hide_from_sharing: true } }
}

fn path() -> Option<PathBuf> { std::env::current_exe().ok().map(|p| p.with_file_name("snowdrift.ini")) }

impl Settings {
    /// Unknown keys and bad values are ignored (the file may be hand-edited).
    pub fn parse(text: &str) -> Settings {
        let mut s = Settings::default();
        for line in text.lines() {
            let Some((k, v)) = line.split_once('=') else { continue };
            let n = v.trim().parse::<usize>().ok();
            match k.trim() {
                "snowfall" => if let Some(n) = n.filter(|n| *n < SNOWFALL.len()) { s.snowfall = n },
                "wind" => if let Some(n) = n.filter(|n| *n < WIND.len()) { s.wind = n },
                "hide_from_sharing" => if let Some(n) = n { s.hide_from_sharing = n != 0 },
                _ => {}
            }
        }
        s
    }

    pub fn load() -> Settings {
        path().and_then(|p| std::fs::read_to_string(p).ok()).map(|t| Settings::parse(&t)).unwrap_or_default()
    }

    /// Best effort: a read-only folder just means settings aren't remembered.
    pub fn save(&self) {
        let text = format!("snowfall={}\nwind={}\nhide_from_sharing={}\n", self.snowfall, self.wind, self.hide_from_sharing as u8);
        if let Some(p) = path() { let _ = std::fs::write(p, text); }
    }
}

const RUN_KEY: windows::core::PCWSTR = w!("Software\\Microsoft\\Windows\\CurrentVersion\\Run");

fn exe_command() -> Option<String> { std::env::current_exe().ok().map(|p| format!("\"{}\"", p.display())) }

/// On only if the Run entry points at *this* exe (a moved exe shows unticked).
pub fn launch_at_login() -> bool {
    let Some(want) = exe_command() else { return false };
    let mut buf = [0u16; 1024];
    let mut len = (buf.len() * 2) as u32;
    let r = unsafe { RegGetValueW(HKEY_CURRENT_USER, RUN_KEY, w!("Snowdrift"), RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut len)) };
    r.is_ok() && String::from_utf16_lossy(&buf[..(len as usize / 2).saturating_sub(1)]) == want
}

pub fn set_launch_at_login(on: bool) {
    unsafe {
        if on {
            let Some(cmd) = exe_command() else { return };
            let wide: Vec<u16> = cmd.encode_utf16().chain(Some(0)).collect();
            let _ = RegSetKeyValueW(HKEY_CURRENT_USER, RUN_KEY, w!("Snowdrift"), REG_SZ.0, Some(wide.as_ptr() as *const _), (wide.len() * 2) as u32);
        } else {
            let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, RUN_KEY, &HSTRING::from("Snowdrift"));
        }
    }
}
