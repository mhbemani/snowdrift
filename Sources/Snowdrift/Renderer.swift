// Falling flakes are *stateless GPU particles*: each flake's position is a closed-form
// function of time computed in the vertex shader (snow falls at terminal velocity, so
// position = start + speed * t is exact). The CPU never loops over flakes: per frame it
// sets one time value and issues one draw call.

import AppKit
import MetalKit

// Compiled at runtime, so no Xcode / metal toolchain needed.
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Flake { float y0, size, alpha, soft, fall, swayAmp, swayFreq, phase; };   // static, written once
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

vertex VOut flakeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        const device Flake *flakes [[buffer(0)]],
                        constant Uniforms &u [[buffer(1)]]) {
    Flake f = flakes[iid];
    float span  = u.viewSize.y + 20.0;
    float d     = f.y0 + f.fall * u.time;              // total distance fallen
    float cycle = floor(d / span);                      // which trip down the screen
    float y     = d - cycle * span - 10.0;
    float x     = hash01(iid, uint(cycle)) * (u.viewSize.x + 40.0) - 20.0
                + u.wind * (y + 10.0) / f.fall                        // drift during this trip
                + f.swayAmp * sin(u.time * f.swayFreq + f.phase);
    float2 corner = float2(vid & 1, vid >> 1) * 2.0 - 1.0;            // triangle-strip quad
    VOut o;
    o.pos = toNDC(float2(x, y) + corner * f.size * 0.5, u.viewSize);
    o.uv = corner; o.alpha = f.alpha; o.soft = f.soft;
    return o;
}

fragment float4 flakeFragment(VOut in [[stage_in]]) {
    float a = (1.0 - smoothstep(1.0 - in.soft, 1.0, length(in.uv))) * in.alpha;
    return float4(a);                                   // premultiplied white
}

// --debug: window outlines. Top edge (the future snow surface) in cyan, the rest in red.
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

private struct Flake { var y0, size, alpha, soft, fall, swayAmp, swayFreq, phase: Float }   // matches MSL
private struct Uniforms { var viewSize: SIMD2<Float>; var time: Float; var wind: Float }

@MainActor
final class SnowRenderer: NSObject, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let flakePipeline: MTLRenderPipelineState
    private let rectPipeline: MTLRenderPipelineState?
    private let flakes: MTLBuffer
    private let count: Int
    private var uniforms: Uniforms
    private let start = CACurrentMediaTime()
    private let tracker: WindowTracker
    private let screenOrigin: CGPoint           // this screen's top-left in global top-left coords
    private var rects: [SIMD4<Float>] = []      // reused every frame, no reallocation
    private let lead: Double
    private var mouseWasDown = false

    /// lead: seconds to predict window positions ahead, hiding the 1–2 frames the overlay trails
    /// the real window. Calibration knob: tune by eye while dragging a window with --debug.
    init(device: MTLDevice, size: CGSize, screenOrigin: CGPoint, tracker: WindowTracker, lead: Double, debug: Bool) throws {
        self.lead = lead
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        func pipeline(_ v: String, _ f: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: v)
            desc.fragmentFunction = lib.makeFunction(name: f)
            let ca = desc.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        flakePipeline = try pipeline("flakeVertex", "flakeFragment")
        rectPipeline = debug ? try pipeline("rectVertex", "rectFragment") : nil

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
                         phase: Float.random(in: 0...(2 * .pi)))
        }
        flakes = device.makeBuffer(bytes: data, length: MemoryLayout<Flake>.stride * count, options: .storageModeShared)!
        uniforms = Uniforms(viewSize: [Float(size.width), h], time: 0, wind: 6)
        self.tracker = tracker
        self.screenOrigin = screenOrigin
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
        // ponytail: time wraps every hour so Float keeps sub-ms precision; all flakes jump once
        // per hour (invisible in falling snow). Pass a Double split if that ever shows.
        uniforms.time = Float((now - start).truncatingRemainder(dividingBy: 3600))
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        if let rectPipeline { drawOutlines(enc, rectPipeline, now: now) }

        enc.setRenderPipelineState(flakePipeline)
        enc.setVertexBuffer(flakes, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func drawOutlines(_ enc: MTLRenderCommandEncoder, _ pipeline: MTLRenderPipelineState, now: CFTimeInterval) {
        rects.removeAll(keepingCapacity: true)
        let screen = CGRect(origin: screenOrigin, size: CGSize(width: CGFloat(uniforms.viewSize.x), height: CGFloat(uniforms.viewSize.y)))
        let (windows, sampled) = tracker.snapshot()
        let ahead = min(now - sampled, 0.1) + lead      // extrapolate from sample time to on-screen time
        for w in windows {
            let f = w.frame.offsetBy(dx: w.velocity.dx * ahead, dy: w.velocity.dy * ahead)
            guard f.intersects(screen) else { continue }
            rects.append([Float(f.minX - screenOrigin.x), Float(f.minY - screenOrigin.y), Float(f.width), Float(f.height)])
        }
        guard !rects.isEmpty else { return }
        enc.setRenderPipelineState(pipeline)
        // setVertexBytes is capped at 4 KB = 256 rects; plenty for a debug view.
        rects.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: min($0.count, 4096), index: 0) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: min(rects.count, 256))
    }
}
