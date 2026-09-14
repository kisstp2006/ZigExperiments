//! Bootstraps the Basic2D engine and runs the embedded Lua game.
const std = @import("std");
const basic2d = @import("basic2d");

const GAME_SCRIPT = @embedFile("game.lua");

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const alloc = da.allocator();

    var engine = try basic2d.Engine.init(alloc, .{
        .title = "Basic2D - Pong (Lua)",
        .width = 800,
        .height = 600,
    });
    defer engine.deinit();

    try engine.startLua(GAME_SCRIPT, "game.lua");

    while (!engine.shouldClose()) {
        _ = engine.update(); // runs Lua Update hooks
        engine.render();
    }
}
