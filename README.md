# Snowdrift ❄️

Snow that falls over your whole desktop (macOS and Windows), piles up on your windows and the Dock or taskbar, and reacts to your mouse and to windows you move, with physics close to real life.

Built to run all day, so it is designed for the lowest possible CPU and memory use.

> macOS 1.0 is out. The Windows 11 version is built and being tested (see [the plan](docs/windows-plan.md)).

## Status

| Milestone | What | State |
|---|---|---|
| M0 | Click-through overlay on every screen, Metal-drawn falling snow | ✅ |
| M1 | Window tracking (position, z-order, velocity) with lag prediction | ✅ |
| M2 | Snow piles on window tops, the Dock and the screen bottom | ✅ |
| M3 | Window motion physics: snow rides along, lifts off, is thrown up; rounded corners, Stage Manager, Dock shape, full screen | ✅ |
| M4 | Mouse pushes and compacts snow; slab physics, sideways friction, fading lumps | ✅ |
| M5 | Menu bar settings, multiple monitors, pause rules | ✅ |
| M6 | Packaged .app, launch at login, signed release | ✅ |

The full plan is in [docs/Snowdrift-Starter-Sheet.pdf](docs/Snowdrift-Starter-Sheet.pdf). The Windows version's plan: [docs/windows-plan.md](docs/windows-plan.md).

## How it stays light

- **Stateless GPU particles.** Snow falls at terminal velocity, so each flake's position is a closed-form function of time computed in the vertex shader. The CPU never loops over flakes: one time value and one draw call per frame.
- **Static GPU data.** Flake data is uploaded once at startup and never touched again.
- **1x drawables, 2 buffers.** Flakes are soft dots, so the overlay renders at 1x instead of Retina 2x with 2 drawables instead of 3: about 4x less GPU memory per screen.
- **Adaptive window polling on its own thread.** Reading the window list costs ~1 ms and can wait ~10 ms, so it never runs on the render thread. It polls 4 times a second when idle and every frame only while the mouse is down or something just moved.
- **Piles grow from a rate, not from flakes.** The GPU moves every flake; the CPU only knows how many land per second (~9) and adds snow as random bumps on whatever surface is exposed. A pile stops growing at 60% of its max height *on average*, so it stays lumpy.
- **Snow that settles by itself.** Piles are height maps with a sand-pile rule at 20 Hz, but every spot has its own random stickiness (0.7–2× the normal slope limit). Slumping stops on its own within seconds, keeps natural bumps, and can't build towers; piles at rest cost nothing.
- **Occlusion for free.** Windows are drawn into a depth buffer only, so snow on a window behind another is hidden by the GPU. On Apple GPUs that depth buffer is memoryless (tile memory, no RAM).
- **Jitter-proof window physics.** Window positions are sampled at 60 Hz out of sync with WindowServer, so a steady 400 pt/s drag reads as 3, 10, 6, 7, 3, 11 pt steps and "acceleration" swings ±10,000 pt/s². So a window's snow is one slab tested against where free-flying snow would be (position-based, with one sample of tolerance): it rides along, hops on a stop, and only breaks apart on a fast flick. Sideways, static and kinetic friction act on a smoothed window speed: no slip from jitter, a slide on a sudden stop. Every rule was replayed on measured window motion before it shipped, and `--selftest` keeps it that way.
- **Flakes remember landing in the shader.** One number per flake, written by the flake vertex shader itself, so there's no extra GPU pass.
- **Lumps fade by real distance.** Falling lumps thin out and are gone within 6–7 cm, measured with the display's physical size.
- **Dock without permissions.** The Dock's platter is computed the way the Dock lays itself out: icon size and items give its natural width (59 pt per icon at size 55), and when that doesn't fit the screen minus 40 pt per side it shrinks to fit. Checked against four measured Docks on two displays (within 1 pt); it follows the Dock as apps launch, quit, or get pinned.
- **A plow that only touches what it touches.** The cursor is a 10 pt circle following its real path; snow it passes through gathers into a gentle rounded hill that travels with it as its own layer (no eating or leaving bits of the snow under it). A full hill takes no more snow, and stops whole against a screen edge.
- **Prediction.** Window positions are extrapolated to the moment the frame reaches the screen, so snow doesn't trail a dragged window.
- **Zero cost when nobody's looking.** Drawing and window polling stop entirely while snow is off, the screen is locked, the screensaver runs or the displays sleep; Low Power Mode halves the frame rate.
- **No permissions, no network.** Only window rectangles are read (no titles, no pixels), so it never asks for Screen Recording or Accessibility.

Measured on an Apple Silicon Mac with piles: about 2–5% of one CPU core (depends on system load) and 20–50 MB of memory at 60 fps.

## Install

1. Download `Snowdrift-1.0.0.zip` from [Releases](../../releases) and unzip it.
2. Move **Snowdrift.app** to your Applications folder.
3. Open it. The first time, macOS says it can't check the app (it's signed by me, not notarized by Apple):
   open **System Settings → Privacy & Security**, scroll down, click **Open Anyway**, and confirm. You only do this once.
4. A ❄ appears in the menu bar. Turn on **Launch at Login** there if you want it every day.

Works on Apple Silicon and Intel Macs with macOS 14 or later. It asks for no permissions and uses no network.

## Build

```bash
macos/scripts/build-app.sh 1.0.0      # → macos/dist/Snowdrift.app and Snowdrift-1.0.0.zip (universal, ad-hoc signed)
```

With a paid Apple developer account, set `SIGN_ID="Developer ID Application: …"` before running it (then notarize the zip with `notarytool`).

## Run from source

Requires macOS 14+ and the Xcode Command Line Tools (full Xcode isn't needed: shaders compile at runtime).

```bash
cd macos && swift run -c release Snowdrift
```

| Option | Meaning |
|---|---|
| `--seconds N` | quit automatically after N seconds |
| `--fps F` | frame rate cap, 1–120 (default 60) |
| `--debug` | outline tracked windows and the Dock estimate (cyan top edge = snow surface), print stats on quit |
| `--lead L` | predict window positions L frames ahead, 0–5 (default 1) |
| `--snowrate R` | pile growth speed multiplier (default 1; 20 to see piles fast) |
| `--log` | print why snow leaves a window (tracking, slab breaking, sliding) |
| `--selftest` | check the physics invariants (snow conserved, jitter ignored, hops land back, plow stays local, slumping stops) and exit |

The snowflake in the menu bar has: Snow on/off, Snowfall (Light / Medium / Heavy), Wind (Calm / Breeze / Windy), Clear All Snow, Hide from Screen Sharing (on by default), Launch at Login (in the app), and Quit. Settings are remembered. Displays can be plugged in, removed or rearranged while it runs. The overlay never catches clicks.

## Code

The repo has one folder per platform: `macos/` (Swift, shipped), `windows/` (Rust, in testing), and `docs/`.

macOS files, under `macos/Sources/Snowdrift/` unless noted:

| File | Role |
|---|---|
| `main.swift` | startup, validated command-line options |
| `Controller.swift` | menu bar, settings, pause rules, displays, Dock refresh |
| `Snowpack.swift` | coordinates the snow: surfaces, piles, window motion, plow, growth, lumps, landing maps |
| `Model.swift` | surfaces, lumps, piles and the per-pile physics (slab, friction, plow hill, slumping) |
| `Physics.swift` | every tunable, in one place |
| `WindowTracker.swift` | window positions on a background thread (no permissions) |
| `Dock.swift` | the Dock's platter from its layout |
| `Renderer.swift`, `Shaders.swift` | Metal: shared GPU setup, per-screen drawing, the shaders |
| `SelfTest.swift` | `--selftest` |
| `macos/scripts/build-app.sh` | universal `.app`, signing, release zip |
| `macos/scripts/make-icon.swift` | draws `macos/Resources/AppIcon.icns` |

Windows files, under `windows/src/` unless noted (same physics and self-check scenarios as macOS):

| File | Role |
|---|---|
| `main.rs` | options, the live loop (pausing, rebuilds), the headless checks and `--bench` |
| `desktop.rs` | monitors, windows (event hooks + DWM frames), taskbar, full screen, mouse |
| `snowpack.rs`, `model.rs`, `physics.rs` | the snow, ported line for line from Swift |
| `gpu.rs`, `shaders.rs`, `overlay.rs` | Direct3D 11 drawing, HLSL, one DirectComposition overlay per monitor |
| `tray.rs`, `settings.rs` | tray menu, lock/display-off events, `snowdrift.ini`, Launch at Login |
| `selftest.rs` | `--selftest` |
| `windows/build.rs` | links the icon into the exe |
| `windows/sync.sh`, `test.sh`, `package.sh` | build, check and zip on the Windows test machine over SSH |

Windows: measured 0.9% of one CPU core and a 16.8 MB working set at 60 fps (`--bench`, RTX 3070 laptop, 1080p).

## Tech

macOS: Swift 6 · AppKit · Metal (runtime-compiled MSL) · Core Graphics window list · Swift Package Manager

Windows: Rust · Direct3D 11 · DirectComposition · HLSL (runtime-compiled) · WinEvent hooks · DWM
