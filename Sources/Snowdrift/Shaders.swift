// Metal shaders, compiled once at startup from this string (no Xcode / metal toolchain needed).
// Coordinates arrive in points, screen-local, y down.

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Flake { float y0, size, alpha, soft, fall, swayAmp, swayFreq, phase, lands; };  // static
struct Uniforms { float2 viewSize; float time; float wind; float dt; };
struct VOut { float4 pos [[position]]; float2 uv; float alpha; float soft; };

static float4 toNDC(float2 p, float2 viewSize) {          // points, y down -> clip space
    return float4(p.x / viewSize.x * 2.0 - 1.0, 1.0 - p.y / viewSize.y * 2.0, 0, 1);
}

// Integer hash -> [0,1). Gives each flake a new x every time it re-enters at the top.
static float hash01(uint a, uint b) {
    uint h = a * 747796405u + b * 2891336453u;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15;
    return float(h & 0xffffu) / 65535.0;
}

// Closed-form flake position at time t. `cycle` = which trip down the screen this is.
static float2 flakePos(Flake f, uint iid, float t, constant Uniforms &u, thread uint &cycle) {
    float span = u.viewSize.y + 20.0;
    float d    = f.y0 + f.fall * t;                    // total distance fallen
    float c    = floor(d / span);
    float y    = d - c * span - 10.0;
    // Start further left by however far the wind carries this flake during its trip, so a strong
    // wind doesn't leave the left of the screen bare.
    float windSpan = max(u.wind, 0.0) * span / f.fall;
    float x    = hash01(iid, uint(c)) * (u.viewSize.x + 40.0 + windSpan) - 20.0 - windSpan
               + u.wind * (y + 10.0) / f.fall                         // drift during this trip
               + f.swayAmp * sin(t * f.swayFreq + f.phase);
    cycle = uint(c);
    return float2(x, y);
}

static int mapIndex(float x, float width) { return clamp(int(x / width * 512.0), 0, 511); }

// maps[0..511]: top of the first surface below (landing flakes stop there)
// maps[512..1023]: ground top (every flake stops there)
vertex VOut flakeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device Flake *flakes [[buffer(0)]],
                        constant Uniforms &u [[buffer(1)]],
                        constant float *maps [[buffer(2)]],
                        device uint *state [[buffer(3)]]) {
    Flake f = flakes[iid];
    uint cycle;
    float2 p = flakePos(f, iid, u.time, u, cycle);
    int ix = mapIndex(p.x, u.viewSize.x);
    float land = maps[ix], ground = maps[512 + ix];
    // The only per-flake state: state[i] = trip number + 1 if the flake landed on that trip.
    // Set only when a flake *crosses* a surface line this frame, so a window that appears or
    // rises over flakes doesn't swallow them: they were already past, in front of its face.
    // Written here in the vertex shader (Apple GPUs allow it), so no extra compute pass.
    if (vid == 0 && f.lands > 0.5 && p.y >= land && p.y - f.fall * u.dt < land) state[iid] = cycle + 1;
    bool landed = f.lands > 0.5 && state[iid] == cycle + 1;
    // Fade over the last few points above a line, so a flake melts into the pile instead of popping.
    float fade = clamp((ground + 1.0 - p.y) / 3.0, 0.0, 1.0);
    if (f.lands > 0.5 && p.y <= land) fade *= clamp((land + 1.0 - p.y) / 3.0, 0.0, 1.0);
    if (landed) fade = 0.0;
    VOut o;
    float2 corner = float2(vid & 1, vid >> 1) * 2.0 - 1.0;            // triangle-strip quad
    o.pos = fade > 0.0 ? toNDC(p + corner * f.size * 0.5, u.viewSize) : float4(2, 2, 2, 1);
    o.uv = corner; o.alpha = f.alpha * fade; o.soft = f.soft;
    return o;
}

fragment float4 flakeFragment(VOut in [[stage_in]]) {
    float a = (1.0 - smoothstep(1.0 - in.soft, 1.0, length(in.uv))) * in.alpha;
    return float4(a);                                   // premultiplied white
}

// Clumps: CPU particles (x, y, size, alpha), screen-local.
vertex VOut clumpVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant float4 *c [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    float2 corner = float2(vid & 1, vid >> 1) * 2.0 - 1.0;
    VOut o;
    o.pos = toNDC(c[iid].xy + corner * c[iid].z * 0.5, u.viewSize);
    o.uv = corner; o.alpha = c[iid].w; o.soft = 0.35;
    return o;
}

// Occluders: window / Dock / menu bar rects, depth only.
struct Occ { float4 r; float depth; float pad0, pad1, pad2; };
struct OOut { float4 pos [[position]]; };
vertex OOut occVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                      constant Occ *o [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    float2 c = float2(vid & 1, vid >> 1);
    OOut out;
    out.pos = toNDC(o[iid].r.xy + c * o[iid].r.zw, u.viewSize);
    out.pos.z = o[iid].depth;
    return out;
}
fragment float4 occFragment() { return float4(0); }      // color writes are masked off

// Piles: one quad per column, its top sloped to the next column's height (smooth surface).
// origin = this chunk's left x and the surface's top y; startX = chunk start within the surface
struct PileParams { float2 origin; float colW; float depth; float radius; float startX; float width; uint count; };
struct POut { float4 pos [[position]]; float v; };
vertex POut pileVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant float *h [[buffer(0)]], constant Uniforms &u [[buffer(1)]],
                       constant PileParams &p [[buffer(2)]]) {
    uint right = vid & 1, top = vid >> 1;
    float hx = h[min(iid + right, p.count - 1)];
    // Rounded window corners: the base follows the curve (same formula as Surface.drop on the CPU).
    float lx = p.startX + float(iid + right) * p.colW;
    float d = min(lx, p.width - lx), base = 0.0;
    if (d < p.radius) { float e = p.radius - max(d, 0.0); base = p.radius - sqrt(p.radius * p.radius - e * e); }
    float2 pos = float2(p.origin.x + float(iid + right) * p.colW, p.origin.y + base - float(top) * hx);
    POut o;
    o.pos = toNDC(pos, u.viewSize);
    o.pos.z = p.depth;
    o.v = float(top);
    return o;
}
fragment float4 pileFragment(POut in [[stage_in]]) {
    return float4(mix(float3(0.784, 0.827, 0.902), float3(0.984, 0.988, 1.0), in.v), 1.0);
}

// --debug: outlines. Top edge (the snow surface) in cyan, the rest in red.
struct ROut { float4 pos [[position]]; float2 local; float2 size; };
vertex ROut rectVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant float4 *rects [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    float4 r = rects[iid];                              // x, y, w, h
    float2 c = float2(vid & 1, vid >> 1);
    ROut o;
    o.pos = toNDC(r.xy + c * r.zw, u.viewSize);
    o.local = c * r.zw; o.size = r.zw;
    return o;
}
fragment float4 rectFragment(ROut in [[stage_in]]) {
    if (in.local.y < 3.0) return float4(0.0, 0.75, 0.9, 0.9);
    float edge = min(min(in.local.x, in.size.x - in.local.x), in.size.y - in.local.y);
    if (edge > 1.5) discard_fragment();
    return float4(0.8, 0.2, 0.2, 0.8);
}
"""
