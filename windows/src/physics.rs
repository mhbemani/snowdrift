//! Every tunable of the snow, in one place (same values as macOS `Physics.swift`).
//! Distances in DIPs (≈ macOS points), times in seconds, y down.

// Grid and limits
pub const COL_W: f32 = 2.0;                 // a pile is a height per column this wide
pub const MAP_SIZE: usize = 512;            // landing-map entries per screen
pub const MAX_CLUMPS: usize = 800;          // falling lumps alive at once
pub const TICK: f64 = 1.0 / 20.0;           // growth and slumping run at 20 Hz

// Growth
pub const FILL_TIME: f32 = 1067.0;          // seconds for exposed snow to rise 10 DIP
pub const FULL_AT: f32 = 0.6;               // a pile stops growing at this share of its max height, on average
pub const MAX_SLOPE: f32 = 1.0;             // typical steepest height difference between neighbouring columns
pub const COHESION: (f32, f32) = (0.7, 2.0);// per spot, × MAX_SLOPE: slumping stops on its own, keeps bumps
pub const WINDOW_MAX: f32 = 10.0;
pub const DOCK_MAX: f32 = 8.0;              // the taskbar
pub const GROUND_MAX: f32 = 24.0;

// Lumps
pub const GRAVITY: f32 = 900.0;
pub const MAX_FALL: f32 = 350.0;
pub const CLUMP_MASS: f32 = 8.0;
pub const LUMP_REACH_CM: (f32, f32) = (6.0, 7.0);

// A window's snow slab
pub const SLAB_GRAVITY: f32 = 3000.0;       // hop height = speed²/(2·this)
pub const BREAK_LIFT: f32 = 40.0;
pub const MAX_THROW_CM: f32 = 10.0;

// Sideways friction
pub const STATIC_FRICTION: f32 = 0.7;
pub const KINETIC_FRICTION: f32 = 0.5;
pub const SIDE_SMOOTHING: f32 = 0.08;

// Mouse plow
pub const PLOW_RADIUS: f32 = 10.0;
pub const HILL_HEIGHT: f32 = 0.8;           // × the surface's max depth
pub const HILL_STEEPNESS: f32 = 0.8;
pub const PACKED_SETTLE: f32 = 0.995;

// Windows 11 rounds window corners by 8 DIP (DWMWCP_ROUND).
pub const CORNER_RADIUS: f32 = 8.0;
