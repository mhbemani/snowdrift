# Snowdrift for Windows: plan

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
| Settings | `UserDefaults` | a small file in `%APPDATA%\Snowdrift` (a test flag points it elsewhere) |
| Launch at login | `SMAppService` | `HKCU\…\Run` value, only when the user ticks it |
| Pause | lock, screensaver, sleep, Low Power | `WTSRegisterSessionNotification` (lock), display power events, battery saver |
| Display changes | `didChangeScreenParameters` | `WM_DISPLAYCHANGE` / `WM_DPICHANGED` |

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
| W1 | Overlay window per monitor, Direct3D 11 + DirectComposition, stateless falling flakes | offscreen render to PNG over SSH; then a person at the laptop |
| W2 | Window tracking (event-driven, DWM frames, cloaked/minimized filter), taskbar surface | `--log` over SSH |
| W3 | Port physics: piles, landing map, slab, friction, lumps, plow; self-check | `--selftest` over SSH |
| W4 | Tray menu and settings, pause rules, display changes, full screen | person at the laptop |
| W5 | Release: one zipped `Snowdrift.exe`, CPU/memory check, README, GitHub release next to the Mac zip | release page |

## Working on the test laptop (a friend's machine)

- Everything stays inside `D:\snowdrift\` (outside the owner's `D:\voicelab` data): source, the Rust
  toolchain (official component archives, SHA-256 checked, just unpacked: no rustup installer, which
  could write to the registry), `CARGO_HOME`, build output, test settings, logs. No admin rights,
  PATH/registry changes or Visual Studio (the GNU toolchain brings its own linker).
  `windows/build.ps1` sets PATH and `CARGO_HOME` for its own process only.
- Only processes we start are stopped; every test run has an auto-quit (`--seconds N`).
- Programs started over SSH can't show windows on the laptop's screen (no interactive desktop), so
  over SSH we run the self-check and render test frames to PNG files. Seeing it live needs someone
  at the laptop to double-click the exe. (A scheduled task could get around this, but it's a system
  change, so we don't.)
- Downloads happen only after the owner of this repo approves them (Rust 1.99.1: ~235 MB, approved).
