# Snowdrift for Windows: plan (done: 1.0.0)

Same app as macOS 1.0: snow falls over the desktop, piles on window tops and the taskbar, reacts to
windows you move and to the mouse, and costs as little as possible because it runs all day.
Target: Windows 11 (Windows 10 should work), x64.

## Stack

| | macOS | Windows |
|---|---|---|
| Language | Swift 6 | **Rust** (no garbage collector, ~1–2 MB exe) |
| Overlay | borderless click-through `NSPanel` per screen | layered, click-through, topmost tool window per monitor (`WS_EX_NOREDIRECTIONBITMAP`), no taskbar button |
| GPU | Metal, runtime-compiled shaders | **Direct3D 11 + DirectComposition** swap chain with premultiplied alpha; HLSL compiled at runtime by `d3dcompiler_47.dll` (part of Windows) |
| Window positions | `CGWindowListCopyWindowInfo`, polled 4–60 Hz | `EnumWindows` + exact frames from `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`; moves are **pushed** by `SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE …)`, so no polling |
| Hidden windows | Stage Manager filter | `DWMWA_CLOAKED` (other virtual desktops, suspended UWP), minimized, tool windows |
| Dock | estimated from its layout | **taskbar** rect reported exactly by `SHAppBarMessage(ABM_GETTASKBARPOS)` |
| Full screen | window covering the Dock's area | `SHQueryUserNotificationState` (+ a window covering the monitor) |
| Mouse | `NSEvent.mouseLocation` | `GetCursorPos` |
| Menu | menu bar ❄ | system tray ❄ (`Shell_NotifyIcon`), same items |
| Settings | `UserDefaults` | `snowdrift.ini` next to the exe (portable: nothing in AppData), written only when a setting changes |
| Launch at login | `SMAppService` | `HKCU\…\Run` value, only when the user ticks it |
| Pause | lock, screensaver, sleep, Low Power | `WTSRegisterSessionNotification` (lock), `GUID_CONSOLE_DISPLAY_STATE` (display off), screensaver flag; energy saver caps it at 30 fps |
| Display changes | `didChangeScreenParameters` | monitor list and scales compared once a second (catches resolution, scaling and plug/unplug alike); a lost graphics device rebuilds the same way |
| App icon | `make-icon.swift` → `.icns` | the same script writes `windows/assets/snowdrift.ico`; `build.rs` links it in as a resource (no resource compiler needed) |

Per-monitor DPI awareness v2 from the start (Windows mixes scales per monitor).

## Physics

`Physics`, `Model` (piles, slab, friction, plow hill, slumping) and `Snowpack` port almost line for
line: plain math on arrays. The flake shader ports to HLSL (stateless particles, per-flake landing
state written by the vertex shader through a UAV, same as Metal's device write).
Both versions run the **same self-check scenarios** (the measured window jitter, the plow invariants,
slumping, lumps), so behaviour stays the same on both platforms.

Later (not now): one shared Rust core for both platforms, called from Swift over a C interface.

## Milestones

| | What | Checked by |
|---|---|---|
| W0 ✅ | Workspace and toolchain in `D:\snowdrift`; hello-world builds over SSH | build log |
| W1 ✅ | Overlay window per monitor, Direct3D 11 + DirectComposition, stateless falling flakes | `--render-test` (off-screen BMP) over SSH |
| W2 ✅ | Window tracking (event-driven, DWM frames, cloaked/minimized filter), taskbar surface | `--track-test` over SSH |
| W3 ✅ | Port physics: piles, landing map, slab, friction, lumps, plow; self-check | `--selftest` over SSH |
| W4 ✅ | Tray menu and settings, pause rules, display changes, full screen | live check at the laptop ✅ |
| W5 ✅ | Release: one zipped `Snowdrift.exe`, CPU/memory check, README, GitHub release | `--bench`, release `windows-v1.0.0` |

Measured with `--bench 30` (RTX 3070 laptop, 1920×1080, a window sliding, the pointer plowing, 60 fps):
**0.9% of one CPU core, 16.8 MB working set.** Most memory is the graphics driver; the app drops
setup-only pages (driver init, shader compiler) after start, which took the steady working set from
47 to 16 MB.

## Working on the test laptop (a friend's machine)

- Everything stays inside `D:\snowdrift\` (outside the owner's `D:\voicelab` data): source, the Rust
  toolchain (official component archives, SHA-256 checked, just unpacked: no rustup installer, which
  could write to the registry), `CARGO_HOME`, build output, test settings, logs. No admin rights,
  PATH/registry changes or Visual Studio (the GNU toolchain brings its own linker).
  `windows/build.ps1` sets PATH and `CARGO_HOME` for its own process only.
- Only processes we start are stopped; every test run has an auto-quit (`--seconds N`).
- Programs started over SSH can't show windows on the laptop's screen (no interactive desktop), so
  over SSH we run the headless checks: `./sync.sh` (copy and build), `./test.sh` (self-check, window
  tracking with test windows of its own, off-screen render), `--bench S`, `./package.sh` (zip).
  Run them through PowerShell with piped output: `cmd` neither waits for a GUI-subsystem exe nor
  shows what it prints. Seeing it live needs someone
  at the laptop to double-click the exe. (A scheduled task could get around this, but it's a system
  change, so we don't.)
- Downloads happen only after the owner of this repo approves them (Rust 1.99.1: ~235 MB, approved).
