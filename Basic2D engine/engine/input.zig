//! Keyboard + mouse polling, mirroring Unity's Input class (2D subset).

const std = @import("std");
const win32 = @import("win32.zig");
const types = @import("types.zig");

const Vec2 = types.Vec2;

pub const Key = enum {
    up_arrow,
    down_arrow,
    left_arrow,
    right_arrow,
    space,
    enter,
    tab,
    escape,
    left_shift,
    right_shift,
    left_control,
    right_control,
    left_alt,
    right_alt,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    num_0,
    num_1,
    num_2,
    num_3,
    num_4,
    num_5,
    num_6,
    num_7,
    num_8,
    num_9,
};

fn vkOf(key: Key) i32 {
    return switch (key) {
        .up_arrow => 0x26,
        .down_arrow => 0x28,
        .left_arrow => 0x25,
        .right_arrow => 0x27,
        .space => 0x20,
        .enter => 0x0D,
        .tab => 0x09,
        .escape => 0x1B,
        .left_shift => 0xA0,
        .right_shift => 0xA1,
        .left_control => 0xA2,
        .right_control => 0xA3,
        .left_alt => 0xA4,
        .right_alt => 0xA5,
        .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => 0x41 + (@as(i32, @intFromEnum(key)) - @as(i32, @intFromEnum(Key.a))),
        .num_0, .num_1, .num_2, .num_3, .num_4, .num_5, .num_6, .num_7, .num_8, .num_9 => 0x30 + (@as(i32, @intFromEnum(key)) - @as(i32, @intFromEnum(Key.num_0))),
    };
}

fn letters() [26]i32 {
    var a: [26]i32 = undefined;
    for (0..26) |i| a[i] = 0x41 + @as(i32, @intCast(i));
    return a;
}
fn digits() [10]i32 {
    var a: [10]i32 = undefined;
    for (0..10) |i| a[i] = 0x30 + @as(i32, @intCast(i));
    return a;
}

const base_tracked = [14]i32{
    0x26, 0x28, 0x25, 0x27, // arrows
    0x20, 0x0D, 0x09, 0x1B, // space, enter, tab, escape
    0xA0, 0xA1, 0xA2, 0xA3, // shifts/controls
    0xA4, 0xA5, // alts
};
const tracked = base_tracked ++ letters() ++ digits();

const VK_LBUTTON: i32 = 0x01;
const VK_RBUTTON: i32 = 0x02;
const VK_MBUTTON: i32 = 0x04;
const mouse_vks = [3]i32{ VK_LBUTTON, VK_RBUTTON, VK_MBUTTON };

/// Maps a Unity-style key name ("LeftArrow", "A", "Space", ...) to a virtual
/// key code, or null when unknown. Used by the Lua bindings.
pub fn vkFromName(name: []const u8) ?i32 {
    const names = .{
        "UpArrow",   "DownArrow",  "LeftArrow",   "RightArrow",
        "Space",     "Enter",      "Tab",         "Escape",
        "LeftShift", "RightShift", "LeftControl", "RightControl",
        "LeftAlt",   "RightAlt",
    };
    const codes = [14]i32{
        0x26, 0x28, 0x25, 0x27,
        0x20, 0x0D, 0x09, 0x1B,
        0xA0, 0xA1, 0xA2, 0xA3,
        0xA4, 0xA5,
    };
    inline for (names, 0..) |n, i| {
        if (std.mem.eql(u8, name, n)) return codes[i];
    }
    if (name.len == 1) {
        const c = name[0];
        if (c >= 'A' and c <= 'Z') return 0x41 + (@as(i32, c) - 'A');
        if (c >= 'a' and c <= 'z') return 0x41 + (@as(i32, c) - 'a');
        if (c >= '0' and c <= '9') return 0x30 + (@as(i32, c) - '0');
    }
    return null;
}

fn keyIsDown(state: i16) bool {
    return (@as(u16, @bitCast(state)) & 0x8000) != 0;
}

pub const Input = struct {
    cur: [256]bool = [_]bool{false} ** 256,
    prev: [256]bool = [_]bool{false} ** 256,
    mouse_cur: [3]bool = .{ false, false, false },
    mouse_prev: [3]bool = .{ false, false, false },
    mouse: Vec2 = .{},
    /// Mouse wheel delta in notches this frame (Unity's Input.mouseScrollDelta).
    mouse_scroll: Vec2 = .{},

    pub fn update(self: *Input, window: *const win32.Window) void {
        for (tracked) |vk| {
            self.prev[@intCast(vk)] = self.cur[@intCast(vk)];
            self.cur[@intCast(vk)] = keyIsDown(win32.getAsyncKeyState(vk));
        }
        for (0..3) |b| {
            self.mouse_prev[b] = self.mouse_cur[b];
            self.mouse_cur[b] = keyIsDown(win32.getAsyncKeyState(mouse_vks[b]));
        }

        const wheel = win32.takeMouseWheel();
        self.mouse_scroll = Vec2.init(0, @as(f32, @floatFromInt(wheel)) / 120.0);

        var cursor: win32.POINT = undefined;
        if (win32.GetCursorPos(&cursor) != 0) {
            if (window.hwnd) |hwnd| {
                var rect: win32.RECT = undefined;
                if (win32.GetClientRect(hwnd, &rect) != 0) {
                    var origin: win32.POINT = .{ .x = rect.left, .y = rect.top };
                    if (win32.ClientToScreen(hwnd, &origin) != 0) {
                        const mx: f32 = @floatFromInt(cursor.x - origin.x);
                        const my_topdown: f32 = @floatFromInt(cursor.y - origin.y);
                        const h: f32 = @floatFromInt(rect.bottom - rect.top);
                        self.mouse = Vec2.init(mx, h - my_topdown);
                    }
                }
            }
        }
    }

    pub fn getKey(self: *const Input, key: Key) bool {
        return self.cur[@intCast(vkOf(key))];
    }
    pub fn getKeyDown(self: *const Input, key: Key) bool {
        const vk: usize = @intCast(vkOf(key));
        return self.cur[vk] and !self.prev[vk];
    }
    pub fn getKeyVk(self: *const Input, vk: i32) bool {
        return self.cur[@intCast(vk)];
    }
    pub fn getKeyDownVk(self: *const Input, vk: i32) bool {
        const i: usize = @intCast(vk);
        return self.cur[i] and !self.prev[i];
    }
    /// Unity-style GetAxisRaw: "Horizontal" or "Vertical" in [-1, 1].
    pub fn getAxisRaw(self: *const Input, horizontal: bool) f32 {
        var v: f32 = 0;
        if (horizontal) {
            if (self.getKey(.right_arrow) or self.getKey(.d)) v += 1;
            if (self.getKey(.left_arrow) or self.getKey(.a)) v -= 1;
        } else {
            if (self.getKey(.up_arrow) or self.getKey(.w)) v += 1;
            if (self.getKey(.down_arrow) or self.getKey(.s)) v -= 1;
        }
        return v;
    }
    pub fn getMouseButton(self: *const Input, button: usize) bool {
        return if (button < 3) self.mouse_cur[button] else false;
    }
    pub fn getMouseButtonDown(self: *const Input, button: usize) bool {
        return if (button < 3) self.mouse_cur[button] and !self.mouse_prev[button] else false;
    }
};
