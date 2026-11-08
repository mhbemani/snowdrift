//! Direct3D 11: one device and the compiled shaders/states shared by every screen, plus a
//! per-screen renderer holding that screen's flakes. Mirrors the macOS `GPU` + `SnowRenderer`.

use std::ffi::c_void;
use windows::core::{Result, PCSTR, s};
use windows::Win32::Foundation::HMODULE;
use windows::Win32::Graphics::Direct3D::Fxc::{D3DCompile, D3DCOMPILE_OPTIMIZATION_LEVEL3};
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;

use crate::shaders::HLSL;

/// One flake, written once (matches the HLSL `Flake`).
#[repr(C)]
#[derive(Clone, Copy)]
struct Flake { y0: f32, size: f32, alpha: f32, soft: f32, fall: f32, sway_amp: f32, sway_freq: f32, phase: f32, lands: f32 }

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Uniforms { view: [f32; 2], time: f32, wind: f32, dt: f32, pad: [f32; 3] }

/// An occluder: rect (x, y, w, h) and depth. 32 bytes, matches HLSL `Occ`.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Occ { pub r: [f32; 4], pub depth: f32, pub pad: [f32; 3] }

/// One pile draw (matches the HLSL `Pile` cbuffer).
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct PileDraw {
    pub origin: [f32; 2], pub col_w: f32, pub depth: f32, pub radius: f32, pub start_x: f32, pub width: f32,
    pub count: u32, pub offset: u32, pub pad: [f32; 3],
}

/// What one screen draws this frame, in that screen's local DIPs.
#[derive(Default)]
pub struct Scene {
    pub occluders: Vec<Occ>,
    pub piles: Vec<PileDraw>,
    pub heights: Vec<f32>,
    pub clumps: Vec<[f32; 4]>,
    pub maps: Vec<f32>,                 // 1024: landing map then ground map
}

/// A CPU-written structured buffer that grows as needed.
struct DynBuf { buf: Option<ID3D11Buffer>, srv: Option<ID3D11ShaderResourceView>, cap: usize, stride: usize }

impl DynBuf {
    fn new(stride: usize) -> Self { DynBuf { buf: None, srv: None, cap: 0, stride } }

    fn upload<T: Copy>(&mut self, dev: &ID3D11Device, ctx: &ID3D11DeviceContext, data: &[T]) -> Result<()> {
        if data.is_empty() { return Ok(()); }
        if data.len() > self.cap {
            let cap = data.len().next_power_of_two().max(64);
            let desc = D3D11_BUFFER_DESC {
                ByteWidth: (cap * self.stride) as u32, Usage: D3D11_USAGE_DYNAMIC,
                BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32, CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
                MiscFlags: D3D11_RESOURCE_MISC_BUFFER_STRUCTURED.0 as u32, StructureByteStride: self.stride as u32,
            };
            let mut buf = None;
            unsafe { dev.CreateBuffer(&desc, None, Some(&mut buf))? };
            let buf = buf.unwrap();
            let mut srv = None;
            unsafe { dev.CreateShaderResourceView(&buf, None, Some(&mut srv))? };
            self.buf = Some(buf); self.srv = srv; self.cap = cap;
        }
        let buf = self.buf.as_ref().unwrap();
        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
        unsafe {
            ctx.Map(buf, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped))?;
            std::ptr::copy_nonoverlapping(data.as_ptr() as *const u8, mapped.pData as *mut u8, std::mem::size_of_val(data));
            ctx.Unmap(buf, 0);
        }
        Ok(())
    }
}

/// Shared by every screen: device, shaders, states, constant buffers.
pub struct Gpu {
    pub device: ID3D11Device,
    pub ctx: ID3D11DeviceContext,
    pub software: bool,
    flake_vs: ID3D11VertexShader, flake_ps: ID3D11PixelShader,
    clump_vs: ID3D11VertexShader,
    occ_vs: ID3D11VertexShader, occ_ps: ID3D11PixelShader,
    pile_vs: ID3D11VertexShader, pile_ps: ID3D11PixelShader,
    blend: ID3D11BlendState, blend_no_color: ID3D11BlendState,
    depth_write: ID3D11DepthStencilState, depth_test: ID3D11DepthStencilState, depth_off: ID3D11DepthStencilState,
    raster: ID3D11RasterizerState,
    cb_uniforms: ID3D11Buffer, cb_maps: ID3D11Buffer, cb_pile: ID3D11Buffer,
    heights: DynBuf, occs: DynBuf, clumps: DynBuf,
}

fn compile(entry: PCSTR, target: PCSTR) -> Result<Vec<u8>> {
    let mut code = None;
    let mut errors = None;
    let r = unsafe {
        D3DCompile(HLSL.as_ptr() as *const c_void, HLSL.len(), s!("snowdrift"), None, None, entry, target,
                   D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &mut code, Some(&mut errors))
    };
    if let Err(e) = r {
        if let Some(err) = errors {
            let msg = unsafe { std::slice::from_raw_parts(err.GetBufferPointer() as *const u8, err.GetBufferSize()) };
            eprintln!("shader compile error:\n{}", String::from_utf8_lossy(msg));
        }
        return Err(e);
    }
    let code: ID3DBlob = code.unwrap();
    Ok(unsafe { std::slice::from_raw_parts(code.GetBufferPointer() as *const u8, code.GetBufferSize()) }.to_vec())
}

fn dynamic_cbuffer(dev: &ID3D11Device, size: usize) -> Result<ID3D11Buffer> {
    let desc = D3D11_BUFFER_DESC {
        ByteWidth: size as u32, Usage: D3D11_USAGE_DYNAMIC, BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
        CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32, ..Default::default()
    };
    let mut b = None;
    unsafe { dev.CreateBuffer(&desc, None, Some(&mut b))? };
    Ok(b.unwrap())
}

fn write_cbuffer<T: Copy>(ctx: &ID3D11DeviceContext, buf: &ID3D11Buffer, data: &[T]) -> Result<()> {
    let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
    unsafe {
        ctx.Map(buf, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped))?;
        std::ptr::copy_nonoverlapping(data.as_ptr() as *const u8, mapped.pData as *mut u8, std::mem::size_of_val(data));
        ctx.Unmap(buf, 0);
    }
    Ok(())
}

impl Gpu {
    /// The graphics card first; Windows' software renderer (WARP) if that isn't available
    /// (e.g. a session with no display, where the off-screen test runs).
    pub fn new() -> Result<Gpu> {
        let levels = [D3D_FEATURE_LEVEL_11_1];
        let flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        let mut device = None;
        let mut ctx = None;
        let mut software = false;
        let hw = unsafe {
            D3D11CreateDevice(None, D3D_DRIVER_TYPE_HARDWARE, HMODULE::default(), flags, Some(&levels),
                              D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut ctx))
        };
        if hw.is_err() {
            software = true;
            unsafe {
                D3D11CreateDevice(None, D3D_DRIVER_TYPE_WARP, HMODULE::default(), flags, Some(&levels),
                                  D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut ctx))?
            };
        }
        let device: ID3D11Device = device.unwrap();
        let ctx: ID3D11DeviceContext = ctx.unwrap();

        let vs = |e: PCSTR| -> Result<ID3D11VertexShader> {
            let code = compile(e, s!("vs_5_0"))?;
            let mut v = None;
            unsafe { device.CreateVertexShader(&code, None, Some(&mut v))? };
            Ok(v.unwrap())
        };
        let ps = |e: PCSTR| -> Result<ID3D11PixelShader> {
            let code = compile(e, s!("ps_5_0"))?;
            let mut p = None;
            unsafe { device.CreatePixelShader(&code, None, Some(&mut p))? };
            Ok(p.unwrap())
        };
        let flake_vs = vs(s!("flakeVS"))?;
        let flake_ps = ps(s!("flakePS"))?;
        let clump_vs = vs(s!("clumpVS"))?;
        let occ_vs = vs(s!("occVS"))?;
        let occ_ps = ps(s!("occPS"))?;
        let pile_vs = vs(s!("pileVS"))?;
        let pile_ps = ps(s!("pilePS"))?;

        let blend_desc = |color: bool| {
            let mut d = D3D11_BLEND_DESC::default();
            d.RenderTarget[0] = D3D11_RENDER_TARGET_BLEND_DESC {
                BlendEnable: true.into(),
                SrcBlend: D3D11_BLEND_ONE, DestBlend: D3D11_BLEND_INV_SRC_ALPHA, BlendOp: D3D11_BLEND_OP_ADD,
                SrcBlendAlpha: D3D11_BLEND_ONE, DestBlendAlpha: D3D11_BLEND_INV_SRC_ALPHA, BlendOpAlpha: D3D11_BLEND_OP_ADD,
                RenderTargetWriteMask: if color { D3D11_COLOR_WRITE_ENABLE_ALL.0 as u8 } else { 0 },
            };
            d
        };
        let mut blend = None;
        let mut blend_no_color = None;
        unsafe {
            device.CreateBlendState(&blend_desc(true), Some(&mut blend))?;
            device.CreateBlendState(&blend_desc(false), Some(&mut blend_no_color))?;
        }
        let depth = |func: D3D11_COMPARISON_FUNC, write: bool, enable: bool| -> Result<ID3D11DepthStencilState> {
            let d = D3D11_DEPTH_STENCIL_DESC {
                DepthEnable: enable.into(),
                DepthWriteMask: if write { D3D11_DEPTH_WRITE_MASK_ALL } else { D3D11_DEPTH_WRITE_MASK_ZERO },
                DepthFunc: func, ..Default::default()
            };
            let mut s = None;
            unsafe { device.CreateDepthStencilState(&d, Some(&mut s))? };
            Ok(s.unwrap())
        };
        let depth_write = depth(D3D11_COMPARISON_LESS, true, true)?;
        let depth_test = depth(D3D11_COMPARISON_LESS, false, true)?;
        let depth_off = depth(D3D11_COMPARISON_ALWAYS, false, false)?;
        let rdesc = D3D11_RASTERIZER_DESC { FillMode: D3D11_FILL_SOLID, CullMode: D3D11_CULL_NONE, DepthClipEnable: true.into(), ..Default::default() };
        let mut raster = None;
        unsafe { device.CreateRasterizerState(&rdesc, Some(&mut raster))? };

        Ok(Gpu {
            cb_uniforms: dynamic_cbuffer(&device, std::mem::size_of::<Uniforms>())?,
            cb_maps: dynamic_cbuffer(&device, 4096)?,
            cb_pile: dynamic_cbuffer(&device, std::mem::size_of::<PileDraw>())?,
            device, ctx, software, flake_vs, flake_ps, clump_vs, occ_vs, occ_ps, pile_vs, pile_ps,
            blend: blend.unwrap(), blend_no_color: blend_no_color.unwrap(),
            depth_write, depth_test, depth_off, raster: raster.unwrap(),
            heights: DynBuf::new(4), occs: DynBuf::new(32), clumps: DynBuf::new(16),
        })
    }
}

/// Small deterministic random generator (no dependency).
pub struct Rng(u64);
impl Rng {
    pub fn new(seed: u64) -> Rng { Rng(seed | 1) }
    pub fn next(&mut self) -> f32 {
        self.0 ^= self.0 << 13; self.0 ^= self.0 >> 7; self.0 ^= self.0 << 17;
        (self.0 >> 40) as f32 / (1u64 << 24) as f32
    }
    pub fn range(&mut self, lo: f32, hi: f32) -> f32 { lo + (hi - lo) * self.next() }
}

/// Draws one screen. Flakes are stateless GPU particles: written once, never touched by the CPU.
pub struct ScreenRenderer {
    flakes_srv: ID3D11ShaderResourceView,
    landed_uav: ID3D11UnorderedAccessView,
    count: u32,
    pub size: [f32; 2],                 // DIPs
    pub landing_rate: f32,
    pub wind: f32,
}

impl ScreenRenderer {
    pub fn new(gpu: &Gpu, size: [f32; 2], density: f32, wind: f32, seed: u64) -> Result<ScreenRenderer> {
        let count = ((size[0] * size[1]) / 4500.0 * density).max(1.0) as usize;
        let mut rng = Rng::new(seed);
        let h = size[1];
        let data: Vec<Flake> = (0..count).map(|_| {
            let depth = rng.next().powi(3);                     // mostly small/far, few big/near
            Flake {
                y0: rng.range(0.0, h), size: 2.0 + 7.0 * depth,
                alpha: if depth > 0.6 { 0.35 } else { rng.range(0.5, 0.9) },
                soft: if depth > 0.6 { 0.9 } else { 0.45 },
                fall: 30.0 + 70.0 * depth + rng.range(0.0, 15.0),
                sway_amp: rng.range(4.0, 14.0), sway_freq: rng.range(1.3, 2.4), phase: rng.range(0.0, 6.283),
                lands: if depth < 0.6 && rng.next() < 0.7 { 1.0 } else { 0.0 },
            }
        }).collect();
        let landing_rate = data.iter().map(|f| f.lands * f.fall / (h + 20.0)).sum();

        let dev = &gpu.device;
        let make = |stride: usize, n: usize, init: *const c_void, uav: bool| -> Result<ID3D11Buffer> {
            let desc = D3D11_BUFFER_DESC {
                ByteWidth: (stride * n) as u32, Usage: D3D11_USAGE_DEFAULT,
                BindFlags: (D3D11_BIND_SHADER_RESOURCE.0 | if uav { D3D11_BIND_UNORDERED_ACCESS.0 } else { 0 }) as u32,
                MiscFlags: D3D11_RESOURCE_MISC_BUFFER_STRUCTURED.0 as u32, StructureByteStride: stride as u32,
                ..Default::default()
            };
            let sub = D3D11_SUBRESOURCE_DATA { pSysMem: init, ..Default::default() };
            let mut b = None;
            unsafe { dev.CreateBuffer(&desc, Some(&sub), Some(&mut b))? };
            Ok(b.unwrap())
        };
        let flakes = make(std::mem::size_of::<Flake>(), count, data.as_ptr() as *const c_void, false)?;
        let zeros = vec![0u32; count];
        let landed = make(4, count, zeros.as_ptr() as *const c_void, true)?;
        let mut srv = None;
        let mut uav = None;
        unsafe {
            dev.CreateShaderResourceView(&flakes, None, Some(&mut srv))?;
            dev.CreateUnorderedAccessView(&landed, None, Some(&mut uav))?;
        }
        Ok(ScreenRenderer { flakes_srv: srv.unwrap(), landed_uav: uav.unwrap(), count: count as u32, size, landing_rate, wind })
    }

    /// Draws a frame into `rtv`/`dsv` (pixel size `px`): occluders (depth only), piles, flakes, lumps.
    pub fn draw(&self, gpu: &mut Gpu, rtv: &ID3D11RenderTargetView, dsv: &ID3D11DepthStencilView,
                px: [u32; 2], time: f32, dt: f32, scene: &Scene) -> Result<()> {
        let ctx = gpu.ctx.clone();
        let u = Uniforms { view: self.size, time, wind: self.wind, dt, pad: [0.0; 3] };
        write_cbuffer(&ctx, &gpu.cb_uniforms, &[u])?;
        let mut maps = [0f32; 1024];
        if scene.maps.len() == 1024 { maps.copy_from_slice(&scene.maps) } else { maps.fill(self.size[1]) }
        write_cbuffer(&ctx, &gpu.cb_maps, &maps)?;
        gpu.occs.upload(&gpu.device, &ctx, &scene.occluders)?;
        gpu.heights.upload(&gpu.device, &ctx, &scene.heights)?;
        gpu.clumps.upload(&gpu.device, &ctx, &scene.clumps)?;

        unsafe {
            ctx.ClearRenderTargetView(rtv, &[0.0, 0.0, 0.0, 0.0]);
            ctx.ClearDepthStencilView(dsv, D3D11_CLEAR_DEPTH.0 as u32, 1.0, 0);
            let vp = D3D11_VIEWPORT { Width: px[0] as f32, Height: px[1] as f32, MaxDepth: 1.0, ..Default::default() };
            ctx.RSSetViewports(Some(&[vp]));
            ctx.RSSetState(&gpu.raster);
            ctx.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
            ctx.IASetInputLayout(None);
            let cbs = [Some(gpu.cb_uniforms.clone()), Some(gpu.cb_maps.clone()), Some(gpu.cb_pile.clone())];
            ctx.VSSetConstantBuffers(0, Some(&cbs));
            // RTV + the flakes' landing UAV (slot 1: UAV slots start after the render targets).
            let rtvs = [Some(rtv.clone())];
            let uavs = [Some(self.landed_uav.clone())];
            ctx.OMSetRenderTargetsAndUnorderedAccessViews(Some(&rtvs), dsv, 1, 1, Some(uavs.as_ptr()), None);

            // 1. Occluders: depth only.
            if !scene.occluders.is_empty() {
                ctx.OMSetBlendState(&gpu.blend_no_color, None, 0xffffffff);
                ctx.OMSetDepthStencilState(&gpu.depth_write, 0);
                ctx.VSSetShader(&gpu.occ_vs, None);
                ctx.PSSetShader(&gpu.occ_ps, None);
                ctx.VSSetShaderResources(2, Some(&[gpu.occs.srv.clone()]));
                ctx.DrawInstanced(4, scene.occluders.len() as u32, 0, 0);
            }
            // 2. Piles, hidden where a nearer window covers them.
            ctx.OMSetBlendState(&gpu.blend, None, 0xffffffff);
            if !scene.piles.is_empty() {
                ctx.OMSetDepthStencilState(&gpu.depth_test, 0);
                ctx.VSSetShader(&gpu.pile_vs, None);
                ctx.PSSetShader(&gpu.pile_ps, None);
                ctx.VSSetShaderResources(1, Some(&[gpu.heights.srv.clone()]));
                for p in &scene.piles {
                    write_cbuffer(&ctx, &gpu.cb_pile, &[*p])?;
                    ctx.DrawInstanced(4, p.count.saturating_sub(1).max(1), 0, 0);
                }
            }
            // 3. Falling flakes, in front of everything.
            ctx.OMSetDepthStencilState(&gpu.depth_off, 0);
            ctx.VSSetShader(&gpu.flake_vs, None);
            ctx.PSSetShader(&gpu.flake_ps, None);
            ctx.VSSetShaderResources(0, Some(&[Some(self.flakes_srv.clone())]));
            ctx.DrawInstanced(4, self.count, 0, 0);
            // 4. Lumps.
            if !scene.clumps.is_empty() {
                ctx.VSSetShader(&gpu.clump_vs, None);
                ctx.VSSetShaderResources(3, Some(&[gpu.clumps.srv.clone()]));
                ctx.DrawInstanced(4, scene.clumps.len() as u32, 0, 0);
            }
        }
        Ok(())
    }
}

/// An off-screen target (for `--render-test`): BGRA color + depth, readable from the CPU.
pub struct Offscreen { tex: ID3D11Texture2D, staging: ID3D11Texture2D, pub rtv: ID3D11RenderTargetView, pub dsv: ID3D11DepthStencilView, pub px: [u32; 2] }

impl Offscreen {
    pub fn new(gpu: &Gpu, w: u32, h: u32) -> Result<Offscreen> {
        let mut desc = D3D11_TEXTURE2D_DESC {
            Width: w, Height: h, MipLevels: 1, ArraySize: 1, Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 }, Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32, ..Default::default()
        };
        let mut tex = None;
        unsafe { gpu.device.CreateTexture2D(&desc, None, Some(&mut tex))? };
        let tex: ID3D11Texture2D = tex.unwrap();
        desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
        let mut staging = None;
        unsafe { gpu.device.CreateTexture2D(&desc, None, Some(&mut staging))? };
        let mut rtv = None;
        unsafe { gpu.device.CreateRenderTargetView(&tex, None, Some(&mut rtv))? };
        let dsv = depth_view(gpu, w, h)?;
        Ok(Offscreen { tex, staging: staging.unwrap(), rtv: rtv.unwrap(), dsv, px: [w, h] })
    }

    /// Writes the current image as a 32-bit BMP (premultiplied alpha composited over `bg`).
    pub fn save_bmp(&self, gpu: &Gpu, path: &str, bg: [u8; 3]) -> Result<()> {
        let (w, h) = (self.px[0] as usize, self.px[1] as usize);
        let mut pixels = vec![0u8; w * h * 4];
        unsafe {
            gpu.ctx.CopyResource(&self.staging, &self.tex);
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            gpu.ctx.Map(&self.staging, 0, D3D11_MAP_READ, 0, Some(&mut m))?;
            for y in 0..h {
                let row = std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), w * 4);
                for x in 0..w {
                    let (b, g, r, a) = (row[x * 4] as u32, row[x * 4 + 1] as u32, row[x * 4 + 2] as u32, row[x * 4 + 3] as u32);
                    let o = (y * w + x) * 4;
                    pixels[o] = (b + bg[2] as u32 * (255 - a) / 255).min(255) as u8;
                    pixels[o + 1] = (g + bg[1] as u32 * (255 - a) / 255).min(255) as u8;
                    pixels[o + 2] = (r + bg[0] as u32 * (255 - a) / 255).min(255) as u8;
                    pixels[o + 3] = 255;
                }
            }
            gpu.ctx.Unmap(&self.staging, 0);
        }
        let mut file = Vec::with_capacity(54 + pixels.len());
        let size = (54 + pixels.len()) as u32;
        file.extend_from_slice(b"BM"); file.extend_from_slice(&size.to_le_bytes()); file.extend_from_slice(&[0; 4]);
        file.extend_from_slice(&54u32.to_le_bytes()); file.extend_from_slice(&40u32.to_le_bytes());
        file.extend_from_slice(&(w as i32).to_le_bytes()); file.extend_from_slice(&(-(h as i32)).to_le_bytes());
        file.extend_from_slice(&1u16.to_le_bytes()); file.extend_from_slice(&32u16.to_le_bytes());
        file.extend_from_slice(&[0; 24]);
        file.extend_from_slice(&pixels);
        std::fs::write(path, file).map_err(|e| windows::core::Error::new(windows::Win32::Foundation::E_FAIL, e.to_string()))
    }
}

/// A depth buffer for one target.
pub fn depth_view(gpu: &Gpu, w: u32, h: u32) -> Result<ID3D11DepthStencilView> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: w, Height: h, MipLevels: 1, ArraySize: 1, Format: DXGI_FORMAT_D32_FLOAT,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 }, Usage: D3D11_USAGE_DEFAULT,
        BindFlags: D3D11_BIND_DEPTH_STENCIL.0 as u32, ..Default::default()
    };
    let mut tex = None;
    unsafe { gpu.device.CreateTexture2D(&desc, None, Some(&mut tex))? };
    let tex: ID3D11Texture2D = tex.unwrap();
    let mut dsv = None;
    unsafe { gpu.device.CreateDepthStencilView(&tex, None, Some(&mut dsv))? };
    Ok(dsv.unwrap())
}

