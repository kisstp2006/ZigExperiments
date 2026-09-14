//! Basic2D: a tiny Unity-inspired 2D game engine written in Zig.
//!
//! Unity 2D API subset mirrored here:
//!   GameObject / Transform / SpriteRenderer / BoxCollider2D / CircleCollider2D
//!   Time / Input / Physics2D / Debug / Vector2 / Color / Mathf
//!   MonoBehaviour-style Start/Update scripts + coroutines (Lua side)
//!
//! Architecture: a real ECS under the hood (engine/ecs.zig). Entities are
//! indices with generation counters; components live in per-type block
//! storages (SoA); the engine loop runs a small set of systems:
//!
//!   1. InputSystem     - pump Win32 messages, update Input state
//!   2. ScriptSystem    - Lua Update callbacks + coroutines (lua_host.zig)
//!   3. CleanupSystem   - release entities marked with Destroy()
//!   4. RenderSystem    - sort drawables, batch by texture, draw
//!
//! The GameObject/Component API on top (both in Zig and Lua) is Unity-like.
//!
//! Coordinates: one world unit == one pixel, origin bottom-left, Y up.

const std = @import("std");
const builtin = @import("builtin");

const win32 = @import("win32.zig");
const gl = @import("gl.zig");
const renderer_mod = @import("renderer.zig");
const input_mod = @import("input.zig");
const types = @import("types.zig");
const image_mod = @import("image.zig");
const text_mod = @import("text.zig");
const api_doc = @import("api_doc.zig");
pub const ecs = @import("ecs.zig");
pub const lua_host = @import("lua_host.zig");

pub const Vec2 = types.Vec2;
pub const Color = types.Color;
pub const Mathf = types.Mathf;
pub const Input = input_mod.Input;
pub const Key = input_mod.Key;
pub const Vertex = renderer_mod.Vertex;
pub const Texture = types.Texture;

// Component and ECS types live in ecs.zig; re-export them so `basic2d`
// keeps the same public surface.
pub const Shape = ecs.Shape;
pub const DrawMode = ecs.DrawMode;
pub const Sprite = ecs.Sprite;
pub const Transform = ecs.Transform;
pub const SpriteRenderer = ecs.SpriteRenderer;
pub const TextMesh = ecs.TextMesh;
pub const Collider2D = ecs.Collider2D;
pub const UIAnchor = ecs.UIAnchor;
pub const UIImage = ecs.UIImage;
pub const UIText = ecs.UIText;
pub const UIButton = ecs.UIButton;
pub const GameObject = ecs.GameObject;
pub const EntityId = ecs.EntityId;
pub const World = ecs.World;

pub const InitOptions = struct {
    title: []const u8 = "Basic2D",
    width: u32 = 800,
    height: u32 = 600,
};

const DrawEntry = struct {
    entity: u32,
    is_text: bool,
    order: i32,
};

/// Screen-space UI drawables, collected by the UI system and sorted by
/// order. Buttons emit two entries: the rect and its label.
const UiDrawEntry = struct {
    entity: u32,
    kind: enum { image, text, button, button_label },
    order: i32,
};

/// Stable insertion sort by sorting order (lists are tiny per frame).
fn sortDrawEntries(items: []DrawEntry) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j: usize = i;
        while (j > 0 and items[j - 1].order > key.order) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }
}

pub const Engine = struct {
    allocator: std.mem.Allocator,
    window: win32.Window,
    renderer: renderer_mod.Renderer,
    input: Input = .{},
    /// The ECS world: entities + component storages.
    world: ecs.World,
    vertex_scratch: std.ArrayList(Vertex) = .empty,
    draw_entries: std.ArrayList(DrawEntry) = .empty,
    ui_entries: std.ArrayList(UiDrawEntry) = .empty,

    /// All loaded textures/sprites, owned by the engine until shutdown.
    textures: std.ArrayList(*Texture) = .empty,
    sprites: std.ArrayList(*Sprite) = .empty,
    /// Built-in bitmap font atlas used by TextMesh components.
    font_atlas: *Texture,

    camera_position: Vec2 = .{},
    /// Camera zoom, like scaling Unity's orthographicSize: 1 = 1 unit per
    /// pixel; larger values zoom in.
    zoom: f32 = 1,
    background: Color = .{ .r = 0.12, .g = 0.12, .b = 0.14, .a = 1 },

    time: f64 = 0,
    delta_time: f32 = 0,
    frame_count: u64 = 0,
    quit_requested: bool = false,
    /// Auto-exit after N frames (used for CI/smoke testing).
    max_frames: ?u64 = null,
    /// When set, a screenshot is captured on the next rendered frame.
    screenshot_path: ?[]u8 = null,
    pending_screenshot: bool = false,
    quit_after_screenshot: bool = false,

    timer_freq: i64,
    last_counter: i64,
    lua: ?*lua_host.LuaHost = null,

    pub fn init(allocator: std.mem.Allocator, options: InitOptions) !Engine {
        if (builtin.os.tag != .windows) {
            @compileError("Basic2D currently supports Windows only (Win32 + WGL)");
        }
        const cli = parseCliArgs(allocator);
        errdefer if (cli.screenshot) |p| allocator.free(p);

        // `--generate-api <path>` writes the Lua API reference and exits.
        const api_generated = cli.generate_api != null;
        if (cli.generate_api) |p| {
            defer allocator.free(p);
            try api_doc.writeLuaApiFile(allocator, p);
        }

        var window = try win32.Window.create(options.title, options.width, options.height);
        errdefer window.deinit();

        gl.loadAll();
        gl.printInfo();
        var renderer = try renderer_mod.Renderer.init();
        errdefer renderer.deinit();

        const font_atlas = try allocator.create(Texture);
        errdefer allocator.destroy(font_atlas);
        font_atlas.* = try text_mod.buildAtlasTexture(allocator);
        errdefer gl.deleteTexture(font_atlas.id);

        return .{
            .allocator = allocator,
            .window = window,
            .renderer = renderer,
            .world = ecs.World.init(allocator),
            .font_atlas = font_atlas,
            .camera_position = Vec2.init(
                @as(f32, @floatFromInt(options.width)) / 2.0,
                @as(f32, @floatFromInt(options.height)) / 2.0,
            ),
            .max_frames = cli.max_frames,
            .screenshot_path = cli.screenshot,
            .quit_requested = api_generated,
            .timer_freq = win32.perfCounterFreq(),
            .last_counter = win32.perfCounterNow(),
        };
    }

    pub fn deinit(self: *Engine) void {
        if (self.lua) |lh| {
            lh.deinit();
            self.allocator.destroy(lh);
        }
        // Free TextMesh-owned strings before the storage blocks go away.
        var texts = self.world.text_meshes.iter();
        while (texts.next()) |item| {
            if (item.comp.text_owned) self.allocator.free(item.comp.text);
        }
        // UI elements own their strings too.
        var ui_texts = self.world.ui_texts.iter();
        while (ui_texts.next()) |item| {
            if (item.comp.text_owned) self.allocator.free(item.comp.text);
        }
        var ui_buttons = self.world.buttons.iter();
        while (ui_buttons.next()) |item| {
            if (item.comp.label_owned) self.allocator.free(item.comp.label);
        }
        self.world.deinit();
        for (self.sprites.items) |s| self.allocator.destroy(s);
        for (self.textures.items) |t| {
            gl.deleteTexture(t.id);
            self.allocator.destroy(t);
        }
        gl.deleteTexture(self.font_atlas.id);
        self.allocator.destroy(self.font_atlas);
        if (self.screenshot_path) |p| self.allocator.free(p);
        self.sprites.deinit(self.allocator);
        self.textures.deinit(self.allocator);
        self.vertex_scratch.deinit(self.allocator);
        self.draw_entries.deinit(self.allocator);
        self.ui_entries.deinit(self.allocator);
        self.renderer.deinit();
        self.window.deinit();
    }

    pub fn shouldClose(self: *Engine) bool {
        return self.window.should_close or self.quit_requested;
    }

    /// Sets the camera zoom, clamped to a sane range.
    pub fn setZoom(self: *Engine, zoom: f32) void {
        self.zoom = std.math.clamp(zoom, 0.1, 10.0);
    }

    pub fn requestQuit(self: *Engine) void {
        self.quit_requested = true;
    }

    /// Writes the full Lua API reference/stub file (safe to load; useful
    /// for editor autocompletion). Same output as `--generate-api <path>`.
    pub fn generateLuaApi(self: *Engine, path: []const u8) !void {
        try api_doc.writeLuaApiFile(self.allocator, path);
    }

    /// Advances one frame: pumps messages, updates input/time and runs the
    /// Lua scripts (if any). Returns the frame's delta time in seconds.
    pub fn update(self: *Engine) f32 {
        self.window.pumpMessages();

        const now = win32.perfCounterNow();
        const delta_ticks = now - self.last_counter;
        self.last_counter = now;
        var dt: f32 = @as(f32, @floatFromInt(delta_ticks)) / @as(f32, @floatFromInt(self.timer_freq));
        dt = std.math.clamp(dt, 0.0001, 0.25);
        self.delta_time = dt;
        self.time += dt;
        self.frame_count += 1;

        self.input.update(&self.window);

        // UISystem: hit-test buttons, track hover/pressed, fire clicks.
        self.uiInteractionSystem();

        // ScriptSystem: MonoBehaviour-style Update callbacks + coroutines.
        if (self.lua) |lh| lh.update(dt);

        // CleanupSystem: entities marked with Destroy() die now.
        self.cleanupSystem();

        if (self.input.getKeyDown(.escape)) self.requestQuit();
        if (self.max_frames) |max| {
            if (self.frame_count >= max) self.requestQuit();
        }
        if (self.quit_requested and self.screenshot_path != null and !self.pending_screenshot) {
            // Give the renderer one more frame so the back buffer contains
            // the final frame before it is captured.
            self.pending_screenshot = true;
            self.quit_after_screenshot = true;
            self.quit_requested = false;
        }
        return dt;
    }

    /// UISystem: hit-tests every UIButton with the mouse, tracks hover/
    /// pressed state, and fires clicks (Lua onClick + was_clicked flag).
    fn uiInteractionSystem(self: *Engine) void {
        const mouse = self.input.mouse;
        const down = self.input.getMouseButton(0);
        const w: f32 = @floatFromInt(self.window.width);
        const h: f32 = @floatFromInt(self.window.height);

        var it = self.world.buttons.iter();
        while (it.next()) |item| {
            const b = item.comp;
            b.was_clicked = false;
            const info = self.world.entities.items[item.entity];
            if (!info.active or info.marked_for_destroy or !b.visible) continue;

            const pos = uiAnchorPoint(b.anchor, w, h).add(b.offset);
            const inside = mouse.x >= pos.x - b.size.x * 0.5 and
                mouse.x <= pos.x + b.size.x * 0.5 and
                mouse.y >= pos.y - b.size.y * 0.5 and
                mouse.y <= pos.y + b.size.y * 0.5;

            if (inside and down and !b.pressed) b.pressed = true;
            if (b.pressed and !down) {
                b.pressed = false;
                if (inside) {
                    b.was_clicked = true;
                    if (b.on_click_ref != -1) {
                        if (self.lua) |lh| lh.fireUiCallback(b.on_click_ref);
                    }
                }
            }
            b.hover = inside and !b.pressed;
        }
    }

    /// Draws every visible active sprite/text and presents the frame.
    /// Drawables are sorted by sorting_order, then grouped by texture so
    /// each texture costs one draw call.
    pub fn render(self: *Engine) void {
        const scratch = &self.vertex_scratch;
        scratch.clearRetainingCapacity();
        self.renderer.beginFrame(self.window.width, self.window.height, self.background);

        // Collect drawables and sort them (stable) by sorting order.
        const entries = &self.draw_entries;
        entries.clearRetainingCapacity();

        var sprites = self.world.sprites.iter();
        while (sprites.next()) |item| {
            const e = item.entity;
            const info = self.world.entities.items[e];
            if (!info.active or info.marked_for_destroy) continue;
            const sr = item.comp;
            if (!sr.visible) continue;
            entries.append(self.allocator, .{ .entity = e, .is_text = false, .order = sr.sorting_order }) catch {};
        }
        var texts = self.world.text_meshes.iter();
        while (texts.next()) |item| {
            const e = item.entity;
            const info = self.world.entities.items[e];
            if (!info.active or info.marked_for_destroy) continue;
            const tm = item.comp;
            if (tm.text.len == 0) continue;
            entries.append(self.allocator, .{ .entity = e, .is_text = true, .order = tm.sorting_order }) catch {};
        }
        sortDrawEntries(entries.items);

        var current_tex: ?*Texture = null;
        var started = false;
        for (entries.items) |entry| {
            const e = entry.entity;
            if (entry.is_text) {
                const tm = self.world.text_meshes.at(e);
                const tex = self.font_atlas;
                if (!started or tex != current_tex) {
                    if (started) self.flushGroup(current_tex);
                    started = true;
                    current_tex = tex;
                }
                self.pushTextQuads(e, tm);
            } else {
                const sr = self.world.sprites.at(e);
                const tex: ?*Texture = if (sr.sprite) |s| s.texture else null;
                if (!started or tex != current_tex) {
                    if (started) self.flushGroup(current_tex);
                    started = true;
                    current_tex = tex;
                }
                self.pushSpriteQuads(e, sr);
            }
        }

        if (started) self.flushGroup(current_tex);

        // UISystem render pass: screen-space elements drawn after the
        // world, unaffected by the camera (zoom/position).
        self.renderUi();

        if (self.pending_screenshot) {
            if (self.screenshot_path) |p| self.captureScreenshot(p);
            self.pending_screenshot = false;
            if (self.quit_after_screenshot) {
                self.quit_after_screenshot = false;
                self.requestQuit();
            }
        }
        self.window.swap();
    }

    /// Captures the back buffer into a 24-bit BMP file, like Unity's
    /// ScreenCapture.CaptureScreenshot.
    pub fn captureScreenshot(self: *Engine, path: []const u8) void {
        const w = self.window.width;
        const h = self.window.height;
        const pixels = self.allocator.alloc(u8, w * h * 4) catch return;
        defer self.allocator.free(pixels);

        gl.glReadPixels(0, 0, @intCast(w), @intCast(h), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pixels.ptr);

        const row_size = ((w * 3 + 3) / 4) * 4;
        const data_size = row_size * h;
        const file_size = 54 + data_size;
        const file = self.allocator.alloc(u8, file_size) catch return;
        defer self.allocator.free(file);
        @memset(file, 0);
        file[0] = 'B';
        file[1] = 'M';
        std.mem.writeInt(u32, file[2..6], @intCast(file_size), .little);
        std.mem.writeInt(u32, file[10..14], 54, .little); // pixel data offset
        std.mem.writeInt(u32, file[14..18], 40, .little); // header size
        std.mem.writeInt(u32, file[18..22], w, .little);
        std.mem.writeInt(u32, file[22..26], h, .little);
        std.mem.writeInt(u16, file[26..28], 1, .little); // planes
        std.mem.writeInt(u16, file[28..30], 24, .little); // bpp
        std.mem.writeInt(u32, file[34..38], data_size, .little);

        // GL row 0 is the bottom of the window; BMP rows are bottom-up too.
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const src = pixels[y * w * 4 ..][0 .. w * 4];
            const dst = file[54 + y * row_size ..][0..row_size];
            for (0..w) |x| {
                dst[x * 3 + 0] = src[x * 4 + 2]; // B
                dst[x * 3 + 1] = src[x * 4 + 1]; // G
                dst[x * 3 + 2] = src[x * 4 + 0]; // R
            }
        }

        const GENERIC_WRITE: u32 = 0x40000000;
        const CREATE_ALWAYS: u32 = 2;
        const path_z = self.allocator.dupeZ(u8, path) catch return;
        defer self.allocator.free(path_z);
        const fh = win32.CreateFileA(path_z, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0x80, null) orelse return;
        defer _ = win32.CloseHandle(fh);
        var written: u32 = 0;
        _ = win32.WriteFile(fh, file.ptr, @intCast(file.len), &written, null);
        std.debug.print("screenshot saved: {s}\n", .{path});
    }

    fn flushGroup(self: *Engine, texture: ?*Texture) void {
        const tex_id: ?gl.GLuint = if (texture) |t| t.id else null;
        self.renderer.flush(
            self.vertex_scratch.items,
            self.window.width,
            self.window.height,
            self.camera_position,
            self.zoom,
            tex_id,
        );
        self.vertex_scratch.clearRetainingCapacity();
    }

    /// Flushes one UI texture group with a screen-space projection
    /// (camera centered on the window, zoom 1: world units == pixels).
    fn flushUiGroup(self: *Engine, texture: ?*Texture) void {
        const tex_id: ?gl.GLuint = if (texture) |t| t.id else null;
        self.renderer.flush(
            self.vertex_scratch.items,
            self.window.width,
            self.window.height,
            Vec2.init(
                @as(f32, @floatFromInt(self.window.width)) / 2.0,
                @as(f32, @floatFromInt(self.window.height)) / 2.0,
            ),
            1.0,
            tex_id,
        );
        self.vertex_scratch.clearRetainingCapacity();
    }

    /// Draws every visible UI element: anchored in screen space, sorted by
    /// sorting_order, grouped by texture.
    fn renderUi(self: *Engine) void {
        const w: f32 = @floatFromInt(self.window.width);
        const h: f32 = @floatFromInt(self.window.height);
        const entries = &self.ui_entries;
        entries.clearRetainingCapacity();

        var images = self.world.images.iter();
        while (images.next()) |item| {
            const img = item.comp;
            if (!img.visible) continue;
            entries.append(self.allocator, .{ .entity = item.entity, .kind = .image, .order = img.sorting_order }) catch {};
        }
        var texts = self.world.ui_texts.iter();
        while (texts.next()) |item| {
            const ut = item.comp;
            if (!ut.visible or ut.text.len == 0) continue;
            entries.append(self.allocator, .{ .entity = item.entity, .kind = .text, .order = ut.sorting_order }) catch {};
        }
        var buttons = self.world.buttons.iter();
        while (buttons.next()) |item| {
            const b = item.comp;
            if (!b.visible) continue;
            entries.append(self.allocator, .{ .entity = item.entity, .kind = .button, .order = b.sorting_order }) catch {};
            // The label rides one order above its own rect.
            entries.append(self.allocator, .{ .entity = item.entity, .kind = .button_label, .order = b.sorting_order + 1 }) catch {};
        }
        sortUiEntries(entries.items);

        var current_tex: ?*Texture = null;
        var started = false;
        for (entries.items) |entry| {
            const e = entry.entity;
            switch (entry.kind) {
                .image => {
                    const img = self.world.images.at(e);
                    const pos = uiAnchorPoint(img.anchor, w, h).add(img.offset);
                    const tex: ?*Texture = if (img.sprite) |s| s.texture else null;
                    if (!started or tex != current_tex) {
                        if (started) self.flushUiGroup(current_tex);
                        started = true;
                        current_tex = tex;
                    }
                    if (img.sprite != null and img.draw_mode == .sliced) {
                        var sr = SpriteRenderer{ .size = img.size, .color = img.color, .sprite = img.sprite };
                        self.pushSlicedQuadsAt(pos, 0, &sr);
                    } else {
                        self.pushRect(pos.x, pos.y, img.size.x, img.size.y, 0, 0, 1, 1, img.color, 0, 0, if (img.sprite != null) 1 else 0);
                    }
                },
                .text => {
                    const ut = self.world.ui_texts.at(e);
                    const pos = uiAnchorPoint(ut.anchor, w, h).add(ut.offset);
                    const tex = self.font_atlas;
                    if (!started or tex != current_tex) {
                        if (started) self.flushUiGroup(current_tex);
                        started = true;
                        current_tex = tex;
                    }
                    self.pushTextQuadsAt(pos, 0, ut.font_size, ut.color, ut.text);
                },
                .button => {
                    const b = self.world.buttons.at(e);
                    const pos = uiAnchorPoint(b.anchor, w, h).add(b.offset);
                    const color = if (b.pressed) b.pressed_color else if (b.hover) b.hover_color else b.normal_color;
                    const tex: ?*Texture = null;
                    if (!started or tex != current_tex) {
                        if (started) self.flushUiGroup(current_tex);
                        started = true;
                        current_tex = tex;
                    }
                    self.pushRect(pos.x, pos.y, b.size.x, b.size.y, 0, 0, 1, 1, color, 0, 0, 0);
                },
                .button_label => {
                    const b = self.world.buttons.at(e);
                    const pos = uiAnchorPoint(b.anchor, w, h).add(b.offset);
                    const tex = self.font_atlas;
                    if (!started or tex != current_tex) {
                        if (started) self.flushUiGroup(current_tex);
                        started = true;
                        current_tex = tex;
                    }
                    self.pushTextQuadsAt(pos, 0, b.font_size, b.label_color, b.label);
                },
            }
        }
        if (started) self.flushUiGroup(current_tex);
    }

    /// Anchor point in screen pixels (origin bottom-left, Y up).
    fn uiAnchorPoint(anchor: ecs.UIAnchor, w: f32, h: f32) Vec2 {
        const hw = w / 2.0;
        const hh = h / 2.0;
        return switch (anchor) {
            .top_left => .{ .x = 0, .y = h },
            .top_center => .{ .x = hw, .y = h },
            .top_right => .{ .x = w, .y = h },
            .middle_left => .{ .x = 0, .y = hh },
            .center => .{ .x = hw, .y = hh },
            .middle_right => .{ .x = w, .y = hh },
            .bottom_left => .{ .x = 0, .y = 0 },
            .bottom_center => .{ .x = hw, .y = 0 },
            .bottom_right => .{ .x = w, .y = 0 },
        };
    }

    /// Stable insertion sort for the tiny per-frame UI list.
    fn sortUiEntries(items: []UiDrawEntry) void {
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const key = items[i];
            var j: usize = i;
            while (j > 0 and items[j - 1].order > key.order) : (j -= 1) {
                items[j] = items[j - 1];
            }
            items[j] = key;
        }
    }

    fn pushSpriteQuads(self: *Engine, entity: u32, sr: *SpriteRenderer) void {
        if (sr.sprite != null and sr.draw_mode == .sliced) {
            self.pushSlicedQuads(entity, sr);
            return;
        }
        const textured = sr.sprite != null;
        const u_left: f32 = if (sr.flip_x and textured) 1 else 0;
        const u_right: f32 = if (sr.flip_x and textured) 0 else 1;
        const v_top: f32 = if (sr.flip_y and textured) 1 else 0;
        const v_bottom: f32 = if (sr.flip_y and textured) 0 else 1;
        const shape: f32 = if (sr.shape == .circle) 1 else 0;
        const t = self.world.transforms.at(entity);
        self.pushRect(
            t.position.x,
            t.position.y,
            sr.size.x,
            sr.size.y,
            u_left,
            v_top,
            u_right,
            v_bottom,
            sr.color,
            t.rotation,
            shape,
            if (textured) 1 else 0,
        );
    }

    /// Pushes one textured/solid rectangle as two triangles.
    /// uv order: (u_left, v_top, u_right, v_bottom); v = 0 is the image top.
    fn pushRect(
        self: *Engine,
        cx: f32,
        cy: f32,
        w: f32,
        h: f32,
        u_left: f32,
        v_top: f32,
        u_right: f32,
        v_bottom: f32,
        color: Color,
        rot: f32,
        shape: f32,
        tex_flag: f32,
    ) void {
        const corners = [6]Vec2{
            .{ .x = -1, .y = -1 },
            .{ .x = 1, .y = -1 },
            .{ .x = 1, .y = 1 },
            .{ .x = -1, .y = -1 },
            .{ .x = 1, .y = 1 },
            .{ .x = -1, .y = 1 },
        };
        const uvs = [6]Vec2{
            .{ .x = u_left, .y = v_bottom },
            .{ .x = u_right, .y = v_bottom },
            .{ .x = u_right, .y = v_top },
            .{ .x = u_left, .y = v_bottom },
            .{ .x = u_right, .y = v_top },
            .{ .x = u_left, .y = v_top },
        };
        for (corners, uvs) |c, uv| {
            self.vertex_scratch.append(self.allocator, .{
                .pos_x = cx,
                .pos_y = cy,
                .local_x = c.x,
                .local_y = c.y,
                .r = color.r,
                .g = color.g,
                .b = color.b,
                .a = color.a,
                .shape = shape,
                .rot = rot,
                .size_x = w,
                .size_y = h,
                .uv_x = uv.x,
                .uv_y = uv.y,
                .tex = tex_flag,
            }) catch {};
        }
    }

    /// 9-slice rendering, like Unity's Sliced draw mode: corners keep their
    /// pixel borders, edges stretch in one axis, the center stretches in both.
    fn pushSlicedQuads(self: *Engine, entity: u32, sr: *SpriteRenderer) void {
        const t = self.world.transforms.at(entity);
        self.pushSlicedQuadsAt(t.position, t.rotation, sr);
    }

    fn pushSlicedQuadsAt(self: *Engine, pos: Vec2, rot: f32, sr: *SpriteRenderer) void {
        const s = sr.sprite.?;
        const w = sr.size.x;
        const h = sr.size.y;
        const bl = s.border_l;
        const bb = s.border_b;
        const br = s.border_r;
        const bt = s.border_t;

        // Shrink borders proportionally when the target size is smaller
        // than the border sum (Unity behavior).
        const hs = bl + br;
        const vs = bb + bt;
        const sx: f32 = if (w < hs and hs > 0) w / hs else 1;
        const sy: f32 = if (h < vs and vs > 0) h / vs else 1;
        const wl = bl * sx;
        const wr = br * sx;
        const wb = bb * sy;
        const wt = bt * sy;
        const cw = w - wl - wr;
        const ch = h - wb - wt;

        const ubl = bl / s.width;
        const ubr = br / s.width;
        const vbt = bt / s.height;
        const vbb = bb / s.height;

        const x0 = pos.x - w / 2.0;
        const y0 = pos.y - h / 2.0;
        const xs = [3]f32{ wl, cw, wr };
        const ys = [3]f32{ wb, ch, wt };
        var px = x0;
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            var py = y0;
            var j: usize = 0;
            while (j < 3) : (j += 1) {
                if (xs[i] > 0.001 and ys[j] > 0.001) {
                    var ua: f32 = 0;
                    var ub: f32 = 0;
                    if (i == 0) {
                        ua = 0;
                        ub = ubl;
                    } else if (i == 1) {
                        ua = ubl;
                        ub = 1.0 - ubr;
                    } else {
                        ua = 1.0 - ubr;
                        ub = 1.0;
                    }
                    var va: f32 = 0;
                    var vb: f32 = 0;
                    if (j == 0) {
                        va = 0;
                        vb = vbt;
                    } else if (j == 1) {
                        va = vbt;
                        vb = 1.0 - vbb;
                    } else {
                        va = 1.0 - vbb;
                        vb = 1.0;
                    }
                    const u_left = if (sr.flip_x) 1.0 - ub else ua;
                    const u_right = if (sr.flip_x) 1.0 - ua else ub;
                    const v_top = if (sr.flip_y) 1.0 - vb else va;
                    const v_bottom = if (sr.flip_y) 1.0 - va else vb;
                    self.pushRect(
                        px + xs[i] / 2.0,
                        py + ys[j] / 2.0,
                        xs[i],
                        ys[j],
                        u_left,
                        v_top,
                        u_right,
                        v_bottom,
                        sr.color,
                        rot,
                        0,
                        1,
                    );
                }
                py += ys[j];
            }
            px += xs[i];
        }
    }

    fn pushTextQuads(self: *Engine, entity: u32, tm: *TextMesh) void {
        const t = self.world.transforms.at(entity);
        self.pushTextQuadsAt(t.position, t.rotation, tm.font_size, tm.color, tm.text);
    }

    fn pushTextQuadsAt(self: *Engine, pos: Vec2, rot: f32, font_size: f32, color: Color, text: []const u8) void {
        const advance = text_mod.glyphAdvance(font_size);

        // Count drawable glyphs first for horizontal centering.
        var count: usize = 0;
        for (text) |ch| {
            if (ch >= 32 and ch <= 126) count += 1;
        }
        if (count == 0) return;

        const total_width = @as(f32, @floatFromInt(count)) * advance;
        var i: usize = 0;
        for (text) |ch| {
            if (ch < 32 or ch > 126) continue;
            const uv = text_mod.glyphUv(ch).?;
            const cx = pos.x - total_width / 2.0 + (@as(f32, @floatFromInt(i)) + 0.5) * advance;
            const corners = [6]Vec2{
                .{ .x = -1, .y = -1 },
                .{ .x = 1, .y = -1 },
                .{ .x = 1, .y = 1 },
                .{ .x = -1, .y = -1 },
                .{ .x = 1, .y = 1 },
                .{ .x = -1, .y = 1 },
            };
            const uvs = [6]Vec2{
                .{ .x = uv[0], .y = uv[3] },
                .{ .x = uv[2], .y = uv[3] },
                .{ .x = uv[2], .y = uv[1] },
                .{ .x = uv[0], .y = uv[3] },
                .{ .x = uv[2], .y = uv[1] },
                .{ .x = uv[0], .y = uv[1] },
            };
            for (corners, uvs) |c, uvc| {
                self.vertex_scratch.append(self.allocator, .{
                    .pos_x = cx,
                    .pos_y = pos.y,
                    .local_x = c.x,
                    .local_y = c.y,
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = color.a,
                    .shape = 0,
                    .rot = rot,
                    .size_x = advance,
                    .size_y = font_size,
                    .uv_x = uvc.x,
                    .uv_y = uvc.y,
                    .tex = 1,
                }) catch {};
            }
            i += 1;
        }
    }

    // --- Scene management ---

    /// Loads an image file (BMP or PNG) as a Sprite, like Unity's
    /// Resources.Load<Sprite>(). Sprites live until engine shutdown.
    pub fn loadSprite(self: *Engine, path: []const u8) !*Sprite {
        var image = try image_mod.loadImage(self.allocator, path);
        defer image.deinit(self.allocator);

        const tex = try self.allocator.create(Texture);
        errdefer self.allocator.destroy(tex);
        tex.* = .{
            .id = try gl.createTextureRGBA(image.width, image.height, image.data, true),
            .width = image.width,
            .height = image.height,
        };
        errdefer gl.deleteTexture(tex.id);
        try self.textures.append(self.allocator, tex);

        const spr = try self.allocator.create(Sprite);
        spr.* = .{
            .texture = tex,
            .width = @floatFromInt(image.width),
            .height = @floatFromInt(image.height),
        };
        try self.sprites.append(self.allocator, spr);
        return spr;
    }

    /// Spawns an entity and returns its Unity-style GameObject handle.
    pub fn createGameObject(self: *Engine, name: []const u8) !GameObject {
        const id = try self.world.spawn(name);
        return .{ .world = &self.world, .id = id };
    }

    pub fn findGameObject(self: *Engine, name: []const u8) ?GameObject {
        for (self.world.entities.items, 0..) |*info, i| {
            if (!info.alive or info.marked_for_destroy) continue;
            if (std.mem.eql(u8, info.name, name)) return self.gameObjectAt(@intCast(i));
        }
        return null;
    }

    /// Like Unity's GameObject.FindWithTag.
    pub fn findWithTag(self: *Engine, tag: []const u8) ?GameObject {
        for (self.world.entities.items, 0..) |*info, i| {
            if (!info.alive or info.marked_for_destroy) continue;
            if (info.tag) |t| {
                if (std.mem.eql(u8, t, tag)) return self.gameObjectAt(@intCast(i));
            }
        }
        return null;
    }

    fn gameObjectAt(self: *Engine, entity: u32) GameObject {
        return .{
            .world = &self.world,
            .id = .{ .index = entity, .generation = self.world.entities.items[entity].generation },
        };
    }

    /// Like Unity's Object.Destroy. Actual removal happens at the end of
    /// the frame (CleanupSystem); stale handles fail safely via generations.
    pub fn destroy(self: *Engine, go: GameObject) void {
        self.world.destroy(go.id);
    }

    /// CleanupSystem: frees everything owned by marked-for-destroy entities.
    fn cleanupSystem(self: *Engine) void {
        var i: usize = 0;
        while (i < self.world.entities.items.len) : (i += 1) {
            const info = &self.world.entities.items[i];
            if (!info.alive or !info.marked_for_destroy) continue;
            const entity: u32 = @intCast(i);
            // TextMesh owns its string.
            if (self.world.text_meshes.get(entity)) |tm| {
                if (tm.text_owned) self.allocator.free(tm.text);
            }
            // Lua script tables live in the Lua registry.
            if (self.lua) |lh| lh.onDestroyEntity(entity);
            // UI elements own their strings + Lua onClick refs.
            if (self.world.ui_texts.get(entity)) |ut| {
                if (ut.text_owned) self.allocator.free(ut.text);
            }
            if (self.world.buttons.get(entity)) |b| {
                if (b.label_owned) self.allocator.free(b.label);
            }
            self.world.release(entity);
        }
    }

    // --- Physics2D queries (query only, no simulation) ---

    /// Returns the first active collider overlapping the circle,
    /// or null. `ignore` is skipped (pass the querying object itself).
    pub fn overlapCircle(self: *Engine, center: Vec2, radius: f32, ignore: ?GameObject) ?GameObject {
        var it = self.world.colliders.iter();
        while (it.next()) |item| {
            const e = item.entity;
            const info = self.world.entities.items[e];
            if (!info.alive or !info.active or info.marked_for_destroy) continue;
            if (ignore) |ig| {
                if (ig.id.index == e and ig.id.generation == info.generation) continue;
            }
            const col = item.comp;
            const pos = self.world.transforms.at(e).position;
            if (col.is_circle) {
                const rr = radius + col.radius;
                const dx = pos.x - center.x;
                const dy = pos.y - center.y;
                if (dx * dx + dy * dy <= rr * rr) return self.gameObjectAt(e);
            } else {
                const hx = col.size.x * 0.5;
                const hy = col.size.y * 0.5;
                const cx = std.math.clamp(center.x, pos.x - hx, pos.x + hx);
                const cy = std.math.clamp(center.y, pos.y - hy, pos.y + hy);
                const dx = cx - center.x;
                const dy = cy - center.y;
                if (dx * dx + dy * dy <= radius * radius) return self.gameObjectAt(e);
            }
        }
        return null;
    }

    /// Returns the first active collider overlapping the box centered at
    /// `center` with half extents `half`, or null.
    pub fn overlapBox(self: *Engine, center: Vec2, half: Vec2, ignore: ?GameObject) ?GameObject {
        var it = self.world.colliders.iter();
        while (it.next()) |item| {
            const e = item.entity;
            const info = self.world.entities.items[e];
            if (!info.alive or !info.active or info.marked_for_destroy) continue;
            if (ignore) |ig| {
                if (ig.id.index == e and ig.id.generation == info.generation) continue;
            }
            const col = item.comp;
            const pos = self.world.transforms.at(e).position;
            if (col.is_circle) {
                const cx = std.math.clamp(pos.x, center.x - half.x, center.x + half.x);
                const cy = std.math.clamp(pos.y, center.y - half.y, center.y + half.y);
                const dx = cx - pos.x;
                const dy = cy - pos.y;
                if (dx * dx + dy * dy <= col.radius * col.radius) return self.gameObjectAt(e);
            } else {
                const hx = col.size.x * 0.5;
                const hy = col.size.y * 0.5;
                const dx = @abs(pos.x - center.x);
                const dy = @abs(pos.y - center.y);
                if (dx <= half.x + hx and dy <= half.y + hy) return self.gameObjectAt(e);
            }
        }
        return null;
    }

    // --- Lua ---

    /// Starts the embedded Lua runtime with the given script source
    /// (the whole game, executed once like a Unity scene setup).
    pub fn startLua(self: *Engine, source: []const u8, chunkname: [:0]const u8) !void {
        if (self.lua != null) return error.LuaAlreadyRunning;
        const host = try self.allocator.create(lua_host.LuaHost);
        host.* = try lua_host.LuaHost.init(self, host);
        self.lua = host;
        try host.runChunk(source, chunkname);
    }
};

const CliArgs = struct {
    max_frames: ?u64 = null,
    screenshot: ?[]u8 = null,
    generate_api: ?[]u8 = null,
};

/// Decodes UTF-16 (WTF-16) into a freshly allocated UTF-8 string.
fn utf16ToUtf8Alloc(allocator: std.mem.Allocator, w: [*:0]const u16) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (w[i] != 0) : (i += 1) {
        var cp: u21 = w[i];
        if (cp >= 0xD800 and cp <= 0xDBFF and w[i + 1] >= 0xDC00 and w[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (w[i + 1] - 0xDC00);
            i += 1;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

/// Parses `--frames N` and `--screenshot <path>` from the command line.
fn parseCliArgs(allocator: std.mem.Allocator) CliArgs {
    var argc: c_int = 0;
    const argv = win32.CommandLineToArgvW(win32.GetCommandLineW(), &argc) orelse return .{};
    defer _ = win32.LocalFree(@ptrCast(argv));
    var result = CliArgs{};
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const arg = argv[i] orelse continue;
        if (win32.argIsFramesFlag(arg)) {
            if (i + 1 < @as(usize, @intCast(argc))) {
                const value = argv[i + 1] orelse continue;
                result.max_frames = win32.parseFramesValue(value);
                i += 1;
            }
        } else if (win32.argIsScreenshotFlag(arg)) {
            if (i + 1 < @as(usize, @intCast(argc))) {
                const value = argv[i + 1] orelse continue;
                result.screenshot = utf16ToUtf8Alloc(allocator, value) catch null;
                i += 1;
            }
        } else if (win32.argIsGenerateApiFlag(arg)) {
            if (i + 1 < @as(usize, @intCast(argc))) {
                const value = argv[i + 1] orelse continue;
                result.generate_api = utf16ToUtf8Alloc(allocator, value) catch null;
                i += 1;
            }
        }
    }
    return result;
}

/// Prints to stdout with a newline, like Unity's Debug.Log.
pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}
