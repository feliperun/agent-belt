//! The Win32 surface Agent Belt uses on Windows: windows and messages, the
//! notification-area icon and its menu, a low-level keyboard hook, SendInput,
//! GDI for the overlay, waveIn for the microphone, Credential Manager and the
//! Run registry key.
const std = @import("std");

pub const BOOL = c_int;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WORD = u16;
pub const LONG = c_long;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const HANDLE = *anyopaque;
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMENU = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HDC = *opaque {};
pub const HGDIOBJ = *opaque {};
pub const HFONT = *opaque {};
pub const HPEN = *opaque {};
pub const HRGN = *opaque {};
pub const HBITMAP = *opaque {};
pub const HHOOK = *opaque {};
pub const HKEY = *opaque {};
pub const HWAVEIN = *opaque {};
pub const WCHAR = u16;
pub const LPCWSTR = [*:0]const WCHAR;

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub const HOOKPROC = *const fn (c_int, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub const TIMERPROC = ?*const fn (HWND, UINT, usize, DWORD) callconv(.winapi) void;

pub const POINT = extern struct { x: LONG = 0, y: LONG = 0 };
pub const RECT = extern struct { left: LONG = 0, top: LONG = 0, right: LONG = 0, bottom: LONG = 0 };
pub const MSG = extern struct { hwnd: ?HWND, message: UINT, wParam: WPARAM, lParam: LPARAM, time: DWORD, pt: POINT, lPrivate: DWORD };

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const PAINTSTRUCT = extern struct { hdc: ?HDC, fErase: BOOL, rcPaint: RECT, fRestore: BOOL, fIncUpdate: BOOL, rgbReserved: [32]u8 };

pub const GUID = extern struct { data1: u32 = 0, data2: u16 = 0, data3: u16 = 0, data4: [8]u8 = .{0} ** 8 };

pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: UINT = 1,
    uFlags: UINT = 0,
    uCallbackMessage: UINT = 0,
    hIcon: ?HICON = null,
    szTip: [128]WCHAR = .{0} ** 128,
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]WCHAR = .{0} ** 256,
    uVersion: UINT = 0,
    szInfoTitle: [64]WCHAR = .{0} ** 64,
    dwInfoFlags: DWORD = 0,
    guidItem: GUID = .{},
    hBalloonIcon: ?HICON = null,
};

pub const KBDLLHOOKSTRUCT = extern struct { vkCode: DWORD, scanCode: DWORD, flags: DWORD, time: DWORD, dwExtraInfo: usize };

pub const KEYBDINPUT = extern struct { wVk: WORD, wScan: WORD, dwFlags: DWORD, time: DWORD = 0, dwExtraInfo: usize = 0 };
pub const MOUSEINPUT = extern struct { dx: LONG, dy: LONG, mouseData: DWORD, dwFlags: DWORD, time: DWORD, dwExtraInfo: usize };
pub const INPUT = extern struct {
    type: DWORD,
    u: extern union { ki: KEYBDINPUT, mi: MOUSEINPUT },
};

pub const WAVEFORMATEX = extern struct { wFormatTag: WORD, nChannels: WORD, nSamplesPerSec: DWORD, nAvgBytesPerSec: DWORD, nBlockAlign: WORD, wBitsPerSample: WORD, cbSize: WORD };
pub const WAVEHDR = extern struct { lpData: [*]u8, dwBufferLength: DWORD, dwBytesRecorded: DWORD = 0, dwUser: usize = 0, dwFlags: DWORD = 0, dwLoops: DWORD = 0, lpNext: ?*WAVEHDR = null, reserved: usize = 0 };

pub const FILETIME = extern struct { low: DWORD = 0, high: DWORD = 0 };
pub const CREDENTIALW = extern struct {
    Flags: DWORD = 0,
    Type: DWORD,
    TargetName: LPCWSTR,
    Comment: ?LPCWSTR = null,
    LastWritten: FILETIME = .{},
    CredentialBlobSize: DWORD,
    CredentialBlob: ?[*]u8,
    Persist: DWORD,
    AttributeCount: DWORD = 0,
    Attributes: ?*anyopaque = null,
    TargetAlias: ?LPCWSTR = null,
    UserName: ?LPCWSTR,
};

// ---------------------------------------------------------------- constants

pub const WM_DESTROY = 0x0002;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_COMMAND = 0x0111;
pub const WM_TIMER = 0x0113;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_APP = 0x8000;
pub const WM_SETFONT = 0x0030;

pub const WS_OVERLAPPED = 0x00000000;
pub const WS_POPUP = 0x80000000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_CHILD = 0x40000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_BORDER = 0x00800000;
pub const WS_TABSTOP = 0x00010000;
pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_TRANSPARENT = 0x00000020;
pub const WS_EX_TOOLWINDOW = 0x00000080;
pub const WS_EX_LAYERED = 0x00080000;
pub const WS_EX_NOACTIVATE = 0x08000000;
pub const WS_EX_CLIENTEDGE = 0x00000200;
pub const ES_AUTOHSCROLL = 0x0080;
pub const BS_DEFPUSHBUTTON = 0x0001;

pub const SW_HIDE = 0;
pub const SW_SHOW = 5;
pub const SW_SHOWNOACTIVATE = 4;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_SHOWWINDOW = 0x0040;
pub const HWND_TOPMOST: ?HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const LWA_ALPHA = 0x2;

pub const MF_STRING = 0x0000;
pub const MF_GRAYED = 0x0001;
pub const MF_SEPARATOR = 0x0800;
pub const TPM_RIGHTBUTTON = 0x0002;
pub const TPM_RETURNCMD = 0x0100;
pub const TPM_NONOTIFY = 0x0080;

pub const NIM_ADD = 0;
pub const NIM_MODIFY = 1;
pub const NIM_DELETE = 2;
pub const NIF_MESSAGE = 0x1;
pub const NIF_ICON = 0x2;
pub const NIF_TIP = 0x4;
pub const NIF_INFO = 0x10;

pub const WH_KEYBOARD_LL = 13;
pub const LLKHF_INJECTED = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_SHIFT = 0x10;
pub const VK_LWIN = 0x5B;
pub const VK_RETURN = 0x0D;
pub const VK_SPACE = 0x20;
pub const VK_UP = 0x26;
pub const VK_DOWN = 0x28;

pub const INPUT_KEYBOARD = 1;
pub const KEYEVENTF_KEYUP = 0x2;
pub const KEYEVENTF_UNICODE = 0x4;

pub const IMAGE_ICON = 1;
pub const LR_DEFAULTSIZE = 0x40;
pub const SPI_GETWORKAREA = 0x0030;
pub const TRANSPARENT = 1;
pub const DT_LEFT = 0;
pub const DT_SINGLELINE = 0x20;
pub const DT_VCENTER = 0x4;
pub const DT_END_ELLIPSIS = 0x8000;
pub const PS_SOLID = 0;
pub const FW_NORMAL = 400;
pub const FW_SEMIBOLD = 600;

pub const WAVE_MAPPER: UINT = 0xFFFFFFFF;
pub const WAVE_FORMAT_PCM = 1;
pub const WHDR_DONE = 0x1;
pub const CALLBACK_NULL = 0;

pub const CRED_TYPE_GENERIC = 1;
pub const CRED_PERSIST_LOCAL_MACHINE = 2;
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const KEY_SET_VALUE = 0x0002;
pub const REG_SZ = 1;
pub const ERROR_ALREADY_EXISTS = 183;

pub fn rgb(r: u8, g: u8, b: u8) DWORD {
    return @as(DWORD, r) | (@as(DWORD, g) << 8) | (@as(DWORD, b) << 16);
}

// ---------------------------------------------------------------- functions

pub extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn CreateMutexW(attrs: ?*anyopaque, owner: BOOL, name: LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?LPCWSTR = null,
    lpDesktop: ?LPCWSTR = null,
    lpTitle: ?LPCWSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: WORD = 0,
    cbReserved2: WORD = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
pub const PROCESS_INFORMATION = extern struct { hProcess: ?HANDLE = null, hThread: ?HANDLE = null, dwProcessId: DWORD = 0, dwThreadId: DWORD = 0 };
pub const CREATE_NEW_CONSOLE = 0x10;
pub const CREATE_UNICODE_ENVIRONMENT = 0x400;
pub extern "kernel32" fn CreateProcessW(app: ?LPCWSTR, cmd: [*:0]u16, pattrs: ?*anyopaque, tattrs: ?*anyopaque, inherit: BOOL, flags: DWORD, env: ?*anyopaque, cwd: ?LPCWSTR, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) WORD;
pub extern "user32" fn CreateWindowExW(ex: DWORD, class: LPCWSTR, name: LPCWSTR, style: DWORD, x: c_int, y: c_int, w: c_int, h: c_int, parent: ?HWND, menu: ?HMENU, instance: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(hwnd: ?HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(code: c_int) callconv(.winapi) void;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: c_int, y: c_int, w: c_int, h: c_int, flags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(point: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn LoadImageW(instance: ?HINSTANCE, name: usize, kind: UINT, cx: c_int, cy: c_int, flags: UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn AppendMenuW(menu: HMENU, flags: UINT, id: usize, text: ?LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn TrackPopupMenu(menu: HMENU, flags: UINT, x: c_int, y: c_int, reserved: c_int, hwnd: HWND, rect: ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn DestroyMenu(menu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowsHookExW(id: c_int, proc: HOOKPROC, instance: ?HINSTANCE, thread: DWORD) callconv(.winapi) ?HHOOK;
pub extern "user32" fn CallNextHookEx(hook: ?HHOOK, code: c_int, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetAsyncKeyState(vk: c_int) callconv(.winapi) i16;
pub extern "user32" fn SendInput(count: UINT, inputs: [*]const INPUT, size: c_int) callconv(.winapi) UINT;
pub extern "user32" fn SetTimer(hwnd: ?HWND, id: usize, ms: UINT, proc: TIMERPROC) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(hwnd: ?HWND, id: usize) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(hwnd: ?HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(hwnd: HWND, ps: *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(hdc: HDC, rect: *const RECT, brush: HBRUSH) callconv(.winapi) c_int;
pub extern "user32" fn DrawTextW(hdc: HDC, text: [*]const WCHAR, len: c_int, rect: *RECT, format: UINT) callconv(.winapi) c_int;
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, key: DWORD, alpha: u8, flags: DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowRgn(hwnd: HWND, rgn: ?HRGN, redraw: BOOL) callconv(.winapi) c_int;
pub extern "user32" fn SystemParametersInfoW(action: UINT, param: UINT, pv: ?*anyopaque, ini: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowTextW(hwnd: HWND, text: [*]WCHAR, max: c_int) callconv(.winapi) c_int;
pub extern "user32" fn SendMessageW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn SetFocus(hwnd: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn IsDialogMessageW(hwnd: HWND, msg: *MSG) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn GetSysColorBrush(index: c_int) callconv(.winapi) ?HBRUSH;
pub extern "user32" fn FindWindowW(class: ?LPCWSTR, name: ?LPCWSTR) callconv(.winapi) ?HWND;
pub extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;

pub extern "shell32" fn Shell_NotifyIconW(message: DWORD, data: *NOTIFYICONDATAW) callconv(.winapi) BOOL;

pub extern "gdi32" fn CreateSolidBrush(color: DWORD) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn CreatePen(style: c_int, width: c_int, color: DWORD) callconv(.winapi) ?HPEN;
pub extern "gdi32" fn DeleteObject(obj: HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn SelectObject(hdc: HDC, obj: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: DWORD) callconv(.winapi) DWORD;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn CreateFontW(h: c_int, w: c_int, esc: c_int, orient: c_int, weight: c_int, italic: DWORD, underline: DWORD, strike: DWORD, charset: DWORD, outprec: DWORD, clipprec: DWORD, quality: DWORD, pitch: DWORD, face: LPCWSTR) callconv(.winapi) ?HFONT;
pub extern "gdi32" fn Polyline(hdc: HDC, points: [*]const POINT, count: c_int) callconv(.winapi) BOOL;
pub extern "gdi32" fn Ellipse(hdc: HDC, l: c_int, t: c_int, r: c_int, b: c_int) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateRoundRectRgn(l: c_int, t: c_int, r: c_int, b: c_int, w: c_int, h: c_int) callconv(.winapi) ?HRGN;
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, w: c_int, h: c_int) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn BitBlt(dst: HDC, x: c_int, y: c_int, w: c_int, h: c_int, src: HDC, sx: c_int, sy: c_int, rop: DWORD) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
pub const SRCCOPY: DWORD = 0x00CC0020;

pub extern "winmm" fn waveInOpen(handle: *?HWAVEIN, device: UINT, format: *const WAVEFORMATEX, callback: usize, instance: usize, flags: DWORD) callconv(.winapi) UINT;
pub extern "winmm" fn waveInPrepareHeader(handle: HWAVEIN, header: *WAVEHDR, size: UINT) callconv(.winapi) UINT;
pub extern "winmm" fn waveInUnprepareHeader(handle: HWAVEIN, header: *WAVEHDR, size: UINT) callconv(.winapi) UINT;
pub extern "winmm" fn waveInAddBuffer(handle: HWAVEIN, header: *WAVEHDR, size: UINT) callconv(.winapi) UINT;
pub extern "winmm" fn waveInStart(handle: HWAVEIN) callconv(.winapi) UINT;
pub extern "winmm" fn waveInStop(handle: HWAVEIN) callconv(.winapi) UINT;
pub extern "winmm" fn waveInReset(handle: HWAVEIN) callconv(.winapi) UINT;
pub extern "winmm" fn waveInClose(handle: HWAVEIN) callconv(.winapi) UINT;

pub extern "advapi32" fn CredReadW(target: LPCWSTR, kind: DWORD, flags: DWORD, cred: *?*CREDENTIALW) callconv(.winapi) BOOL;
pub extern "advapi32" fn CredWriteW(cred: *const CREDENTIALW, flags: DWORD) callconv(.winapi) BOOL;
pub extern "advapi32" fn CredFree(buffer: *anyopaque) callconv(.winapi) void;
pub extern "advapi32" fn RegSetKeyValueW(key: HKEY, sub: ?LPCWSTR, name: ?LPCWSTR, kind: DWORD, data: ?*const anyopaque, size: DWORD) callconv(.winapi) LONG;
pub extern "advapi32" fn RegDeleteKeyValueW(key: HKEY, sub: ?LPCWSTR, name: ?LPCWSTR) callconv(.winapi) LONG;

/// UTF-8 to a NUL-terminated UTF-16 string.
pub fn wide(gpa: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, text);
}

pub fn L(comptime text: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}
