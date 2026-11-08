// Falling flakes are *stateless GPU particles*: each flake's position is a closed-form
// function of time computed in the vertex shader (snow falls at terminal velocity, so
// position = start + speed * t is exact). The CPU never loops over flakes.
//
// Per frame, per screen: windows go into the depth buffer only (no color), so snow piles on a
// window behind another one are hidden for free; then piles, falling flakes, and clumps.
// The depth buffer is memoryless on Apple GPUs: it lives in tile memory and costs no RAM.

import AppKit
import MetalKit


private struct Flake { var y0, size, alpha, soft, fall, swayAmp, swayFreq, phase, lands: Float }   // matches MSL
private struct Uniforms { var viewSize: SIMD2<Float>; var time: Float; var wind: Float; var dt: Float }   // 24 B, matches MSL
private struct Occ { var r: SIMD4<Float>; var depth: Float; var p0: Float = 0, p1: Float = 0, p2: Float = 0 }   // 32 B, matches MSL
private struct PileParams { var origin: SIMD2<Float>; var colW, depth, radius, startX, width: Float; var count: UInt32 }   // 32 B

enum GPUError: Error { case unavailable(String) }

/// Everything on the GPU that every screen shares: the compiled shaders, pipelines and depth
/// states. Built once (compiling the shaders takes ~100 ms), not once per display.
@MainActor
final class GPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let flakePipeline, clumpPipeline, occPipeline, pilePipeline: MTLRenderPipelineState
    let rectPipeline: MTLRenderPipelineState?
    let depthWrite, depthTestOnly, depthOff: MTLDepthStencilState
    static let depthFormat = MTLPixelFormat.depth32Float

    init(device: MTLDevice, debug: Bool) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw GPUError.unavailable("command queue") }
        self.queue = queue
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        func pipeline(_ v: String, _ f: String, color: Bool = true) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: v)
            desc.fragmentFunction = lib.makeFunction(name: f)
            desc.depthAttachmentPixelFormat = Self.depthFormat
            guard let ca = desc.colorAttachments[0] else { throw GPUError.unavailable("color attachment") }
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
        func depth(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare; d.isDepthWriteEnabled = write
            guard let state = device.makeDepthStencilState(descriptor: d) else { throw GPUError.unavailable("depth state") }
            return state
        }
        depthWrite = try depth(.less, write: true)
        depthTestOnly = try depth(.less, write: false)
        depthOff = try depth(.always, write: false)
    }
}

/// Draws one screen: window occluders (depth only), piles, falling flakes, lumps.
@MainActor
final class SnowRenderer: NSObject, MTKViewDelegate {
    private let gpu: GPU
    private var flakes: MTLBuffer
    private var landed: MTLBuffer               // 4 bytes per flake, written by the flake vertex shader
    private var count: Int
    private var uniforms: Uniforms
    private let start = CACurrentMediaTime()
    private var lastDraw = CACurrentMediaTime()
    private let snowpack: Snowpack
    private let screenIndex: Int
    private let tracker: WindowTracker          // only for --debug outlines
    /// Landing flakes per second reaching the ground line on this screen (feeds pile growth).
    private(set) var landingRate: Float

    /// Horizontal wind (pt/s). Changing it shifts flakes sideways once (positions are closed-form).
    var wind: Float {
        get { uniforms.wind }
        set { uniforms.wind = newValue }
    }

    // Scratch arrays reused every frame (no per-frame allocation).
    private var occ: [Occ] = []
    private var clumpData: [SIMD4<Float>] = []
    private var rects: [SIMD4<Float>] = []

    init(gpu: GPU, size: CGSize, screenIndex: Int, snowpack: Snowpack, tracker: WindowTracker,
         density: Float, wind: Float) throws {
        self.gpu = gpu
        (flakes, landed, count, landingRate) = try Self.makeFlakes(device: gpu.device, size: size, density: density)
        uniforms = Uniforms(viewSize: [Float(size.width), Float(size.height)], time: 0, wind: wind, dt: 1.0 / 60)
        self.snowpack = snowpack
        self.screenIndex = screenIndex
        self.tracker = tracker
        super.init()
    }

    /// Flakes: one per 4500 pt² of screen at density 1. Written once to GPU memory, never touched again.
    private static func makeFlakes(device: MTLDevice, size: CGSize, density: Float) throws
        -> (MTLBuffer, MTLBuffer, Int, Float) {
        let count = max(1, Int(Float(size.width * size.height) / 4500 * density))
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
        let rate = data.reduce(0) { $0 + $1.lands * $1.fall / (h + 20) }
        guard let flakes = device.makeBuffer(bytes: data, length: MemoryLayout<Flake>.stride * count, options: .storageModeShared),
              let landed = device.makeBuffer(length: 4 * count, options: .storageModeShared)
        else { throw GPUError.unavailable("flake buffers") }
        memset(landed.contents(), 0, 4 * count)
        return (flakes, landed, count, rate)
    }

    /// Change how much snow falls (rebuilds the flake buffer; returns the new landing rate).
    func setDensity(_ density: Float) -> Float {
        let size = CGSize(width: CGFloat(uniforms.viewSize.x), height: CGFloat(uniforms.viewSize.y))
        if let made = try? Self.makeFlakes(device: gpu.device, size: size, density: density) {
            (flakes, landed, count, landingRate) = made
        }
        return landingRate
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange newSize: CGSize) {
        uniforms.viewSize = [Float(view.bounds.width), Float(view.bounds.height)]
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        snowpack.frame(now: now)
        guard screenIndex < snowpack.screens.count else { return }        // displays just changed

        // ponytail: time wraps every hour so Float keeps sub-ms precision; all flakes jump once
        // per hour (invisible in falling snow). Pass a Double split if that ever shows.
        uniforms.time = Float((now - start).truncatingRemainder(dividingBy: 3600))
        uniforms.dt = Float(min(now - lastDraw, 0.1))
        lastDraw = now
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = gpu.queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
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
            enc.setRenderPipelineState(gpu.occPipeline)
            enc.setDepthStencilState(gpu.depthWrite)
            for chunk in stride(from: 0, to: occ.count, by: 128) {
                let n = min(128, occ.count - chunk)
                occ.withUnsafeBytes { enc.setVertexBytes($0.baseAddress! + chunk * MemoryLayout<Occ>.stride, length: n * MemoryLayout<Occ>.stride, index: 0) }
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
            }
        }

        // 2. Piles, hidden where a nearer window covers them.
        enc.setRenderPipelineState(gpu.pilePipeline)
        enc.setDepthStencilState(gpu.depthTestOnly)
        for s in snowpack.surfaces {
            guard s.x < screen.maxX, s.x + s.width > screen.minX, let p = snowpack.piles[s.key] else { continue }
            if case .ground(let g) = s.key, g != screenIndex { continue }
            let n = p.h.count
            // setVertexBytes is capped at 4 KB = 1024 floats: draw long piles in chunks sharing one column.
            var start = 0
            while start < n - 1 || (n == 1 && start == 0) {
                let end = min(start + 1024, n)
                var params = PileParams(origin: [Float(s.x) - ox + Float(start) * Physics.colW, Float(s.y) - oy - p.lift],
                                        colW: Physics.colW, depth: s.depth - 0.001, radius: s.radius,
                                        startX: Float(start) * Physics.colW, width: Float(s.width), count: UInt32(end - start))
                p.h.withUnsafeBytes { enc.setVertexBytes($0.baseAddress! + start * 4, length: (end - start) * 4, index: 0) }
                enc.setVertexBytes(&params, length: MemoryLayout<PileParams>.stride, index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: max(1, end - start - 1))
                if end == n { break }
                start = end - 1
            }
        }

        // 3. Falling flakes, in front of everything.
        enc.setDepthStencilState(gpu.depthOff)
        enc.setRenderPipelineState(gpu.flakePipeline)
        enc.setVertexBuffer(flakes, offset: 0, index: 0)
        snowpack.maps[screenIndex].withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
        enc.setVertexBuffer(landed, offset: 0, index: 3)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)

        // 4. Clumps.
        clumpData.removeAll(keepingCapacity: true)
        for c in snowpack.clumps where Float(screen.minX) <= c.x && c.x < Float(screen.maxX) {
            let fade = c.alpha
            clumpData.append([c.x - ox, c.y - oy, c.size * (0.6 + 0.4 * fade), 0.95 * fade])   // thin out as they fall
        }
        if !clumpData.isEmpty {
            enc.setRenderPipelineState(gpu.clumpPipeline)
            for chunk in stride(from: 0, to: clumpData.count, by: 256) {                     // 4 KB = 256 × 16 B
                let n = min(256, clumpData.count - chunk)
                clumpData.withUnsafeBytes { enc.setVertexBytes($0.baseAddress! + chunk * 16, length: n * 16, index: 0) }
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
            }
        }

        if let rect = gpu.rectPipeline { drawOutlines(enc, rect, screen: screen) }
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
