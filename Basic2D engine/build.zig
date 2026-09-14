const std = @import("std");

/// C sources of the embedded Lua 5.4 runtime.
/// `lua.c` (standalone interpreter) and `luac.c` are excluded because they
/// define their own `main`.
const lua_sources = [_][]const u8{
    "lapi.c",     "lauxlib.c",  "lbaselib.c", "lcode.c",
    "lcorolib.c", "lctype.c",   "ldblib.c",   "ldebug.c",
    "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",
    "linit.c",    "liolib.c",   "llex.c",     "lmathlib.c",
    "lmem.c",     "loadlib.c",  "lobject.c",  "lopcodes.c",
    "loslib.c",   "lparser.c",  "lstate.c",   "lstring.c",
    "lstrlib.c",  "ltable.c",   "ltablib.c",  "ltm.c",
    "lundump.c",  "lutf8lib.c", "lvm.c",      "lzio.c",
};

fn addWindowsLinkage(exe: *std.Build.Step.Compile) void {
    exe.root_module.link_libc = true; // Lua is C
    exe.root_module.linkSystemLibrary("opengl32", .{}); // OpenGL
    exe.root_module.linkSystemLibrary("gdi32", .{}); // WGL / SwapBuffers
    exe.root_module.linkSystemLibrary("user32", .{}); // windowing + input
    exe.root_module.linkSystemLibrary("shell32", .{}); // CommandLineToArgvW
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Lua 5.4.8 pulled by the Zig package manager (see build.zig.zon).
    const lua_dep = b.dependency("lua", .{ .target = target, .optimize = optimize });

    // The engine is a plain Zig module: `@import("basic2d")`.
    const engine_mod = b.addModule("basic2d", .{
        .root_source_file = b.path("engine/engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Compile the Lua C runtime into the engine module.
    engine_mod.addCSourceFiles(.{
        .root = lua_dep.path(""),
        .files = &lua_sources,
        .flags = &.{},
    });
    engine_mod.addIncludePath(lua_dep.path(""));

    // --- Lua Pong example (game logic entirely in Lua) ---
    const lua_exe = b.addExecutable(.{
        .name = "lua_pong",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/lua_pong/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "basic2d", .module = engine_mod },
            },
        }),
    });
    addWindowsLinkage(lua_exe);
    b.installArtifact(lua_exe);

    // --- Zig Pong example (game logic entirely in Zig) ---
    const zig_exe = b.addExecutable(.{
        .name = "zig_pong",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zig_pong/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "basic2d", .module = engine_mod },
            },
        }),
    });
    addWindowsLinkage(zig_exe);
    b.installArtifact(zig_exe);

    // `zig build run`      -> Lua example
    const run_lua_cmd = b.addRunArtifact(lua_exe);
    run_lua_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_lua_cmd.addArgs(args);
    const run_lua_step = b.step("run", "Run the Lua Pong example");
    run_lua_step.dependOn(&run_lua_cmd.step);

    // `zig build run-zig`  -> Zig example
    const run_zig_cmd = b.addRunArtifact(zig_exe);
    run_zig_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_zig_cmd.addArgs(args);
    const run_zig_step = b.step("run-zig", "Run the Zig Pong example");
    run_zig_step.dependOn(&run_zig_cmd.step);
}
