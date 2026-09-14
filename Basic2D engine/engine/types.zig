//! Shared value types used across the engine.

const std = @import("std");

/// 2D vector, mirrors Unity's Vector2 (2D-only).
pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub const zero: Vec2 = .{};
    pub const one: Vec2 = .{ .x = 1, .y = 1 };
    pub const up: Vec2 = .{ .x = 0, .y = 1 };
    pub const down: Vec2 = .{ .x = 0, .y = -1 };
    pub const left: Vec2 = .{ .x = -1, .y = 0 };
    pub const right: Vec2 = .{ .x = 1, .y = 0 };

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn mulScalar(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn divScalar(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x / s, .y = a.y / s };
    }
    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn length(self: Vec2) f32 {
        return @sqrt(dot(self, self));
    }
    pub fn distance(a: Vec2, b: Vec2) f32 {
        return sub(b, a).length();
    }
    pub fn normalized(self: Vec2) Vec2 {
        const len = self.length();
        if (len == 0) return .{};
        return divScalar(self, len);
    }
    /// Linear interpolation between a and b by t (clamped to [0,1]).
    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        const tc = std.math.clamp(t, 0, 1);
        return .{ .x = a.x + (b.x - a.x) * tc, .y = a.y + (b.y - a.y) * tc };
    }
    pub fn eql(a: Vec2, b: Vec2) bool {
        return a.x == b.x and a.y == b.y;
    }
};

/// A GPU texture handle (used by sprites and the font atlas).
pub const Texture = struct {
    id: u32, // OpenGL texture object
    width: u32,
    height: u32,
};

/// RGBA color, mirrors Unity's Color.
pub const Color = struct {
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,

    pub fn init(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const red: Color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const green: Color = .{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const blue: Color = .{ .r = 0, .g = 0, .b = 1, .a = 1 };
    pub const yellow: Color = .{ .r = 1, .g = 1, .b = 0, .a = 1 };
    pub const cyan: Color = .{ .r = 0, .g = 1, .b = 1, .a = 1 };
    pub const magenta: Color = .{ .r = 1, .g = 0, .b = 1, .a = 1 };
    pub const gray: Color = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 };
    pub const clear: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

// A small global PRNG, like Unity's Random.Range.
var prng = std.Random.DefaultPrng.init(0x1234_5678_9abc_def0);

/// Math helpers mirroring Unity's Mathf.
pub const Mathf = struct {
    pub const pi: f32 = std.math.pi;

    pub fn clamp(v: f32, lo: f32, hi: f32) f32 {
        return std.math.clamp(v, lo, hi);
    }
    pub fn lerp(a: f32, b: f32, t: f32) f32 {
        const tc = std.math.clamp(t, 0, 1);
        return a + (b - a) * tc;
    }
    pub fn abs(v: f32) f32 {
        return @abs(v);
    }
    pub fn sin(v: f32) f32 {
        return @sin(v);
    }
    pub fn cos(v: f32) f32 {
        return @cos(v);
    }
    pub fn sqrt(v: f32) f32 {
        return @sqrt(v);
    }
    pub fn pow(a: f32, b: f32) f32 {
        return std.math.pow(f32, a, b);
    }
    pub fn min(a: f32, b: f32) f32 {
        return @min(a, b);
    }
    pub fn max(a: f32, b: f32) f32 {
        return @max(a, b);
    }
    pub fn floor(v: f32) f32 {
        return @floor(v);
    }
    pub fn ceil(v: f32) f32 {
        return @ceil(v);
    }
    pub fn randomRange(lo: f32, hi: f32) f32 {
        const r = prng.random().float(f32);
        return lo + r * (hi - lo);
    }
};
