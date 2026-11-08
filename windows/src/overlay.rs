//! One transparent, click-through, always-on-top window per monitor, drawn through
//! DirectComposition (the efficient way Windows composes transparent GPU content).

use std::sync::Once;
use windows::core::{w, Interface, Result};
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::DirectComposition::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::gpu::{depth_view, Gpu, Scene, ScreenRenderer};

static REGISTER: Once = Once::new();

unsafe extern "system" fn overlay_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        // Belt and braces with WS_EX_TRANSPARENT: the overlay never takes a click.
        WM_NCHITTEST => LRESULT(HTTRANSPARENT as isize),
        WM_MOUSEACTIVATE => LRESULT(MA_NOACTIVATE as isize),
        _ => unsafe { DefWindowProcW(hwnd, msg, wp, lp) },
    }
}

pub struct Overlay {
    pub hwnd: HWND,
    swap: IDXGISwapChain1,
    rtv: ID3D11RenderTargetView,
    dsv: ID3D11DepthStencilView,
    _dcomp: IDCompositionDevice,
    _target: IDCompositionTarget,
    _visual: IDCompositionVisual,
    pub px: [u32; 2],
    pub renderer: ScreenRenderer,
}

impl Overlay {
    /// `rect` in physical pixels; `scale` = this monitor's DPI / 96 (the scene is in DIPs).
    pub fn new(gpu: &Gpu, rect: RECT, scale: f32, density: f32, wind: f32, seed: u64, hide_from_capture: bool) -> Result<Overlay> {
        let hinstance: HINSTANCE = unsafe { GetModuleHandleW(None)? }.into();
        REGISTER.call_once(|| unsafe {
            let class = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32, lpfnWndProc: Some(overlay_proc),
                hInstance: hinstance, lpszClassName: w!("SnowdriftOverlay"), ..Default::default()
            };
            RegisterClassExW(&class);
        });
        let (w, h) = ((rect.right - rect.left) as u32, (rect.bottom - rect.top) as u32);
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_NOACTIVATE,
                w!("SnowdriftOverlay"), w!("Snowdrift"), WS_POPUP,
                rect.left, rect.top, w as i32, h as i32, None, None, hinstance, None)?
        };
        unsafe {
            SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA)?;
        }

        // Swap chain for composition: premultiplied alpha, flip model.
        let dxgi_device: IDXGIDevice = gpu.device.cast()?;
        let factory: IDXGIFactory2 = unsafe { dxgi_device.GetAdapter()?.GetParent()? };
        let desc = DXGI_SWAP_CHAIN_DESC1 {
            Width: w, Height: h, Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 }, BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: 2, Scaling: DXGI_SCALING_STRETCH, SwapEffect: DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
            AlphaMode: DXGI_ALPHA_MODE_PREMULTIPLIED, ..Default::default()
        };
        let swap = unsafe { factory.CreateSwapChainForComposition(&gpu.device, &desc, None)? };
        let back: ID3D11Texture2D = unsafe { swap.GetBuffer(0)? };
        let mut rtv = None;
        unsafe { gpu.device.CreateRenderTargetView(&back, None, Some(&mut rtv))? };
        let dsv = depth_view(gpu, w, h)?;

        let dcomp: IDCompositionDevice = unsafe { DCompositionCreateDevice(&dxgi_device)? };
        let target = unsafe { dcomp.CreateTargetForHwnd(hwnd, true)? };
        let visual = unsafe { dcomp.CreateVisual()? };
        unsafe {
            visual.SetContent(&swap)?;
            target.SetRoot(&visual)?;
            dcomp.Commit()?;
            // Not ShowWindow: a process's first ShowWindow obeys the launcher's show mode (hidden over
            // SSH, minimized from a "Run: Minimized" shortcut). SWP_SHOWWINDOW doesn't.
            let _ = SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
        }
        let size = [w as f32 / scale, h as f32 / scale];
        let renderer = ScreenRenderer::new(gpu, size, density, wind, seed)?;
        let o = Overlay { hwnd, swap, rtv: rtv.unwrap(), dsv, _dcomp: dcomp, _target: target, _visual: visual, px: [w, h], renderer };
        o.set_hidden_from_capture(hide_from_capture);
        Ok(o)
    }

    pub fn present(&self, gpu: &mut Gpu, time: f32, dt: f32, scene: &Scene) -> Result<()> {
        self.renderer.draw(gpu, &self.rtv, &self.dsv, self.px, time, dt, scene)?;
        unsafe { self.swap.Present(0, DXGI_PRESENT(0)).ok() }
    }

    /// Screen sharing, recording and screenshots skip the snow.
    pub fn set_hidden_from_capture(&self, on: bool) {
        unsafe { let _ = SetWindowDisplayAffinity(self.hwnd, if on { WDA_EXCLUDEFROMCAPTURE } else { WDA_NONE }); }
    }

    pub fn set_visible(&self, on: bool) {
        unsafe { let _ = ShowWindow(self.hwnd, if on { SW_SHOWNOACTIVATE } else { SW_HIDE }); }
    }
}

impl Drop for Overlay {
    fn drop(&mut self) {
        unsafe { let _ = DestroyWindow(self.hwnd); }
    }
}
