//! Basic2D ECS core.
//!
//! Entities are plain indices (plus a generation counter so old handles
//! become invalid after slot reuse). Components live in per-type
//! `BlockStorage` arrays: a set of fixed-size blocks indexed by entity.
//! Blocks never move after allocation, so component pointers stay stable
//! for the lifetime of the engine while iteration is still cache-friendly
//! (one dense array per component type, like a single-archetype DOTS chunk).
//!
//! Systems are plain functions over `World` (see engine.zig: input,
//! scripts, cleanup and render systems).

const std = @import("std");
const types = @import("types.zig");

pub const Vec2 = types.Vec2;
pub const Color = types.Color;
pub const Texture = types.Texture;

/// A handle to an entity: a slot index plus a generation counter.
/// Comparing generations makes stale handles fail safely after the slot
/// has been reused.
pub const EntityId = struct {
    index: u32,
    generation: u32,

    pub fn eql(a: EntityId, b: EntityId) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

pub const Shape = enum {
    quad,
    circle,
};

/// Sprite drawing modes, like Unity's SpriteDrawMode (Simple/Sliced).
pub const DrawMode = enum {
    simple,
    sliced,
};

/// A texture-based sprite asset, like Unity's Sprite (holds a texture).
pub const Sprite = struct {
    texture: *Texture,
    width: f32,
    height: f32,
    /// 9-slice borders in texture pixels (left, bottom, right, top),
    /// like Unity's Sprite.border.
    border_l: f32 = 0,
    border_b: f32 = 0,
    border_r: f32 = 0,
    border_t: f32 = 0,

    pub fn setBorder(self: *Sprite, l: f32, b: f32, r: f32, t: f32) void {
        self.border_l = l;
        self.border_b = b;
        self.border_r = r;
        self.border_t = t;
    }
};

/// Component: position/rotation/scale. Every entity owns one.
pub const Transform = struct {
    position: Vec2 = .{},
    /// Rotation in radians.
    rotation: f32 = 0,
    scale: Vec2 = .{ .x = 1, .y = 1 },
};

/// Component: draws a solid or textured shape, like SpriteRenderer.
pub const SpriteRenderer = struct {
    color: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    /// Sprite size in world units (pixels).
    size: Vec2 = .{ .x = 1, .y = 1 },
    shape: Shape = .quad,
    visible: bool = true,
    /// Optional texture; null draws a solid-color quad/circle.
    sprite: ?*Sprite = null,
    /// Draw order, like Unity's SpriteRenderer.sortingOrder (higher on top).
    sorting_order: i32 = 0,
    /// Mirrors the sprite horizontally/vertically.
    flip_x: bool = false,
    flip_y: bool = false,
    /// Simple draws one quad; Sliced draws the sprite's 9-slice border.
    draw_mode: DrawMode = .simple,

    /// Assigns a sprite and sizes the renderer to its pixel dimensions,
    /// like Unity's SpriteRenderer.sprite setter. Override `size` afterwards.
    pub fn setSprite(self: *SpriteRenderer, s: ?*Sprite) void {
        self.sprite = s;
        if (s) |sp| self.size = Vec2.init(sp.width, sp.height);
    }
};

/// Component: text rendering, mirrors Unity's TextMesh.
pub const TextMesh = struct {
    /// UTF-8 text; freed when the entity is destroyed when `text_owned`.
    text: []const u8 = "Text",
    text_owned: bool = false,
    /// Text height in world units (pixels).
    font_size: f32 = 24,
    color: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    /// Draw order (higher on top).
    sorting_order: i32 = 0,

    pub fn setText(self: *TextMesh, allocator: std.mem.Allocator, text: []const u8) !void {
        if (self.text_owned) allocator.free(self.text);
        self.text = try allocator.dupe(u8, text);
        self.text_owned = true;
    }
};

/// Component: 2D collision shape (query only for now).
pub const Collider2D = struct {
    is_circle: bool = false,
    /// Circle radius (is_circle == true).
    radius: f32 = 1,
    /// Box full extents, width x height (is_circle == false).
    size: Vec2 = .{ .x = 1, .y = 1 },
};

/// Component: a Lua script table, like a MonoBehaviour. The registry ref
/// is opaque to the ECS; the Lua host owns the Lua state.
pub const ScriptComponent = struct {
    registry_ref: c_int = -1,
    has_update: bool = false,
};

// --- Screen-space UI components ------------------------------------------
// UI elements live on entities like any other component, but they are
// positioned with an anchor + pixel offset (Unity's RectTransform/anchors
// in miniature) and are drawn by the UI system AFTER the world, so the
// camera zoom/position does not affect them.

pub const UIAnchor = enum {
    top_left,
    top_center,
    top_right,
    middle_left,
    center,
    middle_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

/// Component: a solid or textured rectangle in screen space, like
/// Unity's UI Image.
pub const UIImage = struct {
    anchor: UIAnchor = .center,
    /// Pixels from the anchor point.
    offset: Vec2 = .{},
    size: Vec2 = .{ .x = 100, .y = 100 },
    color: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    sprite: ?*Sprite = null,
    draw_mode: DrawMode = .simple,
    visible: bool = true,
    sorting_order: i32 = 0,
};

/// Component: a screen-space text label, like Unity's UI Text.
pub const UIText = struct {
    anchor: UIAnchor = .center,
    offset: Vec2 = .{},
    text: []const u8 = "Text",
    text_owned: bool = false,
    font_size: f32 = 24,
    color: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    visible: bool = true,
    sorting_order: i32 = 0,

    pub fn setText(self: *UIText, allocator: std.mem.Allocator, text: []const u8) !void {
        if (self.text_owned) allocator.free(self.text);
        self.text = try allocator.dupe(u8, text);
        self.text_owned = true;
    }
};

/// Component: a clickable screen-space button, like Unity's UI Button.
/// The UI system hit-tests it with the mouse, tints it (normal/hover/
/// pressed) and fires the click callback.
pub const UIButton = struct {
    anchor: UIAnchor = .center,
    offset: Vec2 = .{},
    size: Vec2 = .{ .x = 160, .y = 48 },
    label: []const u8 = "Button",
    label_owned: bool = false,
    font_size: f32 = 24,
    label_color: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    normal_color: Color = .{ .r = 0.2, .g = 0.3, .b = 0.45, .a = 1 },
    hover_color: Color = .{ .r = 0.25, .g = 0.4, .b = 0.6, .a = 1 },
    pressed_color: Color = .{ .r = 0.15, .g = 0.2, .b = 0.35, .a = 1 },
    visible: bool = true,
    sorting_order: i32 = 0,
    /// Runtime state (owned by the UI system):
    hover: bool = false,
    pressed: bool = false,
    /// True for exactly one frame after a completed click (Zig systems
    /// can poll this; Lua can also use `onClick`).
    was_clicked: bool = false,
    /// Lua function ref for onClick (owned by the Lua host).
    on_click_ref: c_int = -1,

    pub fn setLabel(self: *UIButton, allocator: std.mem.Allocator, label: []const u8) !void {
        if (self.label_owned) allocator.free(self.label);
        self.label = try allocator.dupe(u8, label);
        self.label_owned = true;
    }
};

/// Per-entity state that is not a component (identity, name, lifecycle).
pub const EntityInfo = struct {
    generation: u32 = 0,
    alive: bool = false,
    name: []const u8 = &.{},
    /// Unity-style tag; nil/free-form string.
    tag: ?[]const u8 = null,
    active: bool = true,
    marked_for_destroy: bool = false,
};

/// Component storage: N fixed-size blocks of `block_len` slots each,
/// indexed by entity. Blocks are allocated once and never moved, so
/// `*T` pointers into storage stay valid until `deinit`.
pub fn BlockStorage(comptime T: type) type {
    return struct {
        const Self = @This();
        const block_len: u32 = 1024;

        allocator: std.mem.Allocator,
        blocks: std.ArrayList([]T) = .empty,
        /// Bitmask of present slots: one bit per entity index.
        present: std.ArrayList(u32) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.blocks.items) |blk| self.allocator.free(blk);
            self.blocks.deinit(self.allocator);
            self.present.deinit(self.allocator);
        }

        pub fn has(self: *const Self, entity: u32) bool {
            const w = entity / 32;
            if (w >= self.present.items.len) return false;
            const b: u5 = @intCast(entity % 32);
            return (self.present.items[w] >> b) & 1 != 0;
        }

        /// Returns the slot for `entity`, allocating its block if needed.
        /// Does NOT mark the component present.
        pub fn at(self: *Self, entity: u32) *T {
            const bi = entity / block_len;
            const si = entity % block_len;
            while (self.blocks.items.len <= bi) {
                const blk = self.allocator.alloc(T, block_len) catch
                    @panic("Basic2D ECS: out of memory");
                @memset(std.mem.sliceAsBytes(blk), 0);
                self.blocks.append(self.allocator, blk) catch
                    @panic("Basic2D ECS: out of memory");
            }
            return &self.blocks.items[bi][si];
        }

        /// Adds the component if absent (writing `value`), otherwise
        /// returns the existing one. Like Unity's AddComponent: a second
        /// call returns the component that is already there.
        pub fn set(self: *Self, entity: u32, value: T) !*T {
            if (self.has(entity)) return self.at(entity);
            const p = self.at(entity);
            p.* = value;
            const w = entity / 32;
            const b: u5 = @intCast(entity % 32);
            while (self.present.items.len <= w) {
                try self.present.append(self.allocator, 0);
            }
            self.present.items[w] |= @as(u32, 1) << b;
            return p;
        }

        pub fn get(self: *Self, entity: u32) ?*T {
            if (!self.has(entity)) return null;
            return self.at(entity);
        }

        /// Removes the component and zeroes its slot.
        pub fn clear(self: *Self, entity: u32) void {
            if (!self.has(entity)) return;
            const p = self.at(entity);
            @memset(std.mem.sliceAsBytes(p[0..1]), 0);
            const w = entity / 32;
            const b: u5 = @intCast(entity % 32);
            self.present.items[w] &= ~(@as(u32, 1) << b);
        }

        /// Iterates all present components: `entity` index + `comp` pointer.
        pub const Iter = struct {
            storage: *Self,
            word: usize = 0,
            bits: u32 = 0,

            pub fn next(self: *Iter) ?struct { entity: u32, comp: *T } {
                while (self.bits == 0) {
                    if (self.word >= self.storage.present.items.len) return null;
                    self.bits = self.storage.present.items[self.word];
                    self.word += 1;
                }
                const b: u5 = @intCast(@ctz(self.bits));
                self.bits &= self.bits - 1;
                const entity = @as(u32, @intCast(self.word - 1)) * 32 + @as(u32, b);
                return .{ .entity = entity, .comp = self.storage.at(entity) };
            }
        };

        pub fn iter(self: *Self) Iter {
            return .{ .storage = self };
        }
    };
}

/// The ECS world: all entities and all component storages.
pub const World = struct {
    allocator: std.mem.Allocator,
    entities: std.ArrayList(EntityInfo) = .empty,
    free_indices: std.ArrayList(u32) = .empty,

    transforms: BlockStorage(Transform),
    sprites: BlockStorage(SpriteRenderer),
    text_meshes: BlockStorage(TextMesh),
    colliders: BlockStorage(Collider2D),
    scripts: BlockStorage(ScriptComponent),

    images: BlockStorage(UIImage),
    ui_texts: BlockStorage(UIText),
    buttons: BlockStorage(UIButton),

    entity_count: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .transforms = BlockStorage(Transform).init(allocator),
            .sprites = BlockStorage(SpriteRenderer).init(allocator),
            .text_meshes = BlockStorage(TextMesh).init(allocator),
            .colliders = BlockStorage(Collider2D).init(allocator),
            .scripts = BlockStorage(ScriptComponent).init(allocator),
            .images = BlockStorage(UIImage).init(allocator),
            .ui_texts = BlockStorage(UIText).init(allocator),
            .buttons = BlockStorage(UIButton).init(allocator),
        };
    }

    pub fn deinit(self: *World) void {
        for (self.entities.items) |*info| {
            if (info.name.len > 0) self.allocator.free(info.name);
            if (info.tag) |t| self.allocator.free(t);
        }
        self.entities.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
        self.transforms.deinit();
        self.sprites.deinit();
        self.text_meshes.deinit();
        self.colliders.deinit();
        self.scripts.deinit();
        self.images.deinit();
        self.ui_texts.deinit();
        self.buttons.deinit();
    }

    pub fn spawn(self: *World, name: []const u8) !EntityId {
        const name_dup = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_dup);

        const index: u32 = if (self.free_indices.pop()) |i| i else blk: {
            try self.entities.append(self.allocator, .{});
            break :blk @intCast(self.entities.items.len - 1);
        };

        const info = &self.entities.items[index];
        info.* = .{
            .generation = info.generation +% 1,
            .alive = true,
            .name = name_dup,
        };
        // Every entity has a Transform, like every Unity GameObject.
        _ = try self.transforms.set(index, .{});
        self.entity_count += 1;
        return .{ .index = index, .generation = info.generation };
    }

    /// Marks an entity for destruction (like Unity's Object.Destroy):
    /// the cleanup system actually frees it at the end of the frame.
    pub fn destroy(self: *World, id: EntityId) void {
        if (!self.isAlive(id)) return;
        self.entities.items[id.index].marked_for_destroy = true;
    }

    pub fn isAlive(self: *const World, id: EntityId) bool {
        return self.isValid(id.index, id.generation);
    }

    /// Builds a full handle for a raw entity index (current generation).
    pub fn idOf(self: *const World, entity: u32) EntityId {
        return .{ .index = entity, .generation = self.entities.items[entity].generation };
    }

    // --- Generic component dispatch (flecs-style ecs_add/ecs_get) ---
    // This is the canonical ECS API for authoring scenes: spawn entities
    // and add typed components, then iterate the storages in systems.

    /// Adds `value` to the entity if the component is absent (returns the
    /// existing component otherwise), like flecs' `ecs_add` / Unity's
    /// `AddComponent`.
    pub fn add(self: *World, comptime T: type, id: EntityId, value: T) !*T {
        switch (T) {
            Transform => return self.transforms.set(id.index, value),
            SpriteRenderer => return self.sprites.set(id.index, value),
            TextMesh => return self.text_meshes.set(id.index, value),
            Collider2D => return self.colliders.set(id.index, value),
            ScriptComponent => return self.scripts.set(id.index, value),
            UIImage => return self.images.set(id.index, value),
            UIText => return self.ui_texts.set(id.index, value),
            UIButton => return self.buttons.set(id.index, value),
            else => @compileError("unknown ECS component type"),
        }
    }

    /// Returns the entity's component pointer, or null when absent.
    pub fn get(self: *World, comptime T: type, id: EntityId) ?*T {
        switch (T) {
            Transform => return self.transforms.get(id.index),
            SpriteRenderer => return self.sprites.get(id.index),
            TextMesh => return self.text_meshes.get(id.index),
            Collider2D => return self.colliders.get(id.index),
            ScriptComponent => return self.scripts.get(id.index),
            UIImage => return self.images.get(id.index),
            UIText => return self.ui_texts.get(id.index),
            UIButton => return self.buttons.get(id.index),
            else => @compileError("unknown ECS component type"),
        }
    }

    pub fn has(self: *World, comptime T: type, id: EntityId) bool {
        switch (T) {
            Transform => return self.transforms.has(id.index),
            SpriteRenderer => return self.sprites.has(id.index),
            TextMesh => return self.text_meshes.has(id.index),
            Collider2D => return self.colliders.has(id.index),
            ScriptComponent => return self.scripts.has(id.index),
            UIImage => return self.images.has(id.index),
            UIText => return self.ui_texts.has(id.index),
            UIButton => return self.buttons.has(id.index),
            else => @compileError("unknown ECS component type"),
        }
    }

    /// Removes the component and zeroes its storage slot.
    pub fn remove(self: *World, comptime T: type, id: EntityId) void {
        switch (T) {
            Transform => self.transforms.clear(id.index),
            SpriteRenderer => self.sprites.clear(id.index),
            TextMesh => self.text_meshes.clear(id.index),
            Collider2D => self.colliders.clear(id.index),
            ScriptComponent => self.scripts.clear(id.index),
            UIImage => self.images.clear(id.index),
            UIText => self.ui_texts.clear(id.index),
            UIButton => self.buttons.clear(id.index),
            else => @compileError("unknown ECS component type"),
        }
    }

    pub fn isValid(self: *const World, entity: u32, generation: u32) bool {
        if (entity >= self.entities.items.len) return false;
        const info = self.entities.items[entity];
        return info.alive and !info.marked_for_destroy and info.generation == generation;
    }

    pub fn nameOf(self: *const World, id: EntityId) []const u8 {
        return self.entities.items[id.index].name;
    }

    pub fn rename(self: *World, id: EntityId, name: []const u8) !void {
        if (!self.isAlive(id)) return;
        const new_name = try self.allocator.dupe(u8, name);
        self.allocator.free(self.entities.items[id.index].name);
        self.entities.items[id.index].name = new_name;
    }

    pub fn tagOf(self: *const World, id: EntityId) ?[]const u8 {
        return self.entities.items[id.index].tag;
    }

    pub fn setTag(self: *World, id: EntityId, tag: ?[]const u8) !void {
        if (!self.isAlive(id)) return;
        const info = &self.entities.items[id.index];
        if (info.tag) |old| self.allocator.free(old);
        info.tag = if (tag) |t| try self.allocator.dupe(u8, t) else null;
    }

    /// Frees a marked-for-destroy entity: strings, components, slot reuse.
    pub fn release(self: *World, entity: u32) void {
        const info = &self.entities.items[entity];
        if (info.name.len > 0) self.allocator.free(info.name);
        if (info.tag) |t| self.allocator.free(t);
        const generation = info.generation;
        info.* = .{ .generation = generation };
        self.transforms.clear(entity);
        self.sprites.clear(entity);
        self.text_meshes.clear(entity);
        self.colliders.clear(entity);
        self.scripts.clear(entity);
        self.images.clear(entity);
        self.ui_texts.clear(entity);
        self.buttons.clear(entity);
        self.free_indices.append(self.allocator, entity) catch {};
        self.entity_count -= 1;
    }
};

/// Unity-style GameObject facade over an entity. Value type: copying it
/// copies the handle, and `==` compares world + id like reference equality.
pub const GameObject = struct {
    world: *World,
    id: EntityId,

    pub fn isAlive(self: GameObject) bool {
        return self.world.isAlive(self.id);
    }

    /// Reference equality (Zig disallows `==` on structs holding pointers).
    pub fn eql(a: GameObject, b: GameObject) bool {
        return a.world == b.world and a.id.eql(b.id);
    }

    pub fn name(self: GameObject) []const u8 {
        return self.world.nameOf(self.id);
    }

    pub fn setName(self: GameObject, new_name: []const u8) !void {
        try self.world.rename(self.id, new_name);
    }

    pub fn tag(self: GameObject) ?[]const u8 {
        return self.world.tagOf(self.id);
    }

    /// Pass null to clear the tag.
    pub fn setTag(self: GameObject, new_tag: ?[]const u8) !void {
        try self.world.setTag(self.id, new_tag);
    }

    pub fn transform(self: GameObject) *Transform {
        return self.world.transforms.at(self.id.index);
    }

    pub fn addSpriteRenderer(self: GameObject) !*SpriteRenderer {
        return self.world.sprites.set(self.id.index, .{ .visible = true });
    }

    pub fn getSpriteRenderer(self: GameObject) ?*SpriteRenderer {
        return self.world.sprites.get(self.id.index);
    }

    pub fn addTextMesh(self: GameObject) !*TextMesh {
        return self.world.text_meshes.set(self.id.index, .{});
    }

    pub fn getTextMesh(self: GameObject) ?*TextMesh {
        return self.world.text_meshes.get(self.id.index);
    }

    pub fn addBoxCollider(self: GameObject, w: f32, h: f32) !*Collider2D {
        return self.world.colliders.set(self.id.index, .{
            .is_circle = false,
            .size = Vec2.init(w, h),
        });
    }

    pub fn addCircleCollider(self: GameObject, radius: f32) !*Collider2D {
        return self.world.colliders.set(self.id.index, .{
            .is_circle = true,
            .radius = radius,
        });
    }

    pub fn getCollider(self: GameObject) ?*Collider2D {
        return self.world.colliders.get(self.id.index);
    }

    pub fn setActive(self: GameObject, active: bool) void {
        if (!self.world.isAlive(self.id)) return;
        self.world.entities.items[self.id.index].active = active;
    }

    /// Like Unity's Object.Destroy: the object dies at the end of the frame.
    pub fn destroy(self: GameObject) void {
        self.world.destroy(self.id);
    }
};
