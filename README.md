# Snowdrift ❄️

Snow that falls over your whole macOS desktop, piles up on your windows and the Dock, and reacts to your mouse and to windows you move, with physics close to real life.

Built to run all day, so it is designed for the lowest possible CPU and memory use.

> Work in progress. macOS first; Windows 11 later.

## Status

| Milestone | What | State |
|---|---|---|
| M0 | Click-through overlay on every screen, Metal-drawn falling snow | ✅ |
| M1 | Window tracking (position, z-order, velocity) with lag prediction | ✅ |
| M2 | Snow piles on window tops, the Dock and the screen bottom | ✅ |
| M3 | Window motion physics: snow rides along, lifts off, is thrown up; rounded corners, Stage Manager, Dock shape, full screen | ✅ |
| M4 | Mouse pushes and compacts snow | ⏳ |
| M5 | Menu bar settings, multiple monitors, pause rules | |
| M6 | Signed release | |

The full plan is in [Snowdrift-Starter-Sheet.pdf](Snowdrift-Starter-Sheet.pdf).

## How it stays light

- **Stateless GPU particles.** Snow falls at terminal velocity, so each flake's position is a closed-form function of time computed in the vertex shader. The CPU never loops over flakes: one time value and one draw call per frame.
- **Static GPU data.** Flake data is uploaded once at startup and never touched again.
- **1x drawables, 2 buffers.** Flakes are soft dots, so the overlay renders at 1x instead of Retina 2x with 2 drawables instead of 3: about 4x less GPU memory per screen.
- **Adaptive window polling on its own thread.** Reading the window list costs ~1 ms and can wait ~10 ms, so it never runs on the render thread. It polls 4 times a second when idle and every frame only while the mouse is down or something just moved.
- **Piles grow from a rate, not from flakes.** The GPU moves every flake; the CPU only knows how many land per second (~9) and adds snow as random bumps on whatever surface is exposed. Piles are height maps with a sand-pile slump rule at 20 Hz, run only on piles still changing; growth slows near the max height, so full piles cost nothing.
- **Occlusion for free.** Windows are drawn into a depth buffer only, so snow on a window behind another is hidden by the GPU. On Apple GPUs that depth buffer is memoryless (tile memory, no RAM).
- **Physics only while things move.** Window physics runs only when a window's velocity sample changes. One rule (snow stays unless the window accelerates down faster than gravity) covers dropping a window and stopping one that moves up. Flakes remember a landing with one number each, written by the flake vertex shader itself, so there's no extra GPU pass.
- **Dock without permissions.** The Dock's platter is computed from its live reserved height and its item count, using proportions measured once from a screenshot, so it follows the Dock as apps launch, quit, or get pinned.
- **Prediction.** Window positions are extrapolated to the moment the frame reaches the screen, so snow doesn't trail a dragged window.
- **No permissions, no network.** Only window rectangles are read (no titles, no pixels), so it never asks for Screen Recording or Accessibility.

Measured on an Apple Silicon Mac with piles: about 2–5% of one CPU core (depends on system load) and 20–45 MB of memory at 60 fps.

## Run

Requires macOS 14+ and the Xcode Command Line Tools (full Xcode isn't needed: shaders compile at runtime).

```bash
swift run -c release Snowdrift
```

| Option | Meaning |
|---|---|
| `--seconds N` | quit automatically after N seconds |
| `--fps F` | frame rate cap (default 60) |
| `--debug` | outline tracked windows and the Dock estimate (cyan top edge = snow surface), print stats on quit |
| `--lead L` | predict window positions L frames ahead (default 1) |
| `--snowrate R` | pile growth speed multiplier (default 1; 10 to see piles fast) |

Quit from the snowflake in the menu bar. The overlay never catches clicks.

## Tech

Swift 6 · AppKit · Metal (runtime-compiled MSL) · Core Graphics window list · Swift Package Manager
