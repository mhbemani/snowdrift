//! HLSL shaders, compiled once at startup by d3dcompiler_47.dll (part of Windows).
//! A port of the macOS Metal shaders: same math, same coordinates (DIPs, screen-local, y down).

pub const HLSL: &str = r#"
cbuffer Uniforms : register(b0) { float2 viewSize; float time; float wind; float dt; float3 pad0; };
// maps[0..511]: top of the first surface below (landing flakes stop); maps[512..1023]: ground top.
cbuffer Maps : register(b1) { float4 maps4[256]; };
cbuffer Pile : register(b2) { float2 pOrigin; float pColW; float pDepth; float pRadius; float pStartX; float pWidth; uint pCount; uint pOffset; float3 pad1; };

struct Flake { float y0, size, alpha, soft, fall, swayAmp, swayFreq, phase, lands; };
struct Occ { float4 r; float depth; float3 pad; };
StructuredBuffer<Flake> flakes : register(t0);
StructuredBuffer<float> heights : register(t1);
StructuredBuffer<Occ> occs : register(t2);
StructuredBuffer<float4> clumps : register(t3);
// The only per-flake state: trip number + 1 if the flake landed on that trip (written by the VS).
RWStructuredBuffer<uint> landed : register(u1);

float mapAt(int i) { return maps4[i >> 2][i & 3]; }
float4 toNDC(float2 p) { return float4(p.x / viewSize.x * 2.0 - 1.0, 1.0 - p.y / viewSize.y * 2.0, 0, 1); }
float hash01(uint a, uint b) {
    uint h = a * 747796405u + b * 2891336453u;
    h ^= h >> 16; h *= 0x7feb352du; h ^= h >> 15;
    return float(h & 0xffffu) / 65535.0;
}

struct VOut { float4 pos : SV_Position; float2 uv : UV; float alpha : ALPHA; float soft : SOFT; };

// Stateless flakes: the position is a closed-form function of time (terminal velocity).
VOut flakeVS(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    Flake f = flakes[iid];
    float span = viewSize.y + 20.0;
    float d = f.y0 + f.fall * time;
    float c = floor(d / span);
    uint cycle = (uint)c;
    float y = d - c * span - 10.0;
    float windSpan = max(wind, 0.0) * span / f.fall;
    float x = hash01(iid, cycle) * (viewSize.x + 40.0 + windSpan) - 20.0 - windSpan
            + wind * (y + 10.0) / f.fall + f.swayAmp * sin(time * f.swayFreq + f.phase);
    int ix = clamp((int)(x / viewSize.x * 512.0), 0, 511);
    float land = mapAt(ix), ground = mapAt(512 + ix);
    // Landing is recorded only when a flake crosses a surface line this frame, so a window that
    // opens or rises over flakes doesn't swallow them.
    if (vid == 0 && f.lands > 0.5 && y >= land && y - f.fall * dt < land) landed[iid] = cycle + 1;
    bool isLanded = f.lands > 0.5 && landed[iid] == cycle + 1;
    float fade = saturate((ground + 1.0 - y) / 3.0);
    if (f.lands > 0.5 && y <= land) fade *= saturate((land + 1.0 - y) / 3.0);
    if (isLanded) fade = 0.0;
    float2 corner = float2(vid & 1, vid >> 1) * 2.0 - 1.0;
    VOut o;
    o.pos = fade > 0.0 ? toNDC(float2(x, y) + corner * f.size * 0.5) : float4(2, 2, 2, 1);
    o.uv = corner; o.alpha = f.alpha * fade; o.soft = f.soft;
    return o;
}

float4 flakePS(VOut i) : SV_Target {
    float a = (1.0 - smoothstep(1.0 - i.soft, 1.0, length(i.uv))) * i.alpha;
    return float4(a, a, a, a);                       // premultiplied white
}

// Lumps: CPU particles (x, y, size, alpha), screen-local.
VOut clumpVS(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float4 c = clumps[iid];
    float2 corner = float2(vid & 1, vid >> 1) * 2.0 - 1.0;
    VOut o;
    o.pos = toNDC(c.xy + corner * c.z * 0.5);
    o.uv = corner; o.alpha = c.w; o.soft = 0.35;
    return o;
}

// Occluders: window / taskbar rects, depth only (color writes are masked off).
float4 occVS(uint vid : SV_VertexID, uint iid : SV_InstanceID) : SV_Position {
    Occ o = occs[iid];
    float2 c = float2(vid & 1, vid >> 1);
    float4 p = toNDC(o.r.xy + c * o.r.zw);
    p.z = o.depth;
    return p;
}
float4 occPS() : SV_Target { return float4(0, 0, 0, 0); }

// Piles: one quad per column, its top sloped to the next column (smooth); the base follows
// rounded window corners.
struct POut { float4 pos : SV_Position; float v : V; };
POut pileVS(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    uint right = vid & 1, top = vid >> 1;
    float hx = heights[pOffset + min(iid + right, pCount - 1)];
    float lx = pStartX + (float)(iid + right) * pColW;
    float d = min(lx, pWidth - lx), base = 0.0;
    if (d < pRadius) { float e = pRadius - max(d, 0.0); base = pRadius - sqrt(pRadius * pRadius - e * e); }
    float2 p = float2(pOrigin.x + (float)(iid + right) * pColW, pOrigin.y + base - (float)top * hx);
    POut o;
    o.pos = toNDC(p);
    o.pos.z = pDepth;
    o.v = (float)top;
    return o;
}
float4 pilePS(POut i) : SV_Target {
    return float4(lerp(float3(0.784, 0.827, 0.902), float3(0.984, 0.988, 1.0), i.v), 1.0);
}
"#;
