// Falling flakes are *stateless GPU particles*: each flake's position is a closed-form
// function of time computed in the vertex shader (snow falls at terminal velocity, so
// position = start + speed * t is exact). The CPU never loops over flakes.
//
// Per frame, per screen: windows go into the depth buffer only (no color), so snow piles on a
// window behind another one are hidden for free; then piles, falling flakes, and clumps.
// The depth buffer is memoryless on Apple GPUs: it lives in tile memory and costs no RAM.

import AppKit
import MetalKit

// Compiled at runtime, so no Xcode / metal toolchain needed.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Flake { float y0, size, alpha, soft, fall, swayAmp, swayFreq, phase, lands; };  // static
struct Uniforms { float2 viewSize; float time; float wind; };
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

// maps[0..511]: top of the first surface below (landing flakes stop there)
// maps[512..1023]: ground top (every flake stops there)
vertex VOut flakeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device Flake *flakes [[buffer(0)]],
                        constant Uniforms &u [[buffer(1)]],
                        constant float *maps [[buffer(2)]]) {
    Flake f = flakes[iid];
    float span  = u.viewSize.y + 20.0;
    float d     = f.y0 + f.fall * u.time;              // total distance fallen
    float cycle = floor(d / span);                      // which trip down the screen
    float y     = d - cycle * span - 10.0;
    float x     = hash01(iid, uint(cycle)) * (u.viewSize.x + 40.0) - 20.0
                + u.wind * (y + 10.0) / f.fall                        // drift during this trip
                + f.swayAmp * sin(u.time * f.swayFreq + f.phase);
    int ix = clamp(int(x / u.viewSize.x * 512.0), 0, 511);
    float stopY = f.lands > 0.5 ? maps[ix] : maps[512 + ix];
    // Fade over the last few points, so a flake melts into the pile instead of popping.
    float fade = clamp((stopY + 1.0 - y) / 3.0, 0.0, 1.0);
    VOut o;
    float2 corner = float2(vid & 1, vid >> 1) * 2.0 - 1.0;            // triangle-strip quad
    o.pos = fade > 0.0 ? toNDC(float2(x, y) + corner * f.size * 0.5, u.viewSize) : float4(2, 2, 2, 1);
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
struct PileParams { float2 origin; float colW; float depth; uint count; };   // origin = left x, base y
struct POut { float4 pos [[position]]; float v; };
vertex POut pileVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant float *h [[buffer(0)]], constant Uniforms &u [[buffer(1)]],
                       constant PileParams &p [[buffer(2)]]) {
    uint right = vid & 1, top = vid >> 1;
    float hx = h[min(iid + right, p.count - 1)];
    float2 pos = float2(p.origin.x + float(iid + right) * p.colW, p.origin.y - float(top) * hx);
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

private struct Flake { var y0, size, alpha, soft, fall, swayAmp, swayFreq, phase, lands: Float }   // matches MSL
private struct Uniforms { var viewSize: SIMD2<Float>; var time: Float; var wind: Float }
private struct Occ { var r: SIMD4<Float>; var depth: Float; var p0: Float = 0, p1: Float = 0, p2: Float = 0 }   // 32 B, matches MSL
private struct PileParams { var origin: SIMD2<Float>; var colW: Float; var depth: Float; var count: UInt32 }

@MainActor
final class SnowRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let flakePipeline, clumpPipeline, occPipeline, pilePipeline: MTLRenderPipelineState
    private let rectPipeline: MTLRenderPipelineState?
    private let depthWrite, depthTestOnly, depthOff: MTLDepthStencilState
    private let flakes: MTLBuffer
    private let count: Int
    private var uniforms: Uniforms
    private let start = CACurrentMediaTime()
    private let snowpack: Snowpack
    private let screenIndex: Int
    private let tracker: WindowTracker
    private var mouseWasDown = false
    /// Landing flakes per second reaching the ground line on this screen (feeds pile growth).
    let landingRate: Float

    // Scratch arrays reused every frame (no per-frame allocation).
    private var occ: [Occ] = []
    private var clumpData: [SIMD4<Float>] = []
    private var rects: [SIMD4<Float>] = []

    static let depthFormat = MTLPixelFormat.depth32Float

    init(device: MTLDevice, size: CGSize, screenIndex: Int, snowpack: Snowpack, tracker: WindowTracker, debug: Bool) throws {
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        func pipeline(_ v: String, _ f: String, color: Bool = true) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: v)
            desc.fragmentFunction = lib.makeFunction(name: f)
            desc.depthAttachmentPixelFormat = Self.depthFormat
            let ca = desc.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.writeMask = color ? .all : []
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        flakePipeline = try pipeline("flakeVertex", "flakeFragment")
        clumpPipeline = try pipeline("clumpVertex", "flakeFragment")
        occPipeline = try pipeline("occVertex", "occFragment", color: false)
        pilePipeline = try pipeline("pileVertex", "pileFragment")
        rectPipeline = debug ? try pipeline("rectVertex", "rectFragment") : nil

        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare; d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = depth(.less, write: true)
        depthTestOnly = depth(.less, write: false)
        depthOff = depth(.always, write: false)

        // ponytail: flake count scales with screen area, density setting comes in M5
        count = Int(size.width * size.height / 4500)
        let h = Float(size.height)
        let data = (0..<count).map { _ -> Flake in
            let depth = pow(Float.random(in: 0...1), 3)                   // mostly small/far, few big/near
            return Flake(y0: Float.random(in: 0...h), size: 2 + 7 * depth,  // 2–9 pt
                         alpha: depth > 0.6 ? 0.35 : Float.random(in: 0.5...0.9),
                         soft: depth > 0.6 ? 0.9 : 0.45,                    // near flakes are blurred
                         fall: 30 + 70 * depth + Float.random(in: 0...15),  // pt/s, near = faster
                         swayAmp: Float.random(in: 4...14), swayFreq: Float.random(in: 1.3...2.4),
                         phase: Float.random(in: 0...(2 * .pi)),
                         // Near (big, blurry) flakes pass in front of everything; the rest land.
                         lands: depth < 0.6 && Float.random(in: 0..<1) < 0.7 ? 1 : 0)
        }
        landingRate = data.reduce(0) { $0 + $1.lands * $1.fall / (h + 20) }
        flakes = device.makeBuffer(bytes: data, length: MemoryLayout<Flake>.stride * count, options: .storageModeShared)!
        uniforms = Uniforms(viewSize: [Float(size.width), h], time: 0, wind: 6)
        self.snowpack = snowpack
        self.screenIndex = screenIndex
        self.tracker = tracker
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange newSize: CGSize) {
        uniforms.viewSize = [Float(view.bounds.width), Float(view.bounds.height)]
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let mouseDown = CGEventSource.buttonState(.combinedSessionState, button: .left)   // ~free, unlike NSEvent's
        if mouseDown && !mouseWasDown { tracker.mouseWentDown() }
        mouseWasDown = mouseDown
        snowpack.frame(now: now)

        // ponytail: time wraps every hour so Float keeps sub-ms precision; all flakes jump once
        // per hour (invisible in falling snow). Pass a Double split if that ever shows.
        uniforms.time = Float((now - start).truncatingRemainder(dividingBy: 3600))
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let screen = snowpack.screens[screenIndex].frame
        let ox = Float(screen.minX), oy = Float(screen.minY)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        // 1. Occluders: depth only.
        occ.removeAll(keepingCapacity: true)
        for s in snowpack.surfaces {
            if case .ground = s.key { continue }
            occ.append(Occ(r: [Float(s.x) - ox, Float(s.y) - oy, Float(s.width), Float(s.height)], depth: s.depth))
        }
        let ms = snowpack.screens[screenIndex].menuBar
        if ms > 0 { occ.append(Occ(r: [0, 0, Float(screen.width), Float(ms)], depth: 0.05)) }
        if !occ.isEmpty {
            enc.setRenderPipelineState(occPipeline)
            enc.setDepthStencilState(depthWrite)
            for chunk in stride(from: 0, to: occ.count, by: 128) {
                let n = min(128, occ.count - chunk)
                occ.withUnsafeBytes { enc.setVertexBytes($0.baseAddress! + chunk * MemoryLayout<Occ>.stride, length: n * MemoryLayout<Occ>.stride, index: 0) }
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
            }
        }

        // 2. Piles, hidden where a nearer window covers them.
        enc.setRenderPipelineState(pilePipeline)
        enc.setDepthStencilState(depthTestOnly)
        for s in snowpack.surfaces {
            guard s.x < screen.maxX, s.x + s.width > screen.minX, let p = snowpack.piles[s.key] else { continue }
            if case .ground(let g) = s.key, g != screenIndex { continue }
            let n = p.h.count
            // setVertexBytes is capped at 4 KB = 1024 floats: draw long piles in chunks sharing one column.
            var start = 0
            while start < n - 1 || (n == 1 && start == 0) {
                let end = min(start + 1024, n)
                var params = PileParams(origin: [Float(s.x) - ox + Float(start) * Snowpack.colW, Float(s.y) - oy],
                                        colW: Snowpack.colW, depth: s.depth - 0.001, count: UInt32(end - start))
                p.h.withUnsafeBytes { enc.setVertexBytes($0.baseAddress! + start * 4, length: (end - start) * 4, index: 0) }
                enc.setVertexBytes(&params, length: MemoryLayout<PileParams>.stride, index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: max(1, end - start - 1))
                if end == n { break }
                start = end - 1
            }
        }

        // 3. Falling flakes, in front of everything.
        enc.setDepthStencilState(depthOff)
        enc.setRenderPipelineState(flakePipeline)
        enc.setVertexBuffer(flakes, offset: 0, index: 0)
        snowpack.maps[screenIndex].withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)

        // 4. Clumps.
        clumpData.removeAll(keepingCapacity: true)
        for c in snowpack.clumps where Float(screen.minX) <= c.x && c.x < Float(screen.maxX) {
            clumpData.append([c.x - ox, c.y - oy, c.size, 0.95])
        }
        if !clumpData.isEmpty {
            enc.setRenderPipelineState(clumpPipeline)
            clumpData.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }   // ≤120 × 16 B
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: clumpData.count)
        }

        if let rectPipeline { drawOutlines(enc, rectPipeline, screen: screen) }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func drawOutlines(_ enc: MTLRenderCommandEncoder, _ pipeline: MTLRenderPipelineState, screen: CGRect) {
        rects.removeAll(keepingCapacity: true)
        var all = tracker.snapshot().windows.map(\.frame)
        if let d = snowpack.dockRect { all.append(d) }
        for f in all where f.intersects(screen) {
            rects.append([Float(f.minX - screen.minX), Float(f.minY - screen.minY), Float(f.width), Float(f.height)])
        }
        guard !rects.isEmpty else { return }
        enc.setRenderPipelineState(pipeline)
        rects.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: min($0.count, 4096), index: 0) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: min(rects.count, 256))
    }
}
