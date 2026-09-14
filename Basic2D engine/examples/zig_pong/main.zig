//! Pong in pure Zig on top of Basic2D's ECS — the canonical scene-authoring
//! path: entities + components via World.spawn/World.add, gameplay as plain
//! system functions that query the component storages.
const std = @import("std");
const basic2d = @import("basic2d");

const Vec2 = basic2d.Vec2;
const Color = basic2d.Color;
const World = basic2d.World;
const EntityId = basic2d.EntityId;
const Transform = basic2d.Transform;
const SpriteRenderer = basic2d.SpriteRenderer;
const Collider2D = basic2d.Collider2D;

/// Per-game state shared by the systems (systems are plain functions).
const GameState = struct {
    left: EntityId,
    right: EntityId,
    ball: EntityId,
    ball_vel: Vec2 = Vec2.init(320, 240),
    left_score: u32 = 0,
    right_score: u32 = 0,
    flash_timer: f32 = 0,
};

fn addSolidSprite(world: *World, id: EntityId, color: Color, size: Vec2, order: i32, shape: basic2d.Shape) !*SpriteRenderer {
    return world.add(SpriteRenderer, id, .{
        .color = color,
        .size = size,
        .shape = shape,
        .sorting_order = order,
    });
}

/// System: ball movement, wall bounce, scoring, paddle collision.
fn ballSystem(engine: *basic2d.Engine, state: *GameState, score_mesh: *basic2d.TextMesh, W: f32, H: f32, dt: f32) void {
    const world = &engine.world;
    const t = world.get(Transform, state.ball).?;
    t.position.x += state.ball_vel.x * dt;
    t.position.y += state.ball_vel.y * dt;

    if (t.position.y < 14) {
        t.position.y = 14;
        state.ball_vel.y = -state.ball_vel.y;
    } else if (t.position.y > H - 14) {
        t.position.y = H - 14;
        state.ball_vel.y = -state.ball_vel.y;
    }

    if (t.position.x < -40) {
        state.right_score += 1;
        basic2d.debugLog("Right scores!  {d} - {d}", .{ state.left_score, state.right_score });
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d} - {d}", .{ state.left_score, state.right_score }) catch "?";
        score_mesh.setText(engine.allocator, s) catch {};
        t.position = Vec2.init(W / 2, H / 2);
        state.ball_vel = Vec2.init(320, 240);
    } else if (t.position.x > W + 40) {
        state.left_score += 1;
        basic2d.debugLog("Left scores!  {d} - {d}", .{ state.left_score, state.right_score });
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d} - {d}", .{ state.left_score, state.right_score }) catch "?";
        score_mesh.setText(engine.allocator, s) catch {};
        t.position = Vec2.init(W / 2, H / 2);
        state.ball_vel = Vec2.init(320, 240);
    }

    if (engine.overlapCircle(t.position, 13, .{ .world = world, .id = state.ball })) |hit| {
        if (hit.id.eql(state.left) or hit.id.eql(state.right)) {
            const offset = (t.position.y - hit.transform().position.y) / 60.0;
            state.ball_vel.x = -state.ball_vel.x * 1.05;
            state.ball_vel.y = std.math.clamp(state.ball_vel.y + offset * 160.0, -520, 520);
            // Push out of the paddle so we don't re-hit next frame.
            t.position.x = if (hit.id.eql(state.left))
                world.get(Transform, state.left).?.position.x + 25
            else
                world.get(Transform, state.right).?.position.x - 25;
        }
    }
}

/// System: player paddle, AI paddle, mouse controls.
fn paddleSystem(engine: *basic2d.Engine, state: *GameState, H: f32, dt: f32) void {
    const world = &engine.world;
    const lt = world.get(Transform, state.left).?;
    const move = engine.input.getAxisRaw(false); // Vertical
    lt.position.y += 420 * move * dt;
    lt.position.y = std.math.clamp(lt.position.y, 60, H - 60);

    const rt = world.get(Transform, state.right).?;
    const ball_y = world.get(Transform, state.ball).?.position.y;
    const diff = ball_y - rt.position.y;
    rt.position.y += std.math.clamp(diff, -520 * dt, 520 * dt);
    rt.position.y = std.math.clamp(rt.position.y, 60, H - 60);

    if (engine.input.getMouseButtonDown(0)) {
        world.get(Transform, state.ball).?.position = engine.input.mouse;
    }
    if (engine.input.getMouseButtonDown(1)) {
        const bs = world.get(SpriteRenderer, state.ball).?;
        bs.flip_x = !bs.flip_x;
    }
    const scroll = engine.input.mouse_scroll.y;
    if (scroll != 0) engine.setZoom(engine.zoom + scroll * 0.1);
}

/// System: an ECS query over the whole SpriteRenderer storage — flash the
/// ball green for a moment, once per second.
fn flashSystem(world: *World, state: *GameState, dt: f32) void {
    state.flash_timer += dt;
    if (state.flash_timer >= 1.15) state.flash_timer = 0;

    var it = world.sprites.iter();
    while (it.next()) |item| {
        if (!std.mem.eql(u8, world.nameOf(world.idOf(item.entity)), "Ball")) continue;
        item.comp.color = if (state.flash_timer < 0.15)
            Color.init(0.3, 1.0, 0.4, 1.0)
        else
            Color.init(1.0, 0.9, 0.3, 1.0);
    }
}

pub fn main() !void {
    var da: std.heap.DebugAllocator(.{}) = .init;
    defer _ = da.deinit();
    const alloc = da.allocator();

    const W: f32 = 800;
    const H: f32 = 600;

    var engine = try basic2d.Engine.init(alloc, .{
        .title = "Basic2D - Pong (Zig, ECS)",
        .width = 800,
        .height = 600,
    });
    defer engine.deinit();

    engine.background = Color.init(0.09, 0.09, 0.13, 1.0);
    basic2d.debugLog("Zig Pong (ECS) started - arrows/WASD move the left paddle, ESC quits", .{});

    // --- Scene: entities + components via the ECS World ---
    const world = &engine.world;

    const left = try world.spawn("LeftPaddle");
    world.get(Transform, left).?.position = Vec2.init(40, H / 2);
    _ = try addSolidSprite(world, left, Color.init(0.35, 0.85, 1.0, 1.0), Vec2.init(18, 120), 1, .quad);
    _ = try world.add(Collider2D, left, .{ .is_circle = false, .size = Vec2.init(18, 120) });

    const right = try world.spawn("RightPaddle");
    world.get(Transform, right).?.position = Vec2.init(W - 40, H / 2);
    _ = try addSolidSprite(world, right, Color.init(1.0, 0.45, 0.65, 1.0), Vec2.init(18, 120), 1, .quad);
    _ = try world.add(Collider2D, right, .{ .is_circle = false, .size = Vec2.init(18, 120) });

    const ball = try world.spawn("Ball");
    world.get(Transform, ball).?.position = Vec2.init(W / 2, H / 2);
    const ball_sprite = try addSolidSprite(world, ball, Color.init(1.0, 1.0, 1.0, 1.0), Vec2.init(28, 28), 2, .circle);
    _ = try world.add(Collider2D, ball, .{ .is_circle = true, .radius = 13 });

    // Textured sprite, like Unity's Resources.Load<Sprite>().
    if (engine.loadSprite("examples/lua_pong/assets/ball.bmp")) |spr| {
        ball_sprite.setSprite(spr);
        ball_sprite.size = Vec2.init(28, 28);
        basic2d.debugLog("Loaded ball.bmp sprite ({d}x{d})", .{ spr.width, spr.height });
    } else |_| {
        basic2d.debugLog("ball.bmp not found, using plain circle", .{});
    }

    // Score display via a TextMesh component.
    const score_id = try world.spawn("ScoreText");
    world.get(Transform, score_id).?.position = Vec2.init(W / 2, H - 36);
    const score_mesh = try world.add(basic2d.TextMesh, score_id, .{});
    score_mesh.font_size = 32;
    score_mesh.sorting_order = 10;
    try score_mesh.setText(alloc, "0 - 0");

    // --- Screen-space UI: UIText + UIButton components ---
    const title_id = try world.spawn("UITitle");
    const title = try world.add(basic2d.UIText, title_id, .{});
    try title.setText(alloc, "PONG");
    title.font_size = 40;
    title.color = Color.init(0.75, 0.85, 1.0, 1.0);
    title.anchor = .bottom_center;
    title.offset = Vec2.init(0, 18);

    const quit_btn_id = try world.spawn("QuitButton");
    const quit_btn = try world.add(basic2d.UIButton, quit_btn_id, .{});
    try quit_btn.setLabel(alloc, "Quit");
    quit_btn.size = Vec2.init(110, 40);
    quit_btn.anchor = .top_right;
    quit_btn.offset = Vec2.init(-70, -30);

    basic2d.debugLog("ECS world: {d} entities", .{world.entity_count});

    var state = GameState{ .left = left, .right = right, .ball = ball };

    // --- The frame loop: update() runs the engine's systems, then the
    //     game's own ECS systems run in order before render(). ---
    while (!engine.shouldClose()) {
        const dt = engine.update();
        paddleSystem(&engine, &state, H, dt);
        ballSystem(&engine, &state, score_mesh, W, H, dt);
        flashSystem(world, &state, dt);
        if (quit_btn.was_clicked) engine.requestQuit();
        engine.render();
    }
}
