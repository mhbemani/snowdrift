/// Every tunable of the snow, in one place. Distances in points (pt), times in seconds, y down.
enum Physics {
    // Grid and limits
    static let colW: Float = 2                // a pile is a height per column this wide
    static let mapSize = 512                  // landing-map entries per screen (GPU limit: 4 KB for both maps)
    static let maxClumps = 800                // falling lumps alive at once
    static let tick: Double = 1.0 / 20        // growth and slumping run at 20 Hz

    // Growth
    static let fillTime: Float = 1067         // seconds for exposed snow to rise 10 pt (≈ 11 min to a window's full cover)
    static let fullAt: Float = 0.6            // a pile stops growing at this share of its max height *on average*,
                                              // so it stays lumpy instead of filling every column to a flat top
    static let maxSlope: Float = 1.0          // typical steepest height difference between neighbouring columns
    static let cohesion: ClosedRange<Float> = 0.7...2.0   // per spot, × maxSlope: snow is stickier in some places,
                                              // so slumping stops on its own and keeps natural bumps
    static let windowMax: Float = 10, dockMax: Float = 8, groundMax: Float = 24   // max pile heights

    // Lumps (loose snow in the air)
    static let gravity: Float = 900           // pt/s², slowed by air
    static let maxFall: Float = 350           // pt/s
    static let clumpMass: Float = 8           // pt² of snow that leaves an edge as one lump
    static let lumpReachCm: ClosedRange<Float> = 6...7    // lumps fade out within this fall distance

    // A window's snow slab
    static let slabGravity: Float = 3000      // pt/s²; hop height = speed²/(2·this): stop at 400 pt/s → ~27 pt
    static let breakLift: Float = 40          // a slab lifted higher than this breaks into lumps
    static let maxThrowCm: Float = 10         // snow thrown up by a stopping window rises at most this high

    // Sideways friction on a window
    static let staticFriction: Float = 0.7    // snow sticks while the window accelerates ≤ this·g
    static let kineticFriction: Float = 0.5   // once slipping, the slide slows at this·g
    static let sideSmoothing: Float = 0.08    // s; window speed is smoothed first (sample jitter)

    // Mouse plow
    static let plowRadius: Float = 10         // the cursor pushes snow with a circle this big
    static let hillHeight: Float = 0.8        // a pushed hill's peak, at most this × the surface's max snow depth
    static let hillSteepness: Float = 0.8     // its steepest part rises this much per column (~22°): a gentle mound
    static let packedSettle: Float = 0.995    // per 20 Hz tick: packed snow loosens over ~10 s

    // ponytail: one corner radius for every window. macOS 26 uses ~16 pt (plain) to ~26 pt (toolbar);
    // the real radius isn't exposed without reading pixels.
    static let cornerRadius: Float = 20
}
