//! Embedded Lua 5.4 host exposing the Unity-like 2D API to Lua:
//!
//!   Engine.CreateGameObject / go.transform / go:AddSpriteRenderer()
//!   go:AddBoxCollider2D() / go:AddCircleCollider2D() / go:AddScript(t)
//!   go:AddComponent(name) / go:GetComponent(name)
//!   go:StartCoroutine(f) / go:SetActive(b) / go:Destroy()
//!   GameObject.Find / GameObject.FindWithTag / go.tag / Destroy(go)
//!   Time / Input / Debug / Mathf / Physics2D / Vector2 / Color / WaitForSeconds
//!
//! Scripts are plain tables with MonoBehaviour-style `Start`/`Update` methods.
//! Every game object is an ECS entity behind the scenes (engine/ecs.zig).

const std = @import("std");
const engine_mod = @import("engine.zig");
const ecs = @import("ecs.zig");
const input_mod = @import("input.zig");
const types = @import("types.zig");
const lua = @import("lua_c.zig");

const Engine = engine_mod.Engine;
const World = ecs.World;
const EntityId = ecs.EntityId;
const GameObject = ecs.GameObject;
const Vec2 = types.Vec2;
const Color = types.Color;

// Metatable names used with luaL_newmetatable / luaL_checkudata.
const MT = struct {
    pub const game_object = "Basic2D.GameObject";
    pub const transform = "Basic2D.Transform";
    pub const sprite = "Basic2D.SpriteRenderer";
    pub const sprite_asset = "Basic2D.Sprite";
    pub const text_mesh = "Basic2D.TextMesh";
    pub const box_collider = "Basic2D.BoxCollider2D";
    pub const circle_collider = "Basic2D.CircleCollider2D";
    pub const ui_image = "Basic2D.UIImage";
    pub const ui_text = "Basic2D.UIText";
    pub const ui_button = "Basic2D.UIButton";
    pub const vector2 = "Basic2D.Vector2";
    pub const color = "Basic2D.Color";
    pub const wait_seconds = "Basic2D.WaitForSeconds";
    pub const engine_table = "Basic2D.EngineTable";
    pub const input_table = "Basic2D.InputTable";
};

const Vec2Ud = struct { ptr: *Vec2, owned: bool };
const ColorUd = struct { ptr: *Color, owned: bool };

fn onLuaPanic(L: *lua.lua_State) callconv(.c) c_int {
    const msg = lua.lua_tolstring(L, 1, null);
    std.debug.print("LUA PANIC: {s}\n", .{if (msg) |m| std.mem.span(m) else "?"});
    lua.luaL_traceback(L, L, "traceback:", 0);
    if (lua.lua_tolstring(L, -1, null)) |tb| {
        std.debug.print("{s}\n", .{std.mem.span(tb)});
    }
    return 0;
}

const Coroutine = struct {
    ref: c_int,
    wait_until: f64,
    done: bool,
};

pub const LuaHost = struct {
    L: *lua.lua_State,
    engine: *Engine,
    coroutines: std.ArrayList(Coroutine) = .empty,
    /// ECS systems registered via World.AddSystem(fn): Lua registry refs
    /// called every frame with deltaTime.
    systems: std.ArrayList(c_int) = .empty,
    global_update_ref: c_int = -1,

    /// Creates the Lua state and registers the whole API.
    /// `self_ptr` must be the final address of this LuaHost (it is stored in
    /// the Lua registry so C callbacks can find the host before it is
    /// assigned to `Engine.lua`).
    pub fn init(engine: *Engine, self_ptr: *LuaHost) !LuaHost {
        const L = lua.luaL_newstate() orelse return error.LuaAllocFailed;
        errdefer lua.lua_close(L);

        lua.luaL_openlibs(L);
        _ = lua.lua_atpanic(L, @ptrCast(&onLuaPanic));

        lua.lua_pushlightuserdata(L, @ptrCast(self_ptr));
        lua.lua_setfield(L, lua.LUA_REGISTRYINDEX, "__host");

        registerMetatables(L);
        registerGlobals(L);

        return .{ .L = L, .engine = engine };
    }

    pub fn deinit(self: *LuaHost) void {
        for (self.systems.items) |ref| lua.luaL_unref(self.L, lua.LUA_REGISTRYINDEX, ref);
        self.systems.deinit(self.engine.allocator);
        self.coroutines.deinit(self.engine.allocator);
        lua.lua_close(self.L);
    }

    /// Executes the game script once (scene setup), like Unity running a
    /// scene at play time.
    pub fn runChunk(self: *LuaHost, source: []const u8, chunkname: [:0]const u8) !void {
        const L = self.L;
        const chunkz = try self.engine.allocator.dupeZ(u8, source);
        defer self.engine.allocator.free(chunkz);

        if (lua.luaL_loadbuffer(L, chunkz.ptr, chunkz.len, chunkname.ptr) != lua.LUA_OK) {
            printLuaError(L);
            return error.LuaScriptError;
        }
        if (lua.lua_pcall(L, 0, 0, 0) != lua.LUA_OK) {
            printLuaError(L);
            return error.LuaScriptError;
        }
    }

    /// Called by Engine.update once per frame.
    pub fn update(self: *LuaHost, dt: f32) void {
        const L = self.L;

        // Time table
        _ = lua.lua_getglobal(L, "Time");
        lua.lua_pushnumber(L, dt);
        lua.lua_setfield(L, -2, "deltaTime");
        lua.lua_pushnumber(L, self.engine.time);
        lua.lua_setfield(L, -2, "time");
        lua.lua_pushnumber(L, @floatFromInt(self.engine.frame_count));
        lua.lua_setfield(L, -2, "frameCount");
        lua.lua_pop(L, 1);

        // ECS systems registered via World.AddSystem(function(dt) ... end).
        for (self.systems.items) |sys_ref| {
            _ = lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, sys_ref);
            lua.lua_pushnumber(L, dt);
            if (lua.lua_pcall(L, 1, 0, 0) != lua.LUA_OK) printLuaError(L);
        }

        // Global update callback (Engine.OnUpdate)
        if (self.global_update_ref != -1) {
            _ = lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, self.global_update_ref);
            lua.lua_pushnumber(L, dt);
            if (lua.lua_pcall(L, 1, 0, 0) != lua.LUA_OK) printLuaError(L);
        }

        // MonoBehaviour-style script Update (ScriptSystem: ECS query over
        // the ScriptComponent storage).
        var scripts = self.engine.world.scripts.iter();
        while (scripts.next()) |item| {
            const sc = item.comp;
            const info = &self.engine.world.entities.items[item.entity];
            if (!info.active or info.marked_for_destroy) continue;
            if (!sc.has_update or sc.registry_ref == -1) continue;
            _ = lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, sc.registry_ref);
            _ = lua.lua_getfield(L, -1, "Update");
            if (lua.lua_isfunction(L, -1) == 0) {
                lua.lua_pop(L, 2);
                continue;
            }
            lua.lua_pushvalue(L, -2); // self = the script table
            if (lua.lua_pcall(L, 1, 0, 0) != lua.LUA_OK) printLuaError(L);
            lua.lua_pop(L, 1); // the script table
        }

        self.updateCoroutines();
    }

    fn updateCoroutines(self: *LuaHost) void {
        const L = self.L;
        var i: usize = 0;
        while (i < self.coroutines.items.len) : (i += 1) {
            const co = &self.coroutines.items[i];
            if (co.done or self.engine.time < co.wait_until) continue;

            _ = lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, co.ref);
            const thread = lua.lua_tothread(L, -1);
            lua.lua_pop(L, 1);
            if (thread == null) {
                co.done = true;
                lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, co.ref);
                continue;
            }

            var nres: c_int = 0;
            const status = lua.lua_resume(thread.?, L, 0, &nres);
            if (status == lua.LUA_YIELD) {
                // The yielded values live on the COROUTINE's stack.
                if (nres > 0 and lua.lua_isuserdata(thread.?, -1) != 0) {
                    const p = lua.luaL_testudata(thread.?, -1, MT.wait_seconds);
                    if (p != null) {
                        const secs: *f64 = @ptrCast(@alignCast(p.?));
                        co.wait_until = self.engine.time + secs.*;
                    }
                }
                if (nres > 0) lua.lua_pop(thread.?, nres);
            } else {
                if (status != lua.LUA_OK) printLuaError(thread.?);
                co.done = true;
                lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, co.ref);
            }
        }
        // sweep finished coroutines
        var j: usize = 0;
        while (j < self.coroutines.items.len) {
            if (self.coroutines.items[j].done) {
                _ = self.coroutines.swapRemove(j);
            } else {
                j += 1;
            }
        }
    }

    /// Unrefs the script table of a dying entity (called by CleanupSystem
    /// right before the world releases the entity's components).
    pub fn onDestroyEntity(self: *LuaHost, entity: u32) void {
        if (self.engine.world.scripts.get(entity)) |sc| {
            if (sc.registry_ref != -1) {
                lua.luaL_unref(self.L, lua.LUA_REGISTRYINDEX, sc.registry_ref);
                sc.registry_ref = -1;
            }
        }
        if (self.engine.world.buttons.get(entity)) |b| {
            if (b.on_click_ref != -1) {
                lua.luaL_unref(self.L, lua.LUA_REGISTRYINDEX, b.on_click_ref);
                b.on_click_ref = -1;
            }
        }
    }

    /// Fires a UIButton's Lua onClick callback (called by the UISystem).
    pub fn fireUiCallback(self: *LuaHost, ref: c_int) void {
        _ = lua.lua_rawgeti(self.L, lua.LUA_REGISTRYINDEX, ref);
        if (lua.lua_pcall(self.L, 0, 0, 0) != lua.LUA_OK) printLuaError(self.L);
    }
};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn getHost(L: ?*lua.lua_State) *LuaHost {
    _ = lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, "__host");
    const p = lua.lua_touserdata(L, -1) orelse @panic("LuaHost registry entry missing");
    lua.lua_pop(L, 1);
    return @ptrCast(@alignCast(p));
}

fn getEngine(L: ?*lua.lua_State) *Engine {
    return getHost(L).engine;
}

fn printLuaError(L: ?*lua.lua_State) void {
    if (lua.lua_tolstring(L, -1, null)) |msg| {
        std.debug.print("[Lua error] {s}\n", .{std.mem.span(msg)});
    } else {
        std.debug.print("[Lua error] (non-string error object)\n", .{});
    }
    lua.lua_pop(L, 1);
}

fn luaOom(L: *lua.lua_State) c_int {
    return lua.luaL_error(L, "Basic2D: out of memory");
}

// --- userdata constructors/accessors ---

/// ECS-backed component userdata: entity + generation, resolved through
/// the world on every access. Pointers into the block storage are stable,
/// but generations make stale handles fail loudly — like Unity's
/// "destroyed object" errors.
const ComponentUd = struct {
    world: *World,
    entity: u32,
    generation: u32,
};

/// GameObject userdata: a world pointer + entity id.
const GoUd = struct {
    world: *World,
    id: EntityId,
};

fn pushGameObject(L: ?*lua.lua_State, go: GameObject) void {
    const mem = lua.lua_newuserdata(L, @sizeOf(GoUd)) orelse return;
    const ud: *GoUd = @ptrCast(@alignCast(mem));
    ud.* = .{ .world = go.world, .id = go.id };
    lua.luaL_setmetatable(L, MT.game_object);
}

/// Raw access (no validity check) for __eq / __tostring / Destroy.
fn checkGoUd(L: ?*lua.lua_State, idx: c_int) *GoUd {
    const mem = lua.luaL_checkudata(L, idx, MT.game_object);
    return @ptrCast(@alignCast(mem));
}

/// Validated access: raises a Unity-style error on stale handles.
fn checkGameObject(L: ?*lua.lua_State, idx: c_int) GameObject {
    const ud = checkGoUd(L, idx);
    if (!ud.world.isAlive(ud.id)) {
        _ = lua.luaL_error(L, "GameObject has been destroyed");
        unreachable;
    }
    return .{ .world = ud.world, .id = ud.id };
}

fn pushComponentUd(L: ?*lua.lua_State, metatable: [*:0]const u8, world: *World, entity: u32) void {
    const mem = lua.lua_newuserdata(L, @sizeOf(ComponentUd)) orelse return;
    const ud: *ComponentUd = @ptrCast(@alignCast(mem));
    ud.* = .{
        .world = world,
        .entity = entity,
        .generation = world.entities.items[entity].generation,
    };
    lua.luaL_setmetatable(L, metatable);
}

fn checkComponentUd(L: ?*lua.lua_State, idx: c_int, metatable: [*:0]const u8) *ComponentUd {
    const mem = lua.luaL_checkudata(L, idx, metatable);
    return @ptrCast(@alignCast(mem));
}

/// Builds a GameObject handle out of component userdata (component.gameObject).
fn pushGameObjectFromUd(L: ?*lua.lua_State, ud: *const ComponentUd) void {
    pushGameObject(L, .{
        .world = ud.world,
        .id = .{ .index = ud.entity, .generation = ud.generation },
    });
}

/// Resolves component userdata to a stable storage pointer, validating
/// the entity first (Unity-style "destroyed object" error).
fn resolveTransform(L: ?*lua.lua_State, ud: *const ComponentUd) *ecs.Transform {
    if (!ud.world.isValid(ud.entity, ud.generation)) {
        _ = lua.luaL_error(L, "Transform has been destroyed");
        unreachable;
    }
    return ud.world.transforms.at(ud.entity);
}

fn resolveSpriteRenderer(L: ?*lua.lua_State, ud: *const ComponentUd) *ecs.SpriteRenderer {
    if (!ud.world.isValid(ud.entity, ud.generation)) {
        _ = lua.luaL_error(L, "SpriteRenderer has been destroyed");
        unreachable;
    }
    return ud.world.sprites.at(ud.entity);
}

fn resolveTextMesh(L: ?*lua.lua_State, ud: *const ComponentUd) *ecs.TextMesh {
    if (!ud.world.isValid(ud.entity, ud.generation)) {
        _ = lua.luaL_error(L, "TextMesh has been destroyed");
        unreachable;
    }
    return ud.world.text_meshes.at(ud.entity);
}

fn resolveCollider(L: ?*lua.lua_State, ud: *const ComponentUd) *ecs.Collider2D {
    if (!ud.world.isValid(ud.entity, ud.generation)) {
        _ = lua.luaL_error(L, "Collider2D has been destroyed");
        unreachable;
    }
    return ud.world.colliders.at(ud.entity);
}

fn resolveUiImage(L: ?*lua.lua_State, ud: *const ComponentUd) *ecs.UIImage {
    if (!ud.world.isValid(ud.entity, ud.generation)) {
        _ = lua.luaL_error(L, "UIImage has been destroyed");
        unreachable;
    }
    return ud.world.images.at(ud.entity);
}

fn resolveUiText(L: ?*lua.lua_State, ud: *const ComponentUd) *ecs.UIText {
    if (!ud.world.isValid(ud.entity, ud.generation)) {
        _ = lua.luaL_error(L, "UIText has been destroyed");
        unreachable;
    }
    return ud.world.ui_texts.at(ud.entity);
}

fn resolveUiButton(L: ?*lua.lua_State, ud: *const ComponentUd) *ecs.UIButton {
    if (!ud.world.isValid(ud.entity, ud.generation)) {
        _ = lua.luaL_error(L, "UIButton has been destroyed");
        unreachable;
    }
    return ud.world.buttons.at(ud.entity);
}

fn anchorName(a: ecs.UIAnchor) []const u8 {
    return switch (a) {
        .top_left => "TopLeft",
        .top_center => "TopCenter",
        .top_right => "TopRight",
        .middle_left => "MiddleLeft",
        .center => "Center",
        .middle_right => "MiddleRight",
        .bottom_left => "BottomLeft",
        .bottom_center => "BottomCenter",
        .bottom_right => "BottomRight",
    };
}

fn anchorFromName(s: []const u8) ?ecs.UIAnchor {
    inline for (@typeInfo(ecs.UIAnchor).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, anchorName(@enumFromInt(f.value)))) {
            return @enumFromInt(f.value);
        }
    }
    return null;
}

fn pushTransform(L: ?*lua.lua_State, world: *World, entity: u32) void {
    pushComponentUd(L, MT.transform, world, entity);
}

fn checkTransform(L: ?*lua.lua_State, idx: c_int) *ComponentUd {
    return checkComponentUd(L, idx, MT.transform);
}

fn pushSpriteRenderer(L: ?*lua.lua_State, world: *World, entity: u32) void {
    pushComponentUd(L, MT.sprite, world, entity);
}

fn checkSpriteRenderer(L: ?*lua.lua_State, idx: c_int) *ComponentUd {
    return checkComponentUd(L, idx, MT.sprite);
}

fn pushSprite(L: ?*lua.lua_State, s: *engine_mod.Sprite) void {
    const mem = lua.lua_newuserdata(L, @sizeOf(*engine_mod.Sprite)) orelse return;
    const slot: **engine_mod.Sprite = @ptrCast(@alignCast(mem));
    slot.* = s;
    lua.luaL_setmetatable(L, MT.sprite_asset);
}

fn checkSprite(L: ?*lua.lua_State, idx: c_int) *engine_mod.Sprite {
    const mem = lua.luaL_checkudata(L, idx, MT.sprite_asset);
    const slot: **engine_mod.Sprite = @ptrCast(@alignCast(mem));
    return slot.*;
}

fn pushTextMesh(L: ?*lua.lua_State, world: *World, entity: u32) void {
    pushComponentUd(L, MT.text_mesh, world, entity);
}

fn checkTextMesh(L: ?*lua.lua_State, idx: c_int) *ComponentUd {
    return checkComponentUd(L, idx, MT.text_mesh);
}

fn pushBoxCollider(L: ?*lua.lua_State, world: *World, entity: u32) void {
    pushComponentUd(L, MT.box_collider, world, entity);
}

fn pushCircleCollider(L: ?*lua.lua_State, world: *World, entity: u32) void {
    pushComponentUd(L, MT.circle_collider, world, entity);
}

fn checkCollider(L: ?*lua.lua_State, idx: c_int) *ComponentUd {
    return checkComponentUd(L, idx, MT.box_collider);
}

fn checkCircleCollider(L: ?*lua.lua_State, idx: c_int) *ComponentUd {
    return checkComponentUd(L, idx, MT.circle_collider);
}

fn pushUiImage(L: ?*lua.lua_State, world: *World, entity: u32) void {
    pushComponentUd(L, MT.ui_image, world, entity);
}

fn checkUiImage(L: ?*lua.lua_State, idx: c_int) *ComponentUd {
    return checkComponentUd(L, idx, MT.ui_image);
}

fn pushUiText(L: ?*lua.lua_State, world: *World, entity: u32) void {
    pushComponentUd(L, MT.ui_text, world, entity);
}

fn checkUiText(L: ?*lua.lua_State, idx: c_int) *ComponentUd {
    return checkComponentUd(L, idx, MT.ui_text);
}

fn pushUiButton(L: ?*lua.lua_State, world: *World, entity: u32) void {
    pushComponentUd(L, MT.ui_button, world, entity);
}

fn checkUiButton(L: ?*lua.lua_State, idx: c_int) *ComponentUd {
    return checkComponentUd(L, idx, MT.ui_button);
}

/// Pushes a Vector2 userdata that owns its storage (freed by __gc).
fn pushVec2Owned(L: ?*lua.lua_State, v: Vec2) void {
    const e = getEngine(L);
    const storage = e.allocator.create(Vec2) catch return;
    storage.* = v;
    const mem = lua.lua_newuserdata(L, @sizeOf(Vec2Ud)) orelse return;
    const ud: *Vec2Ud = @ptrCast(@alignCast(mem));
    ud.* = .{ .ptr = storage, .owned = true };
    lua.luaL_setmetatable(L, MT.vector2);
}

/// Pushes a Vector2 userdata that views external storage (live reference,
/// e.g. transform.position). Mutating it mutates the transform.
fn pushVec2View(L: ?*lua.lua_State, v: *Vec2) void {
    const mem = lua.lua_newuserdata(L, @sizeOf(Vec2Ud)) orelse return;
    const ud: *Vec2Ud = @ptrCast(@alignCast(mem));
    ud.* = .{ .ptr = v, .owned = false };
    lua.luaL_setmetatable(L, MT.vector2);
}

fn checkVec2Ptr(L: ?*lua.lua_State, idx: c_int) *Vec2 {
    const mem = lua.luaL_checkudata(L, idx, MT.vector2);
    const ud: *Vec2Ud = @ptrCast(@alignCast(mem));
    return ud.ptr;
}

fn pushColorOwned(L: ?*lua.lua_State, c: Color) void {
    const e = getEngine(L);
    const storage = e.allocator.create(Color) catch return;
    storage.* = c;
    const mem = lua.lua_newuserdata(L, @sizeOf(ColorUd)) orelse return;
    const ud: *ColorUd = @ptrCast(@alignCast(mem));
    ud.* = .{ .ptr = storage, .owned = true };
    lua.luaL_setmetatable(L, MT.color);
}

fn pushColorView(L: ?*lua.lua_State, c: *Color) void {
    const mem = lua.lua_newuserdata(L, @sizeOf(ColorUd)) orelse return;
    const ud: *ColorUd = @ptrCast(@alignCast(mem));
    ud.* = .{ .ptr = c, .owned = false };
    lua.luaL_setmetatable(L, MT.color);
}

fn checkColorPtr(L: ?*lua.lua_State, idx: c_int) *Color {
    const mem = lua.luaL_checkudata(L, idx, MT.color);
    const ud: *ColorUd = @ptrCast(@alignCast(mem));
    return ud.ptr;
}

// ---------------------------------------------------------------------------
// Vector2
// ---------------------------------------------------------------------------

fn vec2New(L: *lua.lua_State) callconv(.c) c_int {
    const x: f32 = @floatCast(lua.luaL_optnumber(L, 1, 0));
    const y: f32 = @floatCast(lua.luaL_optnumber(L, 2, 0));
    pushVec2Owned(L, Vec2.init(x, y));
    return 1;
}

fn vec2Gc(L: *lua.lua_State) callconv(.c) c_int {
    const mem = lua.lua_touserdata(L, 1) orelse return 0;
    const ud: *Vec2Ud = @ptrCast(@alignCast(mem));
    if (ud.owned) getEngine(L).allocator.destroy(ud.ptr);
    return 0;
}

fn vec2Index(L: *lua.lua_State) callconv(.c) c_int {
    const v = checkVec2Ptr(L, 1);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "x")) {
        lua.lua_pushnumber(L, v.x);
        return 1;
    } else if (std.mem.eql(u8, key, "y")) {
        lua.lua_pushnumber(L, v.y);
        return 1;
    } else if (std.mem.eql(u8, key, "magnitude")) {
        lua.lua_pushnumber(L, v.length());
        return 1;
    } else if (std.mem.eql(u8, key, "normalized")) {
        pushVec2Owned(L, v.normalized());
        return 1;
    }
    return 0;
}

fn vec2NewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const v = checkVec2Ptr(L, 1);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    const value: f32 = @floatCast(lua.luaL_checknumber(L, 3));
    if (std.mem.eql(u8, key, "x")) {
        v.x = value;
        return 0;
    } else if (std.mem.eql(u8, key, "y")) {
        v.y = value;
        return 0;
    }
    return lua.luaL_error(L, "Vector2 has no field '%s'", key.ptr);
}

fn vec2BinOp(L: ?*lua.lua_State, comptime op: enum { add, sub, mul }) c_int {
    const a = checkVec2Ptr(L, 1);
    if (op == .mul and lua.lua_isnumber(L, 2) != 0) {
        const s: f32 = @floatCast(lua.lua_tonumber(L, 2));
        pushVec2Owned(L, Vec2.mulScalar(a.*, s));
        return 1;
    }
    const b = checkVec2Ptr(L, 2);
    pushVec2Owned(L, switch (op) {
        .add => Vec2.add(a.*, b.*),
        .sub => Vec2.sub(a.*, b.*),
        .mul => Vec2.init(a.x * b.x, a.y * b.y),
    });
    return 1;
}

fn vec2Add(L: *lua.lua_State) callconv(.c) c_int {
    return vec2BinOp(L, .add);
}
fn vec2Sub(L: *lua.lua_State) callconv(.c) c_int {
    return vec2BinOp(L, .sub);
}
fn vec2Mul(L: *lua.lua_State) callconv(.c) c_int {
    return vec2BinOp(L, .mul);
}

fn vec2Unm(L: *lua.lua_State) callconv(.c) c_int {
    const a = checkVec2Ptr(L, 1);
    pushVec2Owned(L, Vec2.init(-a.x, -a.y));
    return 1;
}

fn vec2Eq(L: *lua.lua_State) callconv(.c) c_int {
    const a = checkVec2Ptr(L, 1);
    const b = checkVec2Ptr(L, 2);
    lua.lua_pushboolean(L, @intFromBool(Vec2.eql(a.*, b.*)));
    return 1;
}

fn vec2ToString(L: *lua.lua_State) callconv(.c) c_int {
    const v = checkVec2Ptr(L, 1);
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "({d}, {d})", .{ v.x, v.y }) catch "Vector2";
    _ = lua.lua_pushlstring(L, s.ptr, s.len);
    return 1;
}

fn vec2Distance(L: *lua.lua_State) callconv(.c) c_int {
    const a = checkVec2Ptr(L, 1);
    const b = checkVec2Ptr(L, 2);
    lua.lua_pushnumber(L, Vec2.distance(a.*, b.*));
    return 1;
}

fn vec2Lerp(L: *lua.lua_State) callconv(.c) c_int {
    const a = checkVec2Ptr(L, 1);
    const b = checkVec2Ptr(L, 2);
    const t: f32 = @floatCast(lua.luaL_checknumber(L, 3));
    pushVec2Owned(L, Vec2.lerp(a.*, b.*, t));
    return 1;
}

/// Handles the `Vector2(x, y)` constructor call.
/// The callable table itself is argument #1, so x and y are at 2 and 3.
fn vec2TableCall(L: *lua.lua_State) callconv(.c) c_int {
    const x: f32 = @floatCast(lua.luaL_optnumber(L, 2, 0));
    const y: f32 = @floatCast(lua.luaL_optnumber(L, 3, 0));
    pushVec2Owned(L, Vec2.init(x, y));
    return 1;
}

/// Handles Vector2.zero / Vector2.up / ... statics (fresh value each time).
fn vec2TableIndex(L: *lua.lua_State) callconv(.c) c_int {
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "zero")) {
        pushVec2Owned(L, Vec2.zero);
        return 1;
    } else if (std.mem.eql(u8, key, "one")) {
        pushVec2Owned(L, Vec2.one);
        return 1;
    } else if (std.mem.eql(u8, key, "up")) {
        pushVec2Owned(L, Vec2.up);
        return 1;
    } else if (std.mem.eql(u8, key, "down")) {
        pushVec2Owned(L, Vec2.down);
        return 1;
    } else if (std.mem.eql(u8, key, "left")) {
        pushVec2Owned(L, Vec2.left);
        return 1;
    } else if (std.mem.eql(u8, key, "right")) {
        pushVec2Owned(L, Vec2.right);
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Color
// ---------------------------------------------------------------------------

fn colorNew(L: *lua.lua_State) callconv(.c) c_int {
    const r: f32 = @floatCast(lua.luaL_optnumber(L, 1, 0));
    const g: f32 = @floatCast(lua.luaL_optnumber(L, 2, 0));
    const b: f32 = @floatCast(lua.luaL_optnumber(L, 3, 0));
    const a: f32 = @floatCast(lua.luaL_optnumber(L, 4, 1));
    pushColorOwned(L, Color.init(r, g, b, a));
    return 1;
}

fn colorGc(L: *lua.lua_State) callconv(.c) c_int {
    const mem = lua.lua_touserdata(L, 1) orelse return 0;
    const ud: *ColorUd = @ptrCast(@alignCast(mem));
    if (ud.owned) getEngine(L).allocator.destroy(ud.ptr);
    return 0;
}

fn colorIndex(L: *lua.lua_State) callconv(.c) c_int {
    const c = checkColorPtr(L, 1);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "r")) {
        lua.lua_pushnumber(L, c.r);
        return 1;
    } else if (std.mem.eql(u8, key, "g")) {
        lua.lua_pushnumber(L, c.g);
        return 1;
    } else if (std.mem.eql(u8, key, "b")) {
        lua.lua_pushnumber(L, c.b);
        return 1;
    } else if (std.mem.eql(u8, key, "a")) {
        lua.lua_pushnumber(L, c.a);
        return 1;
    }
    return 0;
}

fn colorNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const c = checkColorPtr(L, 1);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    const value: f32 = @floatCast(lua.luaL_checknumber(L, 3));
    if (std.mem.eql(u8, key, "r")) {
        c.r = value;
        return 0;
    } else if (std.mem.eql(u8, key, "g")) {
        c.g = value;
        return 0;
    } else if (std.mem.eql(u8, key, "b")) {
        c.b = value;
        return 0;
    } else if (std.mem.eql(u8, key, "a")) {
        c.a = value;
        return 0;
    }
    return lua.luaL_error(L, "Color has no field '%s'", key.ptr);
}

/// Handles the `Color(r, g, b, a)` constructor call; the table is arg #1.
fn colorTableCall(L: *lua.lua_State) callconv(.c) c_int {
    const r: f32 = @floatCast(lua.luaL_optnumber(L, 2, 0));
    const g: f32 = @floatCast(lua.luaL_optnumber(L, 3, 0));
    const b: f32 = @floatCast(lua.luaL_optnumber(L, 4, 0));
    const a: f32 = @floatCast(lua.luaL_optnumber(L, 5, 1));
    pushColorOwned(L, Color.init(r, g, b, a));
    return 1;
}

fn colorTableIndex(L: *lua.lua_State) callconv(.c) c_int {
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    const statics = .{
        .{ "white", Color.white }, .{ "black", Color.black },
        .{ "red", Color.red },     .{ "green", Color.green },
        .{ "blue", Color.blue },   .{ "yellow", Color.yellow },
        .{ "cyan", Color.cyan },   .{ "magenta", Color.magenta },
        .{ "gray", Color.gray },   .{ "clear", Color.clear },
    };
    inline for (statics) |entry| {
        if (std.mem.eql(u8, key, entry[0])) {
            pushColorOwned(L, entry[1]);
            return 1;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Transform
// ---------------------------------------------------------------------------

fn transformIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkTransform(L, 1);
    const t = resolveTransform(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "position")) {
        pushVec2View(L, &t.position);
        return 1;
    } else if (std.mem.eql(u8, key, "rotation")) {
        lua.lua_pushnumber(L, t.rotation);
        return 1;
    } else if (std.mem.eql(u8, key, "scale")) {
        pushVec2View(L, &t.scale);
        return 1;
    } else if (std.mem.eql(u8, key, "gameObject")) {
        pushGameObjectFromUd(L, ud);
        return 1;
    }
    return 0;
}

fn transformNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkTransform(L, 1);
    const t = resolveTransform(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "position")) {
        const v = checkVec2Ptr(L, 3);
        t.position = v.*;
        return 0;
    } else if (std.mem.eql(u8, key, "rotation")) {
        t.rotation = @floatCast(lua.luaL_checknumber(L, 3));
        return 0;
    } else if (std.mem.eql(u8, key, "scale")) {
        const v = checkVec2Ptr(L, 3);
        t.scale = v.*;
        return 0;
    }
    return lua.luaL_error(L, "Transform has no field '%s'", key.ptr);
}

// ---------------------------------------------------------------------------
// SpriteRenderer
// ---------------------------------------------------------------------------

fn spriteIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkSpriteRenderer(L, 1);
    const sr = resolveSpriteRenderer(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "color")) {
        pushColorView(L, &sr.color);
        return 1;
    } else if (std.mem.eql(u8, key, "size")) {
        pushVec2View(L, &sr.size);
        return 1;
    } else if (std.mem.eql(u8, key, "shape")) {
        _ = lua.lua_pushstring(L, if (sr.shape == .quad) "Quad" else "Circle");
        return 1;
    } else if (std.mem.eql(u8, key, "visible")) {
        lua.lua_pushboolean(L, @intFromBool(sr.visible));
        return 1;
    } else if (std.mem.eql(u8, key, "sprite")) {
        if (sr.sprite) |s| {
            pushSprite(L, s);
            return 1;
        }
        return 0;
    } else if (std.mem.eql(u8, key, "flipX")) {
        lua.lua_pushboolean(L, @intFromBool(sr.flip_x));
        return 1;
    } else if (std.mem.eql(u8, key, "flipY")) {
        lua.lua_pushboolean(L, @intFromBool(sr.flip_y));
        return 1;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        lua.lua_pushnumber(L, @floatFromInt(sr.sorting_order));
        return 1;
    } else if (std.mem.eql(u8, key, "drawMode")) {
        _ = lua.lua_pushstring(L, if (sr.draw_mode == .sliced) "Sliced" else "Simple");
        return 1;
    } else if (std.mem.eql(u8, key, "gameObject")) {
        pushGameObjectFromUd(L, ud);
        return 1;
    }
    return 0;
}

fn spriteNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkSpriteRenderer(L, 1);
    const sr = resolveSpriteRenderer(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "color")) {
        const c = checkColorPtr(L, 3);
        sr.color = c.*;
        return 0;
    } else if (std.mem.eql(u8, key, "size")) {
        const v = checkVec2Ptr(L, 3);
        sr.size = v.*;
        return 0;
    } else if (std.mem.eql(u8, key, "shape")) {
        const s = std.mem.span(lua.luaL_checkstring(L, 3));
        if (std.mem.eql(u8, s, "Circle") or std.mem.eql(u8, s, "circle")) {
            sr.shape = .circle;
        } else {
            sr.shape = .quad;
        }
        return 0;
    } else if (std.mem.eql(u8, key, "visible")) {
        sr.visible = lua.lua_toboolean(L, 3) != 0;
        return 0;
    } else if (std.mem.eql(u8, key, "sprite")) {
        if (lua.lua_isnil(L, 3) != 0) {
            sr.setSprite(null);
        } else {
            const s = checkSprite(L, 3);
            sr.setSprite(s);
        }
        return 0;
    } else if (std.mem.eql(u8, key, "flipX")) {
        sr.flip_x = lua.lua_toboolean(L, 3) != 0;
        return 0;
    } else if (std.mem.eql(u8, key, "flipY")) {
        sr.flip_y = lua.lua_toboolean(L, 3) != 0;
        return 0;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        sr.sorting_order = @intFromFloat(lua.luaL_checknumber(L, 3));
        return 0;
    } else if (std.mem.eql(u8, key, "drawMode")) {
        const s = std.mem.span(lua.luaL_checkstring(L, 3));
        if (std.mem.eql(u8, s, "Sliced") or std.mem.eql(u8, s, "sliced")) {
            sr.draw_mode = .sliced;
        } else {
            sr.draw_mode = .simple;
        }
        return 0;
    }
    return lua.luaL_error(L, "SpriteRenderer has no field '%s'", key.ptr);
}

// ---------------------------------------------------------------------------
// Sprite (texture asset)
// ---------------------------------------------------------------------------

fn spriteAssetIndex(L: *lua.lua_State) callconv(.c) c_int {
    const s = checkSprite(L, 1);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "width")) {
        lua.lua_pushnumber(L, s.width);
        return 1;
    } else if (std.mem.eql(u8, key, "height")) {
        lua.lua_pushnumber(L, s.height);
        return 1;
    } else if (std.mem.eql(u8, key, "borderLeft")) {
        lua.lua_pushnumber(L, s.border_l);
        return 1;
    } else if (std.mem.eql(u8, key, "borderBottom")) {
        lua.lua_pushnumber(L, s.border_b);
        return 1;
    } else if (std.mem.eql(u8, key, "borderRight")) {
        lua.lua_pushnumber(L, s.border_r);
        return 1;
    } else if (std.mem.eql(u8, key, "borderTop")) {
        lua.lua_pushnumber(L, s.border_t);
        return 1;
    } else if (std.mem.eql(u8, key, "SetBorder")) {
        lua.lua_pushvalue(L, 2); // method name as upvalue
        lua.lua_pushcclosure(L, @ptrCast(&spriteAssetMethod), 1);
        return 1;
    }
    return 0;
}

fn spriteAssetNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const s = checkSprite(L, 1);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    const v: f32 = @floatCast(lua.luaL_checknumber(L, 3));
    if (std.mem.eql(u8, key, "borderLeft")) {
        s.border_l = v;
        return 0;
    } else if (std.mem.eql(u8, key, "borderBottom")) {
        s.border_b = v;
        return 0;
    } else if (std.mem.eql(u8, key, "borderRight")) {
        s.border_r = v;
        return 0;
    } else if (std.mem.eql(u8, key, "borderTop")) {
        s.border_t = v;
        return 0;
    }
    return lua.luaL_error(L, "Sprite has no field '%s'", key.ptr);
}

fn spriteAssetMethod(L: *lua.lua_State) callconv(.c) c_int {
    const s = checkSprite(L, 1);
    const l: f32 = @floatCast(lua.luaL_checknumber(L, 2));
    const b: f32 = @floatCast(lua.luaL_checknumber(L, 3));
    const r: f32 = @floatCast(lua.luaL_checknumber(L, 4));
    const t: f32 = @floatCast(lua.luaL_checknumber(L, 5));
    s.setBorder(l, b, r, t);
    return 0;
}

// ---------------------------------------------------------------------------
// TextMesh
// ---------------------------------------------------------------------------

fn textMeshIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkTextMesh(L, 1);
    const tm = resolveTextMesh(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "text")) {
        _ = lua.lua_pushlstring(L, tm.text.ptr, tm.text.len);
        return 1;
    } else if (std.mem.eql(u8, key, "fontSize")) {
        lua.lua_pushnumber(L, tm.font_size);
        return 1;
    } else if (std.mem.eql(u8, key, "color")) {
        pushColorView(L, &tm.color);
        return 1;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        lua.lua_pushnumber(L, @floatFromInt(tm.sorting_order));
        return 1;
    } else if (std.mem.eql(u8, key, "gameObject")) {
        pushGameObjectFromUd(L, ud);
        return 1;
    }
    return 0;
}

fn textMeshNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkTextMesh(L, 1);
    const tm = resolveTextMesh(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "text")) {
        const text = std.mem.span(lua.luaL_checkstring(L, 3));
        const e = getEngine(L);
        if (tm.text_owned) e.allocator.free(tm.text);
        tm.text = e.allocator.dupe(u8, text) catch return luaOom(L);
        tm.text_owned = true;
        return 0;
    } else if (std.mem.eql(u8, key, "fontSize")) {
        tm.font_size = @floatCast(lua.luaL_checknumber(L, 3));
        return 0;
    } else if (std.mem.eql(u8, key, "color")) {
        const c = checkColorPtr(L, 3);
        tm.color = c.*;
        return 0;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        tm.sorting_order = @intFromFloat(lua.luaL_checknumber(L, 3));
        return 0;
    }
    return lua.luaL_error(L, "TextMesh has no field '%s'", key.ptr);
}

// ---------------------------------------------------------------------------
// Colliders
// ---------------------------------------------------------------------------

fn boxColliderIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkCollider(L, 1);
    const c = resolveCollider(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "size")) {
        pushVec2View(L, &c.size);
        return 1;
    } else if (std.mem.eql(u8, key, "gameObject")) {
        pushGameObjectFromUd(L, ud);
        return 1;
    }
    return 0;
}

fn boxColliderNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkCollider(L, 1);
    const c = resolveCollider(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "size")) {
        const v = checkVec2Ptr(L, 3);
        c.size = v.*;
        return 0;
    }
    return lua.luaL_error(L, "BoxCollider2D has no field '%s'", key.ptr);
}

fn circleColliderIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkCircleCollider(L, 1);
    const c = resolveCollider(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "radius")) {
        lua.lua_pushnumber(L, c.radius);
        return 1;
    } else if (std.mem.eql(u8, key, "gameObject")) {
        pushGameObjectFromUd(L, ud);
        return 1;
    }
    return 0;
}

fn circleColliderNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkCircleCollider(L, 1);
    const c = resolveCollider(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "radius")) {
        c.radius = @floatCast(lua.luaL_checknumber(L, 3));
        return 0;
    }
    return lua.luaL_error(L, "CircleCollider2D has no field '%s'", key.ptr);
}

// ---------------------------------------------------------------------------
// UI components (UIImage / UIText / UIButton)
// ---------------------------------------------------------------------------

fn uiImageIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkUiImage(L, 1);
    const img = resolveUiImage(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "anchor")) {
        const s = anchorName(img.anchor);
        _ = lua.lua_pushlstring(L, s.ptr, s.len);
        return 1;
    } else if (std.mem.eql(u8, key, "offset")) {
        pushVec2View(L, &img.offset);
        return 1;
    } else if (std.mem.eql(u8, key, "size")) {
        pushVec2View(L, &img.size);
        return 1;
    } else if (std.mem.eql(u8, key, "color")) {
        pushColorView(L, &img.color);
        return 1;
    } else if (std.mem.eql(u8, key, "sprite")) {
        if (img.sprite) |s| {
            pushSprite(L, s);
            return 1;
        }
        return 0;
    } else if (std.mem.eql(u8, key, "drawMode")) {
        _ = lua.lua_pushstring(L, if (img.draw_mode == .sliced) "Sliced" else "Simple");
        return 1;
    } else if (std.mem.eql(u8, key, "visible")) {
        lua.lua_pushboolean(L, @intFromBool(img.visible));
        return 1;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        lua.lua_pushnumber(L, @floatFromInt(img.sorting_order));
        return 1;
    } else if (std.mem.eql(u8, key, "gameObject")) {
        pushGameObjectFromUd(L, ud);
        return 1;
    }
    return 0;
}

fn uiImageNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkUiImage(L, 1);
    const img = resolveUiImage(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "anchor")) {
        const s = std.mem.span(lua.luaL_checkstring(L, 3));
        if (anchorFromName(s)) |a| {
            img.anchor = a;
        } else {
            return lua.luaL_error(L, "unknown anchor '%s'", s.ptr);
        }
        return 0;
    } else if (std.mem.eql(u8, key, "offset")) {
        img.offset = checkVec2Ptr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "size")) {
        img.size = checkVec2Ptr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "color")) {
        img.color = checkColorPtr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "sprite")) {
        if (lua.lua_isnil(L, 3) != 0) {
            img.sprite = null;
        } else {
            img.sprite = checkSprite(L, 3);
        }
        return 0;
    } else if (std.mem.eql(u8, key, "drawMode")) {
        const s = std.mem.span(lua.luaL_checkstring(L, 3));
        img.draw_mode = if (std.mem.eql(u8, s, "Sliced") or std.mem.eql(u8, s, "sliced")) .sliced else .simple;
        return 0;
    } else if (std.mem.eql(u8, key, "visible")) {
        img.visible = lua.lua_toboolean(L, 3) != 0;
        return 0;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        img.sorting_order = @intFromFloat(lua.luaL_checknumber(L, 3));
        return 0;
    }
    return lua.luaL_error(L, "UIImage has no field '%s'", key.ptr);
}

fn uiTextIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkUiText(L, 1);
    const ut = resolveUiText(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "text")) {
        _ = lua.lua_pushlstring(L, ut.text.ptr, ut.text.len);
        return 1;
    } else if (std.mem.eql(u8, key, "fontSize")) {
        lua.lua_pushnumber(L, ut.font_size);
        return 1;
    } else if (std.mem.eql(u8, key, "color")) {
        pushColorView(L, &ut.color);
        return 1;
    } else if (std.mem.eql(u8, key, "anchor")) {
        const s = anchorName(ut.anchor);
        _ = lua.lua_pushlstring(L, s.ptr, s.len);
        return 1;
    } else if (std.mem.eql(u8, key, "offset")) {
        pushVec2View(L, &ut.offset);
        return 1;
    } else if (std.mem.eql(u8, key, "visible")) {
        lua.lua_pushboolean(L, @intFromBool(ut.visible));
        return 1;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        lua.lua_pushnumber(L, @floatFromInt(ut.sorting_order));
        return 1;
    } else if (std.mem.eql(u8, key, "gameObject")) {
        pushGameObjectFromUd(L, ud);
        return 1;
    }
    return 0;
}

fn uiTextNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkUiText(L, 1);
    const ut = resolveUiText(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "text")) {
        const text = std.mem.span(lua.luaL_checkstring(L, 3));
        ut.setText(getEngine(L).allocator, text) catch return luaOom(L);
        return 0;
    } else if (std.mem.eql(u8, key, "fontSize")) {
        ut.font_size = @floatCast(lua.luaL_checknumber(L, 3));
        return 0;
    } else if (std.mem.eql(u8, key, "color")) {
        ut.color = checkColorPtr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "anchor")) {
        const s = std.mem.span(lua.luaL_checkstring(L, 3));
        if (anchorFromName(s)) |a| {
            ut.anchor = a;
        } else {
            return lua.luaL_error(L, "unknown anchor '%s'", s.ptr);
        }
        return 0;
    } else if (std.mem.eql(u8, key, "offset")) {
        ut.offset = checkVec2Ptr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "visible")) {
        ut.visible = lua.lua_toboolean(L, 3) != 0;
        return 0;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        ut.sorting_order = @intFromFloat(lua.luaL_checknumber(L, 3));
        return 0;
    }
    return lua.luaL_error(L, "UIText has no field '%s'", key.ptr);
}

fn uiButtonIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkUiButton(L, 1);
    const b = resolveUiButton(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "label")) {
        _ = lua.lua_pushlstring(L, b.label.ptr, b.label.len);
        return 1;
    } else if (std.mem.eql(u8, key, "fontSize")) {
        lua.lua_pushnumber(L, b.font_size);
        return 1;
    } else if (std.mem.eql(u8, key, "size")) {
        pushVec2View(L, &b.size);
        return 1;
    } else if (std.mem.eql(u8, key, "anchor")) {
        const s = anchorName(b.anchor);
        _ = lua.lua_pushlstring(L, s.ptr, s.len);
        return 1;
    } else if (std.mem.eql(u8, key, "offset")) {
        pushVec2View(L, &b.offset);
        return 1;
    } else if (std.mem.eql(u8, key, "normalColor")) {
        pushColorView(L, &b.normal_color);
        return 1;
    } else if (std.mem.eql(u8, key, "hoverColor")) {
        pushColorView(L, &b.hover_color);
        return 1;
    } else if (std.mem.eql(u8, key, "pressedColor")) {
        pushColorView(L, &b.pressed_color);
        return 1;
    } else if (std.mem.eql(u8, key, "labelColor")) {
        pushColorView(L, &b.label_color);
        return 1;
    } else if (std.mem.eql(u8, key, "visible")) {
        lua.lua_pushboolean(L, @intFromBool(b.visible));
        return 1;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        lua.lua_pushnumber(L, @floatFromInt(b.sorting_order));
        return 1;
    } else if (std.mem.eql(u8, key, "hover")) {
        lua.lua_pushboolean(L, @intFromBool(b.hover));
        return 1;
    } else if (std.mem.eql(u8, key, "pressed")) {
        lua.lua_pushboolean(L, @intFromBool(b.pressed));
        return 1;
    } else if (std.mem.eql(u8, key, "gameObject")) {
        pushGameObjectFromUd(L, ud);
        return 1;
    }
    return 0;
}

fn uiButtonNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkUiButton(L, 1);
    const b = resolveUiButton(L, ud);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "label")) {
        const label = std.mem.span(lua.luaL_checkstring(L, 3));
        b.setLabel(getEngine(L).allocator, label) catch return luaOom(L);
        return 0;
    } else if (std.mem.eql(u8, key, "fontSize")) {
        b.font_size = @floatCast(lua.luaL_checknumber(L, 3));
        return 0;
    } else if (std.mem.eql(u8, key, "size")) {
        b.size = checkVec2Ptr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "anchor")) {
        const s = std.mem.span(lua.luaL_checkstring(L, 3));
        if (anchorFromName(s)) |a| {
            b.anchor = a;
        } else {
            return lua.luaL_error(L, "unknown anchor '%s'", s.ptr);
        }
        return 0;
    } else if (std.mem.eql(u8, key, "offset")) {
        b.offset = checkVec2Ptr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "normalColor")) {
        b.normal_color = checkColorPtr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "hoverColor")) {
        b.hover_color = checkColorPtr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "pressedColor")) {
        b.pressed_color = checkColorPtr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "labelColor")) {
        b.label_color = checkColorPtr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "visible")) {
        b.visible = lua.lua_toboolean(L, 3) != 0;
        return 0;
    } else if (std.mem.eql(u8, key, "sortingOrder")) {
        b.sorting_order = @intFromFloat(lua.luaL_checknumber(L, 3));
        return 0;
    } else if (std.mem.eql(u8, key, "onClick")) {
        if (b.on_click_ref != -1) {
            lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, b.on_click_ref);
            b.on_click_ref = -1;
        }
        if (lua.lua_isnil(L, 3) == 0) {
            lua.luaL_checktype(L, 3, lua.LUA_TFUNCTION);
            lua.lua_pushvalue(L, 3);
            b.on_click_ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);
        }
        return 0;
    }
    return lua.luaL_error(L, "UIButton has no field '%s'", key.ptr);
}

// ---------------------------------------------------------------------------
// GameObject
// ---------------------------------------------------------------------------

fn gameObjectIndex(L: *lua.lua_State) callconv(.c) c_int {
    const go = checkGameObject(L, 1);
    const world = go.world;
    const e = go.id.index;
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "transform")) {
        pushTransform(L, world, e);
        return 1;
    } else if (std.mem.eql(u8, key, "sprite")) {
        if (world.sprites.has(e)) {
            pushSpriteRenderer(L, world, e);
            return 1;
        }
        return 0;
    } else if (std.mem.eql(u8, key, "boxCollider")) {
        if (world.colliders.has(e)) {
            if (!world.colliders.at(e).is_circle) {
                pushBoxCollider(L, world, e);
                return 1;
            }
        }
        return 0;
    } else if (std.mem.eql(u8, key, "circleCollider")) {
        if (world.colliders.has(e)) {
            if (world.colliders.at(e).is_circle) {
                pushCircleCollider(L, world, e);
                return 1;
            }
        }
        return 0;
    } else if (std.mem.eql(u8, key, "textMesh")) {
        if (world.text_meshes.has(e)) {
            pushTextMesh(L, world, e);
            return 1;
        }
        return 0;
    } else if (std.mem.eql(u8, key, "name")) {
        const n = world.entities.items[e].name;
        _ = lua.lua_pushlstring(L, n.ptr, n.len);
        return 1;
    } else if (std.mem.eql(u8, key, "tag")) {
        if (world.entities.items[e].tag) |tag| {
            _ = lua.lua_pushlstring(L, tag.ptr, tag.len);
            return 1;
        }
        lua.lua_pushnil(L);
        return 1;
    } else if (std.mem.eql(u8, key, "active") or std.mem.eql(u8, key, "activeSelf")) {
        lua.lua_pushboolean(L, @intFromBool(world.entities.items[e].active));
        return 1;
    } else if (isGameObjectMethod(key)) {
        lua.lua_pushvalue(L, 2); // method name as upvalue
        lua.lua_pushcclosure(L, @ptrCast(&gameObjectMethod), 1);
        return 1;
    }
    return 0;
}

fn isGameObjectMethod(key: []const u8) bool {
    const methods = .{
        "AddSpriteRenderer", "AddBoxCollider2D", "AddCircleCollider2D",
        "AddTextMesh",       "AddScript",        "StartCoroutine",
        "SetActive",         "Destroy",          "GetComponent",
        "AddComponent",
    };
    inline for (methods) |m| {
        if (std.mem.eql(u8, key, m)) return true;
    }
    return false;
}

fn gameObjectNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const go = checkGameObject(L, 1);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "name")) {
        const new_name = std.mem.span(lua.luaL_checkstring(L, 3));
        go.setName(new_name) catch return luaOom(L);
        return 0;
    } else if (std.mem.eql(u8, key, "tag")) {
        if (lua.lua_isnil(L, 3) != 0) {
            go.setTag(null) catch return luaOom(L);
        } else {
            const t = std.mem.span(lua.luaL_checkstring(L, 3));
            go.setTag(t) catch return luaOom(L);
        }
        return 0;
    }
    return lua.luaL_error(L, "GameObject has no field '%s'", key.ptr);
}

fn gameObjectMethod(L: *lua.lua_State) callconv(.c) c_int {
    const go = checkGameObject(L, 1);
    const method_ptr = lua.lua_tostring(L, lua.lua_upvalueindex(1)) orelse return 0;
    const method = std.mem.span(method_ptr);
    if (std.mem.eql(u8, method, "AddSpriteRenderer")) {
        const sr = go.addSpriteRenderer() catch return luaOom(L);
        _ = sr;
        pushSpriteRenderer(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, method, "AddBoxCollider2D")) {
        const w: f32 = @floatCast(lua.luaL_checknumber(L, 2));
        const h: f32 = @floatCast(lua.luaL_checknumber(L, 3));
        const c = go.addBoxCollider(w, h) catch return luaOom(L);
        _ = c;
        pushBoxCollider(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, method, "AddCircleCollider2D")) {
        const r: f32 = @floatCast(lua.luaL_checknumber(L, 2));
        const c = go.addCircleCollider(r) catch return luaOom(L);
        _ = c;
        pushCircleCollider(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, method, "AddTextMesh")) {
        const tm = go.addTextMesh() catch return luaOom(L);
        _ = tm;
        pushTextMesh(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, method, "AddScript")) {
        lua.luaL_checktype(L, 2, lua.LUA_TTABLE);
        return gameObjectAddScriptTable(L, go, 2);
    } else if (std.mem.eql(u8, method, "AddComponent")) {
        return componentDispatch(L, go, 2);
    } else if (std.mem.eql(u8, method, "StartCoroutine")) {
        return gameObjectStartCoroutine(L);
    } else if (std.mem.eql(u8, method, "SetActive")) {
        go.setActive(lua.lua_toboolean(L, 2) != 0);
        return 0;
    } else if (std.mem.eql(u8, method, "Destroy")) {
        // Raw access: destroying an already-destroyed object is a no-op,
        // like Unity's Object.Destroy.
        const ud = checkGoUd(L, 1);
        ud.world.destroy(ud.id);
        return 0;
    } else if (std.mem.eql(u8, method, "GetComponent")) {
        return getComponentDispatch(L, go, 2);
    }
    return 0;
}

/// Shared component-add dispatch: go:AddComponent(name, ...) (name_idx=2)
/// and World.Add(entity, name, ...) (name_idx=3).
fn componentDispatch(L: *lua.lua_State, go: GameObject, name_idx: c_int) c_int {
    const name = std.mem.span(lua.luaL_checkstring(L, name_idx));
    if (std.mem.eql(u8, name, "Transform")) {
        pushTransform(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, name, "SpriteRenderer")) {
        _ = go.addSpriteRenderer() catch return luaOom(L);
        pushSpriteRenderer(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, name, "TextMesh")) {
        _ = go.addTextMesh() catch return luaOom(L);
        pushTextMesh(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, name, "BoxCollider2D")) {
        const w: f32 = @floatCast(lua.luaL_checknumber(L, name_idx + 1));
        const h: f32 = @floatCast(lua.luaL_checknumber(L, name_idx + 2));
        _ = go.addBoxCollider(w, h) catch return luaOom(L);
        pushBoxCollider(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, name, "CircleCollider2D")) {
        const r: f32 = @floatCast(lua.luaL_checknumber(L, name_idx + 1));
        _ = go.addCircleCollider(r) catch return luaOom(L);
        pushCircleCollider(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, name, "Script")) {
        lua.luaL_checktype(L, name_idx + 1, lua.LUA_TTABLE);
        return gameObjectAddScriptTable(L, go, name_idx + 1);
    } else if (std.mem.eql(u8, name, "UIImage")) {
        _ = go.world.images.set(go.id.index, .{}) catch return luaOom(L);
        pushUiImage(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, name, "UIText")) {
        _ = go.world.ui_texts.set(go.id.index, .{}) catch return luaOom(L);
        pushUiText(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, name, "UIButton")) {
        _ = go.world.buttons.set(go.id.index, .{}) catch return luaOom(L);
        pushUiButton(L, go.world, go.id.index);
        return 1;
    }
    return lua.luaL_error(L, "Unknown component type '%s'", name.ptr);
}

/// Shared component-get dispatch: go:GetComponent(name) and
/// World.Get(entity, name). Returns nil when the component is absent.
fn getComponentDispatch(L: *lua.lua_State, go: GameObject, name_idx: c_int) c_int {
    const name = std.mem.span(lua.luaL_checkstring(L, name_idx));
    if (std.mem.eql(u8, name, "Transform")) {
        pushTransform(L, go.world, go.id.index);
        return 1;
    } else if (std.mem.eql(u8, name, "SpriteRenderer")) {
        if (go.world.sprites.has(go.id.index)) {
            pushSpriteRenderer(L, go.world, go.id.index);
            return 1;
        }
    } else if (std.mem.eql(u8, name, "BoxCollider2D")) {
        if (go.world.colliders.has(go.id.index)) {
            if (!go.world.colliders.at(go.id.index).is_circle) {
                pushBoxCollider(L, go.world, go.id.index);
                return 1;
            }
        }
    } else if (std.mem.eql(u8, name, "CircleCollider2D")) {
        if (go.world.colliders.has(go.id.index)) {
            if (go.world.colliders.at(go.id.index).is_circle) {
                pushCircleCollider(L, go.world, go.id.index);
                return 1;
            }
        }
    } else if (std.mem.eql(u8, name, "TextMesh")) {
        if (go.world.text_meshes.has(go.id.index)) {
            pushTextMesh(L, go.world, go.id.index);
            return 1;
        }
    } else if (std.mem.eql(u8, name, "Script")) {
        if (go.world.scripts.get(go.id.index)) |sc| {
            if (sc.registry_ref != -1) {
                _ = lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, sc.registry_ref);
                return 1;
            }
        }
    } else if (std.mem.eql(u8, name, "UIImage")) {
        if (go.world.images.has(go.id.index)) {
            pushUiImage(L, go.world, go.id.index);
            return 1;
        }
    } else if (std.mem.eql(u8, name, "UIText")) {
        if (go.world.ui_texts.has(go.id.index)) {
            pushUiText(L, go.world, go.id.index);
            return 1;
        }
    } else if (std.mem.eql(u8, name, "UIButton")) {
        if (go.world.buttons.has(go.id.index)) {
            pushUiButton(L, go.world, go.id.index);
            return 1;
        }
    }
    return 0;
}

fn gameObjectToString(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkGoUd(L, 1);
    var buf: [160]u8 = undefined;
    const s = if (ud.world.isAlive(ud.id))
        std.fmt.bufPrint(&buf, "GameObject({s})", .{ud.world.entities.items[ud.id.index].name}) catch "GameObject"
    else
        "GameObject(destroyed)";
    _ = lua.lua_pushlstring(L, s.ptr, s.len);
    return 1;
}

fn gameObjectEq(L: *lua.lua_State) callconv(.c) c_int {
    const a = checkGoUd(L, 1);
    const b = checkGoUd(L, 2);
    lua.lua_pushboolean(L, @intFromBool(a.world == b.world and a.id.eql(b.id)));
    return 1;
}

fn gameObjectAddScriptTable(L: *lua.lua_State, go: GameObject, table_idx: c_int) c_int {
    const e = go.id.index;
    const sc = go.world.scripts.set(e, .{}) catch return luaOom(L);
    if (sc.registry_ref != -1) lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, sc.registry_ref);

    // script.gameObject / script.transform, like a MonoBehaviour component
    lua.lua_pushvalue(L, 1);
    lua.lua_setfield(L, table_idx, "gameObject");
    pushTransform(L, go.world, e);
    lua.lua_setfield(L, table_idx, "transform");

    // keep the table alive in the registry
    lua.lua_pushvalue(L, table_idx);
    sc.registry_ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);

    _ = lua.lua_getfield(L, table_idx, "Update");
    sc.has_update = lua.lua_isfunction(L, -1) != 0;
    lua.lua_pop(L, 1);

    // Start(), called once before the first Update
    _ = lua.lua_getfield(L, table_idx, "Start");
    if (lua.lua_isfunction(L, -1) != 0) {
        lua.lua_pushvalue(L, table_idx); // self
        if (lua.lua_pcall(L, 1, 0, 0) != lua.LUA_OK) printLuaError(L);
    } else {
        lua.lua_pop(L, 1);
    }
    return 0;
}

fn gameObjectStartCoroutine(L: *lua.lua_State) callconv(.c) c_int {
    lua.luaL_checktype(L, 2, lua.LUA_TFUNCTION);
    const host = getHost(L);

    const thread = lua.lua_newthread(L);
    lua.lua_pushvalue(L, 2); // the coroutine function
    _ = lua.lua_xmove(L, thread, 1);
    const ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    host.coroutines.append(host.engine.allocator, .{
        .ref = ref,
        .wait_until = host.engine.time,
        .done = false,
    }) catch return luaOom(L);
    return 0;
}

// ---------------------------------------------------------------------------
// Engine / Time / Input / Debug / Mathf / Physics2D globals
// ---------------------------------------------------------------------------

fn engineCreateGameObject(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const name = std.mem.span(lua.luaL_checkstring(L, 1));
    const go = e.createGameObject(name) catch return luaOom(L);
    pushGameObject(L, go);
    return 1;
}

fn engineFind(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const name = std.mem.span(lua.luaL_checkstring(L, 1));
    if (e.findGameObject(name)) |go| {
        pushGameObject(L, go);
        return 1;
    }
    lua.lua_pushnil(L);
    return 1;
}

fn engineFindWithTag(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const tag = std.mem.span(lua.luaL_checkstring(L, 1));
    if (e.findWithTag(tag)) |go| {
        pushGameObject(L, go);
        return 1;
    }
    lua.lua_pushnil(L);
    return 1;
}

/// Global `Destroy(go)`, like Unity's Object.Destroy. Destroying an
/// already-destroyed object is a no-op.
fn destroyGlobal(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkGoUd(L, 1);
    ud.world.destroy(ud.id);
    return 0;
}

// ---------------------------------------------------------------------------
// World: the canonical ECS facade for authoring scenes in Lua.
//   entity = World.Spawn(name)
//   comp   = World.Add(entity, "SpriteRenderer")
//   World.Get(entity, "Transform") / World.Has / World.Remove
//   for e, comp in World.Query("SpriteRenderer") do ... end
//   World.AddSystem(function(dt) ... end)  -- runs every frame
// ---------------------------------------------------------------------------

const QueryKind = enum(c_int) {
    sprite = 0,
    text_mesh = 1,
    collider = 2,
    script = 3,
    ui_image = 4,
    ui_text = 5,
    ui_button = 6,
};

fn checkWorldEntity(L: ?*lua.lua_State, idx: c_int) GameObject {
    const ud = checkGoUd(L, idx);
    if (!ud.world.isAlive(ud.id)) {
        _ = lua.luaL_error(L, "GameObject has been destroyed");
        unreachable;
    }
    return .{ .world = ud.world, .id = ud.id };
}

fn worldSpawn(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const name = std.mem.span(lua.luaL_checkstring(L, 1));
    const go = e.createGameObject(name) catch return luaOom(L);
    pushGameObject(L, go);
    return 1;
}

fn worldAdd(L: *lua.lua_State) callconv(.c) c_int {
    return componentDispatch(L, checkWorldEntity(L, 1), 2);
}

fn worldGet(L: *lua.lua_State) callconv(.c) c_int {
    return getComponentDispatch(L, checkWorldEntity(L, 1), 2);
}

fn worldRemove(L: *lua.lua_State) callconv(.c) c_int {
    const go = checkWorldEntity(L, 1);
    const name = std.mem.span(lua.luaL_checkstring(L, 2));
    const e = go.id.index;
    if (std.mem.eql(u8, name, "SpriteRenderer")) {
        go.world.sprites.clear(e);
    } else if (std.mem.eql(u8, name, "TextMesh")) {
        if (go.world.text_meshes.get(e)) |tm| {
            if (tm.text_owned) getEngine(L).allocator.free(tm.text);
        }
        go.world.text_meshes.clear(e);
    } else if (std.mem.eql(u8, name, "BoxCollider2D") or std.mem.eql(u8, name, "CircleCollider2D")) {
        go.world.colliders.clear(e);
    } else if (std.mem.eql(u8, name, "Script")) {
        if (go.world.scripts.get(e)) |sc| {
            if (sc.registry_ref != -1) lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, sc.registry_ref);
        }
        go.world.scripts.clear(e);
    } else if (std.mem.eql(u8, name, "UIImage")) {
        go.world.images.clear(e);
    } else if (std.mem.eql(u8, name, "UIText")) {
        if (go.world.ui_texts.get(e)) |ut| {
            if (ut.text_owned) getEngine(L).allocator.free(ut.text);
        }
        go.world.ui_texts.clear(e);
    } else if (std.mem.eql(u8, name, "UIButton")) {
        if (go.world.buttons.get(e)) |b| {
            if (b.label_owned) getEngine(L).allocator.free(b.label);
            if (b.on_click_ref != -1) lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, b.on_click_ref);
        }
        go.world.buttons.clear(e);
    } else if (std.mem.eql(u8, name, "Transform")) {
        return lua.luaL_error(L, "cannot remove Transform (every entity owns one)");
    } else {
        return lua.luaL_error(L, "Unknown component type '%s'", name.ptr);
    }
    return 0;
}

fn worldHas(L: *lua.lua_State) callconv(.c) c_int {
    const go = checkWorldEntity(L, 1);
    const name = std.mem.span(lua.luaL_checkstring(L, 2));
    const has: bool = if (std.mem.eql(u8, name, "Transform"))
        true
    else if (std.mem.eql(u8, name, "SpriteRenderer"))
        go.world.sprites.has(go.id.index)
    else if (std.mem.eql(u8, name, "TextMesh"))
        go.world.text_meshes.has(go.id.index)
    else if (std.mem.eql(u8, name, "BoxCollider2D") or std.mem.eql(u8, name, "CircleCollider2D"))
        go.world.colliders.has(go.id.index)
    else if (std.mem.eql(u8, name, "Script"))
        go.world.scripts.has(go.id.index)
    else if (std.mem.eql(u8, name, "UIImage"))
        go.world.images.has(go.id.index)
    else if (std.mem.eql(u8, name, "UIText"))
        go.world.ui_texts.has(go.id.index)
    else if (std.mem.eql(u8, name, "UIButton"))
        go.world.buttons.has(go.id.index)
    else
        false;
    lua.lua_pushboolean(L, @intFromBool(has));
    return 1;
}

fn worldEntityCount(L: *lua.lua_State) callconv(.c) c_int {
    lua.lua_pushinteger(L, getEngine(L).world.entity_count);
    return 1;
}

fn worldAddSystem(L: *lua.lua_State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, lua.LUA_TFUNCTION);
    const host = getHost(L);
    lua.lua_pushvalue(L, 1);
    const ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    host.systems.append(host.engine.allocator, ref) catch return luaOom(L);
    return 0;
}

fn worldDestroy(L: *lua.lua_State) callconv(.c) c_int {
    const ud = checkGoUd(L, 1);
    ud.world.destroy(ud.id);
    return 0;
}

/// `for entity, component in World.Query("SpriteRenderer") do ... end`
/// Returns a generic-for iterator closure that walks the storage bitmask.
fn worldQuery(L: *lua.lua_State) callconv(.c) c_int {
    const name = std.mem.span(lua.luaL_checkstring(L, 1));
    const kind: QueryKind = blk: {
        if (std.mem.eql(u8, name, "SpriteRenderer")) break :blk .sprite;
        if (std.mem.eql(u8, name, "TextMesh")) break :blk .text_mesh;
        if (std.mem.eql(u8, name, "BoxCollider2D") or std.mem.eql(u8, name, "CircleCollider2D")) break :blk .collider;
        if (std.mem.eql(u8, name, "Script")) break :blk .script;
        if (std.mem.eql(u8, name, "UIImage")) break :blk .ui_image;
        if (std.mem.eql(u8, name, "UIText")) break :blk .ui_text;
        if (std.mem.eql(u8, name, "UIButton")) break :blk .ui_button;
        return lua.luaL_error(L, "Unknown component type '%s'", name.ptr);
    };
    const e = getEngine(L);
    lua.lua_pushlightuserdata(L, @ptrCast(&e.world));
    lua.lua_pushinteger(L, 0); // iterator state: (word << 32) | bits
    lua.lua_pushinteger(L, @intFromEnum(kind));
    lua.lua_pushcclosure(L, @ptrCast(&worldQueryIter), 3);
    return 1;
}

fn worldQueryIter(L: *lua.lua_State) callconv(.c) c_int {
    const world_p = lua.lua_touserdata(L, lua.lua_upvalueindex(1)) orelse return 0;
    const world: *World = @ptrCast(@alignCast(world_p));
    const kind: QueryKind = @enumFromInt(@as(c_int, @intCast(lua.lua_tointeger(L, lua.lua_upvalueindex(3)))));
    const state: u64 = @intCast(lua.lua_tointeger(L, lua.lua_upvalueindex(2)));
    var word: u32 = @truncate(state >> 32);
    var bits: u32 = @truncate(state);

    const words: []const u32 = switch (kind) {
        .sprite => world.sprites.present.items,
        .text_mesh => world.text_meshes.present.items,
        .collider => world.colliders.present.items,
        .script => world.scripts.present.items,
        .ui_image => world.images.present.items,
        .ui_text => world.ui_texts.present.items,
        .ui_button => world.buttons.present.items,
    };

    while (true) {
        while (bits == 0) {
            if (word >= words.len) {
                lua.lua_pushnil(L);
                return 1;
            }
            bits = words[word];
            word += 1;
        }
        const b: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;
        const entity = (word - 1) * 32 + @as(u32, b);
        const info = world.entities.items[entity];
        if (!info.alive or info.marked_for_destroy) continue; // skip dying

        pushGameObject(L, .{ .world = world, .id = world.idOf(entity) });
        switch (kind) {
            .sprite => pushSpriteRenderer(L, world, entity),
            .text_mesh => pushTextMesh(L, world, entity),
            .collider => if (world.colliders.at(entity).is_circle)
                pushCircleCollider(L, world, entity)
            else
                pushBoxCollider(L, world, entity),
            .script => {
                const sc = world.scripts.at(entity);
                if (sc.registry_ref != -1) {
                    _ = lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, sc.registry_ref);
                } else {
                    lua.lua_pushnil(L);
                }
            },
            .ui_image => pushUiImage(L, world, entity),
            .ui_text => pushUiText(L, world, entity),
            .ui_button => pushUiButton(L, world, entity),
        }
        // persist iterator state in upvalue 2
        lua.lua_pushinteger(L, @as(lua.lua_Integer, @bitCast((@as(u64, word) << 32) | @as(u64, bits))));
        lua.lua_replace(L, lua.lua_upvalueindex(2));
        return 2;
    }
}

fn engineLoadSprite(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const path = std.mem.span(lua.luaL_checkstring(L, 1));
    const spr = e.loadSprite(path) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "LoadSprite '{s}' failed: {s}", .{ path, @errorName(err) }) catch "LoadSprite failed";
        return lua.luaL_error(L, msg.ptr);
    };
    pushSprite(L, spr);
    return 1;
}

fn engineOnUpdate(L: *lua.lua_State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, lua.LUA_TFUNCTION);
    const host = getHost(L);
    if (host.global_update_ref != -1) {
        lua.luaL_unref(L, lua.LUA_REGISTRYINDEX, host.global_update_ref);
    }
    lua.lua_pushvalue(L, 1);
    host.global_update_ref = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);
    return 0;
}

fn engineSetBackground(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    // Typed form: Engine.SetBackground(Color(...)); legacy form: 4 numbers.
    if (lua.lua_isuserdata(L, 1) != 0 and lua.luaL_testudata(L, 1, MT.color) != null) {
        e.background = checkColorPtr(L, 1).*;
        return 0;
    }
    const r: f32 = @floatCast(lua.luaL_checknumber(L, 1));
    const g: f32 = @floatCast(lua.luaL_checknumber(L, 2));
    const b: f32 = @floatCast(lua.luaL_checknumber(L, 3));
    const a: f32 = @floatCast(lua.luaL_optnumber(L, 4, 1));
    e.background = Color.init(r, g, b, a);
    return 0;
}

fn engineSetCameraPosition(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const v = checkVec2Ptr(L, 1);
    e.camera_position = v.*;
    return 0;
}

fn engineSetZoom(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const z: f32 = @floatCast(lua.luaL_checknumber(L, 1));
    e.setZoom(z);
    return 0;
}

fn engineQuit(L: *lua.lua_State) callconv(.c) c_int {
    getEngine(L).requestQuit();
    return 0;
}

fn engineCaptureScreenshot(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const path = std.mem.span(lua.luaL_checkstring(L, 1));
    if (e.screenshot_path) |old| e.allocator.free(old);
    e.screenshot_path = e.allocator.dupe(u8, path) catch return luaOom(L);
    e.pending_screenshot = true;
    return 0;
}

fn engineGenerateApi(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const path = std.mem.span(lua.luaL_checkstring(L, 1));
    e.generateLuaApi(path) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "GenerateApi failed: {s}", .{@errorName(err)}) catch "GenerateApi failed";
        return lua.luaL_error(L, msg.ptr);
    };
    return 0;
}

fn engineScreenSize(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    pushVec2Owned(L, Vec2.init(
        @floatFromInt(e.window.width),
        @floatFromInt(e.window.height),
    ));
    return 1;
}

fn engineTableIndex(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "screenWidth")) {
        lua.lua_pushnumber(L, @floatFromInt(e.window.width));
        return 1;
    } else if (std.mem.eql(u8, key, "screenHeight")) {
        lua.lua_pushnumber(L, @floatFromInt(e.window.height));
        return 1;
    } else if (std.mem.eql(u8, key, "zoom")) {
        lua.lua_pushnumber(L, e.zoom);
        return 1;
    } else if (std.mem.eql(u8, key, "background")) {
        pushColorView(L, &e.background);
        return 1;
    } else if (std.mem.eql(u8, key, "cameraPosition")) {
        pushVec2View(L, &e.camera_position);
        return 1;
    }
    return 0;
}

/// Typed writes on the Engine table: zoom (number), background (Color),
/// cameraPosition (Vector2). Anything else is rejected.
fn engineTableNewIndex(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "zoom")) {
        e.setZoom(@floatCast(lua.luaL_checknumber(L, 3)));
        return 0;
    } else if (std.mem.eql(u8, key, "background")) {
        e.background = checkColorPtr(L, 3).*;
        return 0;
    } else if (std.mem.eql(u8, key, "cameraPosition")) {
        e.camera_position = checkVec2Ptr(L, 3).*;
        return 0;
    }
    return lua.luaL_error(L, "Engine has no writable field '%s'", key.ptr);
}

fn inputGetKey(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const name = std.mem.span(lua.luaL_checkstring(L, 1));
    const vk = input_mod.vkFromName(name) orelse {
        lua.lua_pushboolean(L, 0);
        return 1;
    };
    lua.lua_pushboolean(L, @intFromBool(e.input.getKeyVk(vk)));
    return 1;
}

fn inputGetKeyDown(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const name = std.mem.span(lua.luaL_checkstring(L, 1));
    const vk = input_mod.vkFromName(name) orelse {
        lua.lua_pushboolean(L, 0);
        return 1;
    };
    lua.lua_pushboolean(L, @intFromBool(e.input.getKeyDownVk(vk)));
    return 1;
}

fn inputGetAxisRaw(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const name = std.mem.span(lua.luaL_checkstring(L, 1));
    var v: f32 = 0;
    if (std.mem.eql(u8, name, "Horizontal")) {
        v = e.input.getAxisRaw(true);
    } else if (std.mem.eql(u8, name, "Vertical")) {
        v = e.input.getAxisRaw(false);
    }
    lua.lua_pushnumber(L, v);
    return 1;
}

fn inputGetMouseButton(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const btn = lua.luaL_checkinteger(L, 1);
    lua.lua_pushboolean(L, @intFromBool(e.input.getMouseButton(@intCast(btn))));
    return 1;
}

fn inputGetMouseButtonDown(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const btn = lua.luaL_checkinteger(L, 1);
    lua.lua_pushboolean(L, @intFromBool(e.input.getMouseButtonDown(@intCast(btn))));
    return 1;
}

fn inputTableIndex(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const key = std.mem.span(lua.luaL_checkstring(L, 2));
    if (std.mem.eql(u8, key, "mousePosition")) {
        pushVec2View(L, &e.input.mouse);
        return 1;
    } else if (std.mem.eql(u8, key, "mouseScrollDelta")) {
        pushVec2View(L, &e.input.mouse_scroll);
        return 1;
    }
    return 0;
}

fn debugLog(L: *lua.lua_State) callconv(.c) c_int {
    return debugLogImpl(L, "[Lua] ");
}

fn debugLogWarning(L: *lua.lua_State) callconv(.c) c_int {
    return debugLogImpl(L, "[Lua warning] ");
}

fn debugLogError(L: *lua.lua_State) callconv(.c) c_int {
    return debugLogImpl(L, "[Lua error] ");
}

fn debugLogImpl(L: ?*lua.lua_State, prefix: []const u8) c_int {
    const e = getEngine(L);
    const n = lua.lua_gettop(L);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(e.allocator);
    buf.appendSlice(e.allocator, prefix) catch {};

    var i: c_int = 1;
    while (i <= n) : (i += 1) {
        if (i > 1) buf.appendSlice(e.allocator, " ") catch {};
        const s = lua.luaL_tolstring(L, i, null);
        buf.appendSlice(e.allocator, std.mem.span(s)) catch {};
        lua.lua_pop(L, 1);
    }
    std.debug.print("{s}\n", .{buf.items});
    return 0;
}

fn mathfClamp(L: *lua.lua_State) callconv(.c) c_int {
    const v: f32 = @floatCast(lua.luaL_checknumber(L, 1));
    const lo: f32 = @floatCast(lua.luaL_checknumber(L, 2));
    const hi: f32 = @floatCast(lua.luaL_checknumber(L, 3));
    lua.lua_pushnumber(L, types.Mathf.clamp(v, lo, hi));
    return 1;
}

fn mathfLerp(L: *lua.lua_State) callconv(.c) c_int {
    const a: f32 = @floatCast(lua.luaL_checknumber(L, 1));
    const b: f32 = @floatCast(lua.luaL_checknumber(L, 2));
    const t: f32 = @floatCast(lua.luaL_checknumber(L, 3));
    lua.lua_pushnumber(L, types.Mathf.lerp(a, b, t));
    return 1;
}

fn mathfUnary(L: ?*lua.lua_State, comptime kind: enum { abs, sin, cos, sqrt, floor, ceil }) c_int {
    const v: f32 = @floatCast(lua.luaL_checknumber(L, 1));
    const r = switch (kind) {
        .abs => types.Mathf.abs(v),
        .sin => types.Mathf.sin(v),
        .cos => types.Mathf.cos(v),
        .sqrt => types.Mathf.sqrt(v),
        .floor => types.Mathf.floor(v),
        .ceil => types.Mathf.ceil(v),
    };
    lua.lua_pushnumber(L, r);
    return 1;
}

fn mathfAbs(L: *lua.lua_State) callconv(.c) c_int {
    return mathfUnary(L, .abs);
}
fn mathfSin(L: *lua.lua_State) callconv(.c) c_int {
    return mathfUnary(L, .sin);
}
fn mathfCos(L: *lua.lua_State) callconv(.c) c_int {
    return mathfUnary(L, .cos);
}
fn mathfSqrt(L: *lua.lua_State) callconv(.c) c_int {
    return mathfUnary(L, .sqrt);
}
fn mathfFloor(L: *lua.lua_State) callconv(.c) c_int {
    return mathfUnary(L, .floor);
}
fn mathfCeil(L: *lua.lua_State) callconv(.c) c_int {
    return mathfUnary(L, .ceil);
}

fn mathfPow(L: *lua.lua_State) callconv(.c) c_int {
    const a: f32 = @floatCast(lua.luaL_checknumber(L, 1));
    const b: f32 = @floatCast(lua.luaL_checknumber(L, 2));
    lua.lua_pushnumber(L, types.Mathf.pow(a, b));
    return 1;
}

fn mathfMinMax(L: ?*lua.lua_State, comptime is_min: bool) c_int {
    const a: f32 = @floatCast(lua.luaL_checknumber(L, 1));
    const b: f32 = @floatCast(lua.luaL_checknumber(L, 2));
    lua.lua_pushnumber(L, if (is_min) types.Mathf.min(a, b) else types.Mathf.max(a, b));
    return 1;
}

fn mathfMin(L: *lua.lua_State) callconv(.c) c_int {
    return mathfMinMax(L, true);
}
fn mathfMax(L: *lua.lua_State) callconv(.c) c_int {
    return mathfMinMax(L, false);
}

fn mathfRandomRange(L: *lua.lua_State) callconv(.c) c_int {
    const lo: f32 = @floatCast(lua.luaL_checknumber(L, 1));
    const hi: f32 = @floatCast(lua.luaL_checknumber(L, 2));
    lua.lua_pushnumber(L, types.Mathf.randomRange(lo, hi));
    return 1;
}

fn physicsOverlapCircle(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const center = checkVec2Ptr(L, 1);
    const radius: f32 = @floatCast(lua.luaL_checknumber(L, 2));
    var ignore: ?GameObject = null;
    if (lua.lua_isuserdata(L, 3) != 0 and lua.luaL_testudata(L, 3, MT.game_object) != null) {
        const ud = checkGoUd(L, 3);
        ignore = .{ .world = ud.world, .id = ud.id };
    }
    if (e.overlapCircle(center.*, radius, ignore)) |hit| {
        pushGameObject(L, hit);
        return 1;
    }
    lua.lua_pushnil(L);
    return 1;
}

fn physicsOverlapBox(L: *lua.lua_State) callconv(.c) c_int {
    const e = getEngine(L);
    const center = checkVec2Ptr(L, 1);
    const half = checkVec2Ptr(L, 2);
    var ignore: ?GameObject = null;
    if (lua.lua_isuserdata(L, 3) != 0 and lua.luaL_testudata(L, 3, MT.game_object) != null) {
        const ud = checkGoUd(L, 3);
        ignore = .{ .world = ud.world, .id = ud.id };
    }
    if (e.overlapBox(center.*, half.*, ignore)) |hit| {
        pushGameObject(L, hit);
        return 1;
    }
    lua.lua_pushnil(L);
    return 1;
}

fn waitForSeconds(L: *lua.lua_State) callconv(.c) c_int {
    const s = lua.luaL_checknumber(L, 1);
    const mem = lua.lua_newuserdata(L, @sizeOf(f64)) orelse return luaOom(L);
    const p: *f64 = @ptrCast(@alignCast(mem));
    p.* = s;
    lua.luaL_setmetatable(L, MT.wait_seconds);
    return 1;
}

// ---------------------------------------------------------------------------
// registration
// ---------------------------------------------------------------------------

fn setMetatableField(L: ?*lua.lua_State, name: [*:0]const u8, comptime field: [:0]const u8, comptime func: anytype) void {
    _ = name;
    lua.lua_pushcfunction(L, @ptrCast(&func));
    lua.lua_setfield(L, -2, field);
}

fn registerVector2(L: ?*lua.lua_State) void {
    _ = lua.luaL_newmetatable(L, MT.vector2);
    setMetatableField(L, MT.vector2, "__index", vec2Index);
    setMetatableField(L, MT.vector2, "__newindex", vec2NewIndex);
    setMetatableField(L, MT.vector2, "__add", vec2Add);
    setMetatableField(L, MT.vector2, "__sub", vec2Sub);
    setMetatableField(L, MT.vector2, "__mul", vec2Mul);
    setMetatableField(L, MT.vector2, "__unm", vec2Unm);
    setMetatableField(L, MT.vector2, "__eq", vec2Eq);
    setMetatableField(L, MT.vector2, "__tostring", vec2ToString);
    setMetatableField(L, MT.vector2, "__gc", vec2Gc);
    lua.lua_pop(L, 1);
}

fn registerColor(L: ?*lua.lua_State) void {
    _ = lua.luaL_newmetatable(L, MT.color);
    setMetatableField(L, MT.color, "__index", colorIndex);
    setMetatableField(L, MT.color, "__newindex", colorNewIndex);
    setMetatableField(L, MT.color, "__gc", colorGc);
    lua.lua_pop(L, 1);
}

fn registerGameObject(L: ?*lua.lua_State) void {
    _ = lua.luaL_newmetatable(L, MT.game_object);
    setMetatableField(L, MT.game_object, "__index", gameObjectIndex);
    setMetatableField(L, MT.game_object, "__newindex", gameObjectNewIndex);
    setMetatableField(L, MT.game_object, "__tostring", gameObjectToString);
    setMetatableField(L, MT.game_object, "__eq", gameObjectEq);
    lua.lua_pop(L, 1);
}

fn registerTransform(L: ?*lua.lua_State) void {
    _ = lua.luaL_newmetatable(L, MT.transform);
    setMetatableField(L, MT.transform, "__index", transformIndex);
    setMetatableField(L, MT.transform, "__newindex", transformNewIndex);
    lua.lua_pop(L, 1);
}

fn registerSprite(L: ?*lua.lua_State) void {
    _ = lua.luaL_newmetatable(L, MT.sprite);
    setMetatableField(L, MT.sprite, "__index", spriteIndex);
    setMetatableField(L, MT.sprite, "__newindex", spriteNewIndex);
    lua.lua_pop(L, 1);

    _ = lua.luaL_newmetatable(L, MT.sprite_asset);
    setMetatableField(L, MT.sprite_asset, "__index", spriteAssetIndex);
    setMetatableField(L, MT.sprite_asset, "__newindex", spriteAssetNewIndex);
    lua.lua_pop(L, 1);

    _ = lua.luaL_newmetatable(L, MT.text_mesh);
    setMetatableField(L, MT.text_mesh, "__index", textMeshIndex);
    setMetatableField(L, MT.text_mesh, "__newindex", textMeshNewIndex);
    lua.lua_pop(L, 1);
}

fn registerColliders(L: ?*lua.lua_State) void {
    _ = lua.luaL_newmetatable(L, MT.box_collider);
    setMetatableField(L, MT.box_collider, "__index", boxColliderIndex);
    setMetatableField(L, MT.box_collider, "__newindex", boxColliderNewIndex);
    lua.lua_pop(L, 1);

    _ = lua.luaL_newmetatable(L, MT.circle_collider);
    setMetatableField(L, MT.circle_collider, "__index", circleColliderIndex);
    setMetatableField(L, MT.circle_collider, "__newindex", circleColliderNewIndex);
    lua.lua_pop(L, 1);
}

fn registerUi(L: ?*lua.lua_State) void {
    _ = lua.luaL_newmetatable(L, MT.ui_image);
    setMetatableField(L, MT.ui_image, "__index", uiImageIndex);
    setMetatableField(L, MT.ui_image, "__newindex", uiImageNewIndex);
    lua.lua_pop(L, 1);

    _ = lua.luaL_newmetatable(L, MT.ui_text);
    setMetatableField(L, MT.ui_text, "__index", uiTextIndex);
    setMetatableField(L, MT.ui_text, "__newindex", uiTextNewIndex);
    lua.lua_pop(L, 1);

    _ = lua.luaL_newmetatable(L, MT.ui_button);
    setMetatableField(L, MT.ui_button, "__index", uiButtonIndex);
    setMetatableField(L, MT.ui_button, "__newindex", uiButtonNewIndex);
    lua.lua_pop(L, 1);
}

fn registerWaitForSeconds(L: ?*lua.lua_State) void {
    _ = lua.luaL_newmetatable(L, MT.wait_seconds);
    lua.lua_pop(L, 1);
}

fn registerMetatables(L: ?*lua.lua_State) void {
    registerVector2(L);
    registerColor(L);
    registerGameObject(L);
    registerTransform(L);
    registerSprite(L);
    registerColliders(L);
    registerUi(L);
    registerWaitForSeconds(L);
}

const engine_fns = [_]lua.luaL_Reg{
    .{ .name = "CreateGameObject", .func = @ptrCast(&engineCreateGameObject) },
    .{ .name = "Find", .func = @ptrCast(&engineFind) },
    .{ .name = "FindWithTag", .func = @ptrCast(&engineFindWithTag) },
    .{ .name = "LoadSprite", .func = @ptrCast(&engineLoadSprite) },
    .{ .name = "OnUpdate", .func = @ptrCast(&engineOnUpdate) },
    .{ .name = "SetBackground", .func = @ptrCast(&engineSetBackground) },
    .{ .name = "SetCameraPosition", .func = @ptrCast(&engineSetCameraPosition) },
    .{ .name = "SetZoom", .func = @ptrCast(&engineSetZoom) },
    .{ .name = "ScreenSize", .func = @ptrCast(&engineScreenSize) },
    .{ .name = "CaptureScreenshot", .func = @ptrCast(&engineCaptureScreenshot) },
    .{ .name = "GenerateApi", .func = @ptrCast(&engineGenerateApi) },
    .{ .name = "Quit", .func = @ptrCast(&engineQuit) },
};

const gameobject_fns = [_]lua.luaL_Reg{
    .{ .name = "Find", .func = @ptrCast(&engineFind) },
    .{ .name = "FindWithTag", .func = @ptrCast(&engineFindWithTag) },
};

const world_fns = [_]lua.luaL_Reg{
    .{ .name = "Spawn", .func = @ptrCast(&worldSpawn) },
    .{ .name = "Add", .func = @ptrCast(&worldAdd) },
    .{ .name = "Get", .func = @ptrCast(&worldGet) },
    .{ .name = "Remove", .func = @ptrCast(&worldRemove) },
    .{ .name = "Has", .func = @ptrCast(&worldHas) },
    .{ .name = "Query", .func = @ptrCast(&worldQuery) },
    .{ .name = "AddSystem", .func = @ptrCast(&worldAddSystem) },
    .{ .name = "EntityCount", .func = @ptrCast(&worldEntityCount) },
    .{ .name = "Destroy", .func = @ptrCast(&worldDestroy) },
};

const input_fns = [_]lua.luaL_Reg{
    .{ .name = "GetKey", .func = @ptrCast(&inputGetKey) },
    .{ .name = "GetKeyDown", .func = @ptrCast(&inputGetKeyDown) },
    .{ .name = "GetAxisRaw", .func = @ptrCast(&inputGetAxisRaw) },
    .{ .name = "GetMouseButton", .func = @ptrCast(&inputGetMouseButton) },
    .{ .name = "GetMouseButtonDown", .func = @ptrCast(&inputGetMouseButtonDown) },
};

const debug_fns = [_]lua.luaL_Reg{
    .{ .name = "Log", .func = @ptrCast(&debugLog) },
    .{ .name = "LogWarning", .func = @ptrCast(&debugLogWarning) },
    .{ .name = "LogError", .func = @ptrCast(&debugLogError) },
};

const mathf_fns = [_]lua.luaL_Reg{
    .{ .name = "Clamp", .func = @ptrCast(&mathfClamp) },
    .{ .name = "Lerp", .func = @ptrCast(&mathfLerp) },
    .{ .name = "Abs", .func = @ptrCast(&mathfAbs) },
    .{ .name = "Sin", .func = @ptrCast(&mathfSin) },
    .{ .name = "Cos", .func = @ptrCast(&mathfCos) },
    .{ .name = "Sqrt", .func = @ptrCast(&mathfSqrt) },
    .{ .name = "Pow", .func = @ptrCast(&mathfPow) },
    .{ .name = "Min", .func = @ptrCast(&mathfMin) },
    .{ .name = "Max", .func = @ptrCast(&mathfMax) },
    .{ .name = "Floor", .func = @ptrCast(&mathfFloor) },
    .{ .name = "Ceil", .func = @ptrCast(&mathfCeil) },
    .{ .name = "RandomRange", .func = @ptrCast(&mathfRandomRange) },
};

const physics_fns = [_]lua.luaL_Reg{
    .{ .name = "OverlapCircle", .func = @ptrCast(&physicsOverlapCircle) },
    .{ .name = "OverlapBox", .func = @ptrCast(&physicsOverlapBox) },
};

const vector2_fns = [_]lua.luaL_Reg{
    .{ .name = "new", .func = @ptrCast(&vec2New) },
    .{ .name = "Distance", .func = @ptrCast(&vec2Distance) },
    .{ .name = "Lerp", .func = @ptrCast(&vec2Lerp) },
};

const color_fns = [_]lua.luaL_Reg{
    .{ .name = "new", .func = @ptrCast(&colorNew) },
};

fn registerGlobals(L: ?*lua.lua_State) void {
    // Engine table with __index (screenWidth/screenHeight)
    lua.registerLib(L, &engine_fns);
    _ = lua.luaL_newmetatable(L, MT.engine_table);
    setMetatableField(L, MT.engine_table, "__index", engineTableIndex);
    setMetatableField(L, MT.engine_table, "__newindex", engineTableNewIndex);
    _ = lua.lua_setmetatable(L, -2);
    lua.lua_setglobal(L, "Engine");

    // GameObject static table: GameObject.Find / GameObject.FindWithTag
    lua.registerLib(L, &gameobject_fns);
    lua.lua_setglobal(L, "GameObject");

    // World: the ECS facade — the canonical way to author scenes in Lua.
    lua.registerLib(L, &world_fns);
    lua.lua_setglobal(L, "World");

    // Global Destroy(obj), like Unity's Object.Destroy / Destroy(go).
    lua.lua_pushcfunction(L, @ptrCast(&destroyGlobal));
    lua.lua_setglobal(L, "Destroy");

    // Input table with __index (mousePosition)
    lua.registerLib(L, &input_fns);
    _ = lua.luaL_newmetatable(L, MT.input_table);
    setMetatableField(L, MT.input_table, "__index", inputTableIndex);
    _ = lua.lua_setmetatable(L, -2);
    lua.lua_setglobal(L, "Input");

    // Debug
    lua.registerLib(L, &debug_fns);
    lua.lua_setglobal(L, "Debug");

    // Mathf
    lua.registerLib(L, &mathf_fns);
    lua.lua_pushnumber(L, types.Mathf.pi);
    lua.lua_setfield(L, -2, "PI");
    lua.lua_setglobal(L, "Mathf");

    // Physics2D
    lua.registerLib(L, &physics_fns);
    lua.lua_setglobal(L, "Physics2D");

    // Time (updated every frame by LuaHost.update)
    lua.lua_createtable(L, 0, 3);
    lua.lua_pushnumber(L, 0);
    lua.lua_setfield(L, -2, "deltaTime");
    lua.lua_pushnumber(L, 0);
    lua.lua_setfield(L, -2, "time");
    lua.lua_pushnumber(L, 0);
    lua.lua_setfield(L, -2, "frameCount");
    lua.lua_setglobal(L, "Time");

    // Vector2 callable table: Vector2(x, y)
    lua.registerLib(L, &vector2_fns);
    lua.lua_createtable(L, 0, 2);
    setMetatableField(L, "Basic2D.Vector2Table", "__call", vec2TableCall);
    setMetatableField(L, "Basic2D.Vector2Table", "__index", vec2TableIndex);
    _ = lua.lua_setmetatable(L, -2);
    lua.lua_setglobal(L, "Vector2");

    // Color callable table: Color(r, g, b, a)
    lua.registerLib(L, &color_fns);
    lua.lua_createtable(L, 0, 2);
    setMetatableField(L, "Basic2D.ColorTable", "__call", colorTableCall);
    setMetatableField(L, "Basic2D.ColorTable", "__index", colorTableIndex);
    _ = lua.lua_setmetatable(L, -2);
    lua.lua_setglobal(L, "Color");

    // WaitForSeconds
    lua.lua_pushcfunction(L, @ptrCast(&waitForSeconds));
    lua.lua_setglobal(L, "WaitForSeconds");
}
