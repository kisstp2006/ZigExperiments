//! Minimal Win32 + WGL window/context layer for the Basic2D engine.
//! No external dependencies: the Win32 API is declared directly.

const std = @import("std");

pub const HINSTANCE = *anyopaque;
pub const HWND = *anyopaque;
pub const HDC = *anyopaque;
pub const HGLRC = *anyopaque;
pub const HICON = *anyopaque;
pub const HCURSOR = *anyopaque;
pub const HBRUSH = *anyopaque;

const WINAPI: std.builtin.CallingConvention = .winapi;

pub const POINT = extern struct { x: i32, y: i32 };
pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: usize,
    lParam: isize,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

pub const WNDPROC = *const fn (?HWND, u32, usize, isize) callconv(WINAPI) isize;

pub const WNDCLASSW = extern struct {
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16,
    nVersion: u16,
    dwFlags: u32,
    iPixelType: u8,
    cColorBits: u8,
    cRedBits: u8,
    cRedShift: u8,
    cGreenBits: u8,
    cGreenShift: u8,
    cBlueBits: u8,
    cBlueShift: u8,
    cAlphaBits: u8,
    cAlphaShift: u8,
    cAccumBits: u8,
    cAccumRedBits: u8,
    cAccumGreenBits: u8,
    cAccumBlueBits: u8,
    cAccumAlphaBits: u8,
    cDepthBits: u8,
    cStencilBits: u8,
    cAuxBuffers: u8,
    iLayerType: u8,
    bReserved: u8,
    dwLayerMask: u32,
    dwVisibleMask: u32,
    dwDamageMask: u32,
};

// --- Win32 constants ---
const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const CW_USEDEFAULT: i32 = -2147483648; // 0x80000000
const SW_SHOW: i32 = 5;
const WM_CLOSE: u32 = 0x0010;
const WM_DESTROY: u32 = 0x0002;
const WM_MOUSEWHEEL: u32 = 0x020A;
const PM_REMOVE: u32 = 0x0001;
const IDC_ARROW: usize = 32512;

const PFD_DRAW_TO_WINDOW: u32 = 0x00000004;
const PFD_SUPPORT_OPENGL: u32 = 0x00000020;
const PFD_DOUBLEBUFFER: u32 = 0x00000001;
const PFD_TYPE_RGBA: u8 = 0;
const PFD_MAIN_PLANE: u8 = 0;

// WGL_ARB_create_context
const WGL_CONTEXT_MAJOR_VERSION_ARB: i32 = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB: i32 = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB: i32 = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: i32 = 0x0001;

// --- extern declarations ---
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(WINAPI) ?HINSTANCE;
extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(WINAPI) ?HINSTANCE;
extern "kernel32" fn GetProcAddress(hModule: ?*anyopaque, lpProcName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(WINAPI) i32;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(WINAPI) i32;
pub extern "kernel32" fn GetCommandLineW() callconv(WINAPI) [*:0]u16;
pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(WINAPI) ?*anyopaque;

pub extern "shell32" fn CommandLineToArgvW(lpCmdLine: [*:0]const u16, pNumArgs: *c_int) callconv(WINAPI) ?[*]?[*:0]u16;

pub extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn ReadFile(
    hFile: *anyopaque,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(WINAPI) i32;
pub extern "kernel32" fn GetFileSizeEx(hFile: *anyopaque, lpFileSize: *i64) callconv(WINAPI) i32;
pub extern "kernel32" fn WriteFile(
    hFile: *anyopaque,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(WINAPI) i32;
pub extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(WINAPI) i32;

extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) callconv(WINAPI) u16;
extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: u32,
    x: i32,
    y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?*anyopaque,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(WINAPI) ?HWND;
extern "user32" fn DefWindowProcW(hWnd: ?HWND, msg: u32, wParam: usize, lParam: isize) callconv(WINAPI) isize;
extern "user32" fn ShowWindow(hWnd: ?HWND, nCmdShow: i32) callconv(WINAPI) i32;
extern "user32" fn UpdateWindow(hWnd: ?HWND) callconv(WINAPI) i32;
extern "user32" fn GetDC(hWnd: ?HWND) callconv(WINAPI) ?HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(WINAPI) i32;
extern "user32" fn DestroyWindow(hWnd: ?HWND) callconv(WINAPI) i32;
extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) callconv(WINAPI) i32;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(WINAPI) i32;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(WINAPI) isize;
extern "user32" fn AdjustWindowRect(lpRect: *RECT, dwStyle: u32, bMenu: i32) callconv(WINAPI) i32;
pub extern "user32" fn GetClientRect(hWnd: ?HWND, lpRect: *RECT) callconv(WINAPI) i32;
pub extern "user32" fn ClientToScreen(hWnd: ?HWND, lpPoint: *POINT) callconv(WINAPI) i32;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(WINAPI) i32;
extern "user32" fn GetAsyncKeyState(vKey: i32) callconv(WINAPI) i16;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: ?*anyopaque) callconv(WINAPI) ?HCURSOR;

extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(WINAPI) i32;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: i32, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(WINAPI) i32;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(WINAPI) i32;

extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(WINAPI) ?HGLRC;
extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(WINAPI) i32;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(WINAPI) i32;
pub extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(WINAPI) ?*anyopaque;

pub fn getAsyncKeyState(vKey: i32) i16 {
    return GetAsyncKeyState(vKey);
}

/// High-resolution monotonic counter (QueryPerformanceCounter).
pub fn perfCounterNow() i64 {
    var value: i64 = 0;
    _ = QueryPerformanceCounter(&value);
    return value;
}

/// Ticks per second of perfCounterNow().
pub fn perfCounterFreq() i64 {
    var value: i64 = 0;
    _ = QueryPerformanceFrequency(&value);
    return value;
}

/// Looks up a symbol exported by opengl32.dll (for the fixed GL 1.1 set,
/// which some ICDs do not expose through wglGetProcAddress).
pub fn getProcAddressOpenGL32(name: [*:0]const u8) ?*anyopaque {
    const h = GetModuleHandleA("opengl32") orelse return null;
    return GetProcAddress(h, name);
}

pub fn getModuleHandleA(name: [*:0]const u8) ?*anyopaque {
    return GetModuleHandleA(name);
}

pub fn getProcAddress(module: *anyopaque, name: [*:0]const u8) ?*anyopaque {
    return GetProcAddress(module, name);
}

/// Returns true when the UTF-16 argument equals "--frames".
pub fn argIsFramesFlag(arg: [*:0]const u16) bool {
    const expected = [8]u16{ '-', '-', 'f', 'r', 'a', 'm', 'e', 's' };
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (arg[i] != expected[i]) return false;
    }
    return arg[expected.len] == 0;
}

/// Returns true when the UTF-16 argument equals "--screenshot".
pub fn argIsScreenshotFlag(arg: [*:0]const u16) bool {
    const expected = [12]u16{ '-', '-', 's', 'c', 'r', 'e', 'e', 'n', 's', 'h', 'o', 't' };
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (arg[i] != expected[i]) return false;
    }
    return arg[expected.len] == 0;
}

/// Returns true when the UTF-16 argument equals "--generate-api".
pub fn argIsGenerateApiFlag(arg: [*:0]const u16) bool {
    const expected = [14]u16{ '-', '-', 'g', 'e', 'n', 'e', 'r', 'a', 't', 'e', '-', 'a', 'p', 'i' };
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        if (arg[i] != expected[i]) return false;
    }
    return arg[expected.len] == 0;
}

/// Parses a UTF-16 decimal string into a u64, or null.
pub fn parseFramesValue(arg: [*:0]const u16) ?u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (arg[i] != 0) : (i += 1) {
        if (arg[i] < '0' or arg[i] > '9') return null;
        v = v * 10 + (arg[i] - '0');
    }
    if (i == 0) return null;
    return v;
}

/// Window class name must be valid UTF-16; we use a plain ASCII literal.
const class_name = [_:0]u16{ 'B', 'a', 's', 'i', 'c', '2', 'D', 'W', 'i', 'n', 'd', 'o', 'w' };

var g_should_close: bool = false;
var g_mouse_wheel: i32 = 0;

fn wndProc(hwnd: ?HWND, msg: u32, wParam: usize, lParam: isize) callconv(WINAPI) isize {
    switch (msg) {
        WM_CLOSE, WM_DESTROY => {
            g_should_close = true;
            return 0;
        },
        WM_MOUSEWHEEL => {
            const hi: u16 = @truncate(wParam >> 16);
            g_mouse_wheel += @as(i16, @bitCast(hi));
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

/// Returns and resets the accumulated mouse wheel delta (notches * 120).
pub fn takeMouseWheel() i32 {
    const v = g_mouse_wheel;
    g_mouse_wheel = 0;
    return v;
}

/// Converts UTF-8 text into a stack-buffer of UTF-16LE code units (null-terminated).
fn encodeUtf16Stack(text: []const u8, buf: []u16) ![:0]u16 {
    var out_i: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c0 = text[i];
        var cp: u21 = undefined;
        var len: usize = undefined;
        if (c0 < 0x80) {
            cp = c0;
            len = 1;
        } else if (c0 >> 5 == 0b110) {
            cp = @as(u21, c0 & 0x1F);
            len = 2;
        } else if (c0 >> 4 == 0b1110) {
            cp = @as(u21, c0 & 0x0F);
            len = 3;
        } else if (c0 >> 3 == 0b11110) {
            cp = @as(u21, c0 & 0x07);
            len = 4;
        } else return error.InvalidUtf8;
        if (i + len > text.len) return error.InvalidUtf8;
        var k: usize = 1;
        while (k < len) : (k += 1) {
            const cb = text[i + k];
            if (cb >> 6 != 0b10) return error.InvalidUtf8;
            cp = (cp << 6) | (cb & 0x3F);
        }
        if (cp < 0x10000) {
            if (out_i >= buf.len) return error.TitleTooLong;
            buf[out_i] = @intCast(cp);
            out_i += 1;
        } else {
            const v = cp - 0x10000;
            if (out_i + 1 >= buf.len) return error.TitleTooLong;
            buf[out_i] = @intCast(0xD800 + (v >> 10));
            buf[out_i + 1] = @intCast(0xDC00 + (v & 0x3FF));
            out_i += 2;
        }
        i += len;
    }
    if (out_i >= buf.len) return error.TitleTooLong;
    buf[out_i] = 0;
    return buf[0..out_i :0];
}

pub const Window = struct {
    hwnd: ?HWND = null,
    hdc: ?HDC = null,
    glrc: ?HGLRC = null,
    width: u32,
    height: u32,
    should_close: bool = false,

    /// Creates a window with an OpenGL 3.3 core context.
    pub fn create(title: []const u8, width: u32, height: u32) !Window {
        var title_buf: [256]u16 = undefined;
        const title_w = try encodeUtf16Stack(title, &title_buf);

        const hinst = GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;

        const wc = WNDCLASSW{
            .style = 0,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinst,
            .hIcon = null,
            .hCursor = LoadCursorW(null, @ptrFromInt(IDC_ARROW)),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = &class_name,
        };
        if (RegisterClassW(&wc) == 0) return error.RegisterClassFailed;

        var rect = RECT{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) };
        _ = AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, 0);
        const win_w = rect.right - rect.left;
        const win_h = rect.bottom - rect.top;

        const hwnd = CreateWindowExW(
            0,
            &class_name,
            title_w,
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            win_w,
            win_h,
            null,
            null,
            hinst,
            null,
        ) orelse return error.CreateWindowFailed;

        var window = Window{ .width = width, .height = height, .hwnd = hwnd };
        errdefer window.deinit();

        _ = ShowWindow(hwnd, SW_SHOW);
        _ = UpdateWindow(hwnd);

        window.hdc = GetDC(hwnd) orelse return error.GetDCFailed;

        // Dummy pixel format + legacy context, needed to bootstrap modern GL.
        var pfd = std.mem.zeroes(PIXELFORMATDESCRIPTOR);
        pfd.nSize = @sizeOf(PIXELFORMATDESCRIPTOR);
        pfd.nVersion = 1;
        pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
        pfd.iPixelType = PFD_TYPE_RGBA;
        pfd.cColorBits = 32;
        pfd.cDepthBits = 24;
        pfd.cStencilBits = 8;
        pfd.iLayerType = PFD_MAIN_PLANE;

        const pf = ChoosePixelFormat(window.hdc.?, &pfd);
        if (pf == 0) return error.ChoosePixelFormatFailed;
        if (SetPixelFormat(window.hdc.?, pf, &pfd) == 0) return error.SetPixelFormatFailed;

        const legacy = wglCreateContext(window.hdc.?) orelse return error.CreateContextFailed;
        defer _ = wglDeleteContext(legacy);
        if (wglMakeCurrent(window.hdc, legacy) == 0) return error.MakeCurrentFailed;

        const proc = wglGetProcAddress("wglCreateContextAttribsARB") orelse
            return error.MissingWglCreateContextAttribs;
        const create_attrib_ctx: *const fn (?HDC, ?HGLRC, [*c]const i32) callconv(WINAPI) ?HGLRC =
            @ptrCast(proc);

        const attribs = [_]i32{
            WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
            WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0, // terminator
        };

        window.glrc = create_attrib_ctx(window.hdc.?, null, &attribs) orelse
            return error.CreateGL33ContextFailed;
        if (wglMakeCurrent(window.hdc, window.glrc) == 0) return error.MakeCurrentFailed;

        return window;
    }

    /// Pumps all pending window messages.
    pub fn pumpMessages(self: *Window) void {
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        if (g_should_close) self.should_close = true;
    }

    pub fn swap(self: *Window) void {
        if (self.hdc) |hdc| _ = SwapBuffers(hdc);
    }

    pub fn deinit(self: *Window) void {
        if (self.glrc) |rc| {
            _ = wglMakeCurrent(null, null);
            _ = wglDeleteContext(rc);
            self.glrc = null;
        }
        if (self.hwnd) |h| {
            if (self.hdc) |dc| _ = ReleaseDC(h, dc);
            _ = DestroyWindow(h);
            self.hdc = null;
            self.hwnd = null;
        }
    }
};
