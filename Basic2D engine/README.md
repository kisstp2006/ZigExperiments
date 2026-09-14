# Basic2D — a tiny Unity-inspired 2D game engine in Zig (+ embedded Lua)

A really simple OpenGL 2D game engine written in Zig, designed as a framework
for **both Lua and Zig**. The API mirrors a small, hand-picked subset of
Unity's 2D scripting API (verified against the Unity 6 docs):
`GameObject`, `Transform`, `SpriteRenderer`, `Sprite`, `TextMesh`,
`BoxCollider2D`, `CircleCollider2D`, `Physics2D`, `Time`, `Input`, `Debug`,
`Mathf`, `Vector2`, `Color`, MonoBehaviour-style `Start`/`Update` scripts, and
coroutines with `WaitForSeconds`.

One world unit == one pixel. Origin is the bottom-left corner, Y points up.

---

## Requirements

- Windows (the engine uses Win32 + WGL, no GLFW/glad required)
- Zig **0.16.0**
- Git (only for the first fetch of the Lua dependency)

The build system automatically pulls **Lua 5.4.8** via the Zig package manager
(`build.zig.zon` → `git+https://github.com/lua/lua.git#v5.4.8`) and compiles
the Lua C runtime with `zig cc`. No other dependencies.

## Build & run

```sh
zig build run         # Pong written entirely in Lua
zig build run-zig     # the same Pong written entirely in Zig
```

Both games: **W/S or arrows** move the left paddle, **left click** teleports
the ball, **right click** flips the ball sprite, the **mouse wheel** zooms the
camera, and **ESC** or the window close button quits. Passing `--frames N`
auto-exits after N frames (handy for testing):

```sh
zig build run -- --frames 60
```

## Generated Lua API reference

The engine can generate a complete **Lua API reference/stub file** that
lists every global, component field and function — safe to load and meant
for editor autocompletion (LuaLS / EmmyLua annotations):

```sh
zig build run -- --generate-api basic2d_api.lua   # writes the file, then exits
```

You can also generate it from a game script: `Engine.GenerateApi("path.lua")`.
The file defines a `Basic2D_API` index table (and returns it), so scripts
can introspect it with `dofile("basic2d_api.lua")` — the Lua example does
this at startup.

---

## Project layout

```
Basic2D engine/
├── build.zig             # fetches Lua, builds both examples
├── build.zig.zon
├── engine/               # the engine (a Zig module: @import("basic2d"))
│   ├── engine.zig        # Engine + systems (input/scripts/cleanup/render)
│   ├── ecs.zig           # ECS core: EntityId, World, BlockStorage, components
│   ├── api_doc.zig       # generates the Lua API reference (--generate-api)
│   ├── win32.zig         # Win32 window + WGL context (no external bindings)
│   ├── gl.zig            # OpenGL 3.3 core loader + shaders + textures
│   ├── renderer.zig      # batched sprite rendering (grouped by texture)
│   ├── input.zig         # keyboard/mouse polling
│   ├── types.zig         # Vec2, Color, Mathf, Texture
│   ├── image.zig         # BMP/PNG loader (built-in zlib inflater)
│   ├── text.zig          # built-in 5x7 bitmap font + atlas
│   ├── lua_c.zig         # hand-written Lua 5.4 C API bindings
│   └── lua_host.zig      # the Unity-like Lua bindings (ScriptSystem)
└── examples/
    ├── lua_pong/         # main.zig boots the engine; game.lua is the game
    └── zig_pong/         # the same game in pure Zig
```

---

## Architecture: an ECS under a Unity-style API

The engine core is a **proper ECS** (`engine/ecs.zig`) while the public API
stays Unity-like:

- **Entities** are plain indices plus a generation counter. `Destroy()` bumps
  the generation and recycles the slot, so stale handles fail loudly with a
  Unity-style *"has been destroyed"* error instead of dangling.
- **Components** (`Transform`, `SpriteRenderer`, `TextMesh`, `Collider2D`,
  `ScriptComponent`) live in per-type `BlockStorage` arrays: fixed-size
  blocks indexed by entity. Same SoA cache behavior as archetype storage,
  and block pointers never move, so component pointers stay valid.
- **Systems** run every frame in `Engine.update`/`Engine.render`:
  1. `InputSystem` — pumps Win32 messages, refreshes `Input`
  2. `ScriptSystem` — Lua `Start`/`Update` + coroutines (an ECS query over
     the `ScriptComponent` storage)
  3. `CleanupSystem` — releases entities marked with `Destroy()`
  4. `RenderSystem` — collects visible drawables, sorts by `sortingOrder`,
     batches by texture, draws
- **`GameObject`** is a lightweight handle (`world` + entity id), both in
  Zig and in Lua userdata. Components are resolved through the world on
  every access.

> **The ECS is the canonical way to build scenes.** Both examples author
> scenes with `World.Spawn` + component adds and run gameplay as systems.
> The GameObject/Component facade below is a Unity-compatibility layer on
> top of the same world (still fully supported for MonoBehaviour-style
> scripts).

### Authoring scenes with the ECS (Lua)

```lua
-- entities + components
local ball = World.Spawn("Ball")
World.Get(ball, "Transform").position = Vector2(400, 300)
local sr = World.Add(ball, "SpriteRenderer")
sr.shape = "Circle"
sr.sortingOrder = 2
World.Add(ball, "CircleCollider2D", 13)      -- BoxCollider2D takes (w, h)

-- component queries: for entity, component in World.Query("...") do ... end
local n = 0
for e, c in World.Query("SpriteRenderer") do n = n + 1 end

-- systems run every frame with deltaTime (registration order)
World.AddSystem(function(dt)
    local t = World.Get(ball, "Transform")
    t.position = t.position + Vector2(320, 0) * dt
end)

World.Has(ball, "CircleCollider2D")  -- true
World.Remove(ball, "SpriteRenderer") -- detach a component
World.Destroy(ball)                   -- deferred, slot-safe
World.EntityCount()                   -- number of live entities
```

### Authoring scenes with the ECS (Zig)

```zig
const world = &engine.world;

const id = try world.spawn("Ball");
world.get(basic2d.Transform, id).?.position = Vec2.init(400, 300);
const sr = try world.add(basic2d.SpriteRenderer, id, .{
    .shape = .circle, .sorting_order = 2,
});
_ = try world.add(basic2d.Collider2D, id, .{ .is_circle = true, .radius = 13 });

// storage iteration (the systems' query pattern):
var it = world.sprites.iter();
while (it.next()) |item| {
    // item.entity: u32 index, item.comp: *SpriteRenderer
}

world.has(basic2d.SpriteRenderer, id);  // bool
world.remove(basic2d.SpriteRenderer, id);
world.destroy(id);
```

### Screen-space UI (UIImage / UIText / UIButton)

UI elements are ordinary entities with UI components, drawn by the UI
system AFTER the world — anchored to the screen, unaffected by camera
zoom. Anchors are Unity-style: `TopLeft`, `TopCenter`, `TopRight`,
`MiddleLeft`, `Center`, `MiddleRight`, `BottomLeft`, `BottomCenter`,
`BottomRight`, plus an `offset` in pixels.

```lua
local btn = World.Spawn("QuitButton")
local b = World.Add(btn, "UIButton")
b.label = "Quit"
b.size = Vector2(110, 40)
b.anchor = "TopRight"
b.offset = Vector2(-70, -30)
b.normalColor = Color(0.2, 0.3, 0.45, 1)   -- hoverColor / pressedColor / labelColor too
b.onClick = function() Engine.Quit() end     -- fires on release inside the rect

local title = World.Add(World.Spawn("Title"), "UIText")
title.text = "PONG"                         -- fontSize / color / anchor / offset

local bar = World.Add(World.Spawn("Bar"), "UIImage")
bar.size = Vector2(220, 12)                  -- color / sprite / drawMode ("Sliced") / anchor
```

Zig equivalent: `world.add(basic2d.UIButton, id, .{...})`, set fields directly,
and poll `button.was_clicked` (true for one frame) or read `hover`/`pressed`.
Buttons auto-tint normal → hover → pressed and fire clicks via the UI system;
`World.Query("UIButton")` iterates them like any other component.

---

## The Unity 2D API subset

### Same API in Lua and Zig

| Unity                     | Lua                                              | Zig |
| ------------------------- | ------------------------------------------------ | ------------------------------------------- |
| `new GameObject("name")`  | `Engine.CreateGameObject("name")`                | `engine.createGameObject("name")`           |
| `transform.position`      | `go.transform.position = Vector2(400, 300)`      | `go.transform().position = Vec2.init(...)`  |
| `transform.rotation`      | `go.transform.rotation = 0.5` (radians)          | `go.transform().rotation = 0.5`             |
| `GetComponent<T>()`       | `go:GetComponent("SpriteRenderer")` / `go.sprite`| `go.getSpriteRenderer()`                    |
| `AddComponent<T>()`       | `go:AddComponent("SpriteRenderer")`              | `try go.addSpriteRenderer()`                |
| `GameObject.Find`         | `GameObject.Find("Ball")` / `Engine.Find`        | `engine.findGameObject("Ball")`            |
| `GameObject.FindWithTag`  | `GameObject.FindWithTag("Player")`               | `engine.findWithTag("Player")`             |
| `GameObject.tag`          | `go.tag = "Player"` / `go.tag`                    | `try go.setTag("Player")` / `go.tag()`     |
| `AddComponent<SpriteRenderer>()` | `go:AddSpriteRenderer()`                  | `try go.addSpriteRenderer()`                |
| `sprite.color`            | `sr.color = Color(1, 0, 0, 1)`                   | `sr.color = Color.init(1, 0, 0, 1)`         |
| `sprite.sprite`           | `sr.sprite = sprite` (auto-sizes)                | `sr.setSprite(sprite)`                      |
| `sprite.size`             | `sr.size = Vector2(32, 32)`                      | `sr.size = Vec2.init(32, 32)`               |
| `sprite.flipX/flipY`      | `sr.flipX = true`                                | `sr.flip_x = true`                          |
| `sprite.sortingOrder`     | `sr.sortingOrder = 5`                            | `sr.sorting_order = 5`                      |
| `sprite.drawMode`         | `sr.drawMode = "Sliced"` (9-slice)               | `sr.draw_mode = .sliced`                    |
| `Sprite.border` (9-slice) | `sprite:SetBorder(l, b, r, t)` / `sprite.borderLeft = ...` | `sprite.setBorder(l, b, r, t)`   |
| `Camera zoom`             | `Engine.SetZoom(2)` / `Engine.zoom`              | `engine.setZoom(2)` / `engine.zoom`         |
| `Camera.backgroundColor`  | `Engine.background = Color(r,g,b,a)` / read      | `engine.background = Color.init(...)`       |
| `Camera.transform.position` | `Engine.cameraPosition` (Vector2, get/set)     | `engine.camera_position`                    |
| `Input.mouseScrollDelta`  | `Input.mouseScrollDelta` (wheel, y axis)         | `engine.input.mouse_scroll`                 |
| `TextMesh`                | `go:AddTextMesh()`; `.text`/`.fontSize`/`.color` | `go.addTextMesh()`; `.text`/`.font_size`/`.color` |
| `Resources.Load<Sprite>`  | `Engine.LoadSprite("assets/ball.bmp")`           | `engine.loadSprite("assets/ball.bmp")`      |
| `BoxCollider2D`           | `go:AddBoxCollider2D(w, h)`                      | `try go.addBoxCollider(w, h)`               |
| `CircleCollider2D`        | `go:AddCircleCollider2D(r)`                      | `try go.addCircleCollider(r)`               |
| `Physics2D.OverlapCircle` | `Physics2D.OverlapCircle(pos, r, ignore)`        | `engine.overlapCircle(pos, r, ignore)`      |
| `Physics2D.OverlapBox`    | `Physics2D.OverlapBox(center, half, ignore)`     | `engine.overlapBox(center, half, ignore)`   |
| `Time.deltaTime`          | `Time.deltaTime`                                 | `engine.update()` returns dt                |
| `Input.GetKey("LeftArrow")` | `Input.GetKey("LeftArrow")` / `GetKeyDown`     | `engine.input.getKey(.left_arrow)`          |
| `Input.GetAxisRaw`        | `Input.GetAxisRaw("Horizontal")`                 | `engine.input.getAxisRaw(true)`             |
| `Input.mousePosition`     | `Input.mousePosition` (bottom-left origin)       | `engine.input.mouse`                        |
| `Debug.Log`               | `Debug.Log("hello", 42)`                         | `basic2d.debugLog("hello {d}", .{42})`      |
| `Vector2`                 | `Vector2(1, 2)`, `+ - *`, `.x/.y`, `.normalized` | `Vec2.init(1, 2)`, `Vec2.add(...)`          |
| `Color`                   | `Color(r, g, b, a)`                              | `Color.init(r, g, b, a)`                    |
| `Mathf.Clamp/Lerp/...`    | `Mathf.Clamp(v, 0, 1)`                           | `Mathf.clamp(v, 0, 1)`                      |
| `ScreenCapture.CaptureScreenshot` | `Engine.CaptureScreenshot("shot.bmp")`   | CLI: `--screenshot shot.bmp` (or see below)  |
| `Object.Destroy`          | `go:Destroy()` or global `Destroy(go)`           | `go.destroy()` (or `engine.destroy(go)`)    |
| `SetActive`               | `go:SetActive(false)`                            | `go.setActive(false)`                       |
| `Engine.Quit`             | `Engine.Quit()`                                  | `engine.requestQuit()`                      |

### Lua-only niceties (MonoBehaviour-style)

*(Compatibility layer over the ECS — `World.AddSystem` is the canonical
per-frame path; use this for Unity-flavored per-object scripts.)*

- **Script components**: attach a plain Lua table with `Start`/`Update`.
  `self` inside the methods is the script component; `self.gameObject` and
  `self.transform` work like Unity's `Component` accessors:

  ```lua
  local script = {}
  function script:Start()  Debug.Log("hi from " .. self.gameObject.name) end
  function script:Update()
      self.transform.position = self.transform.position + Vector2(100, 0) * Time.deltaTime
  end
  ball:AddScript(script)
  ```

- **Global update callback**: `Engine.OnUpdate(function(dt) ... end)`.

- **Coroutines**, like `StartCoroutine` + `WaitForSeconds`:

  ```lua
  ball:StartCoroutine(function()
      while true do
          coroutine.yield(WaitForSeconds(1.0))
          ball.transform.rotation = ball.transform.rotation + 0.2
      end
  end)
  ```

- `Vector2.zero/one/up/down/left/right`, `Vector2.Distance`, `Vector2.Lerp`,
  `Color.white/red/...`, `Input.GetMouseButton(0)`,
  `Engine.SetBackground(r,g,b,a)` (also accepts a `Color`),
  `Engine.background` (typed Color property), `Engine.cameraPosition`
  (typed Vector2 property), `Engine.zoom` (read/write),
  `Engine.ScreenSize()`, `Engine.screenWidth/screenHeight`.
  The `Engine` table is strict: writing an unknown field raises an error.

### Sprites and text

- **Sprites**: `Engine.LoadSprite(path)` loads a **BMP** (24/32-bit) or **PNG**
  (8-bit RGB/RGBA) file into a Sprite. Assign with `sr.sprite = sprite` (Lua)
  or `sr.setSprite(sprite)` (Zig); the renderer auto-sizes to the image
  pixels. Sprite colors tint the texture; the circle shape keeps a round
  silhouette over it. Sprites stay alive until engine shutdown.
- **Rendering controls**: `flipX`/`flipY` mirror sprites, `sortingOrder`
  controls draw order (higher draws on top, stable ties), and the camera
  zooms via `Engine.SetZoom` / `engine.setZoom` (1 = one unit per pixel).
  Mouse wheel input is exposed as `Input.mouseScrollDelta`.
- **Screen-space UI**: `UIImage` (solid/sliced/sprite rect), `UIText`
  (label) and `UIButton` (hover/pressed tints + `onClick` / `was_clicked`)
  are components on regular entities, anchored to the screen. See the UI
  section above.
- **9-slice sprites**: set borders on a Sprite (`sprite:SetBorder(l, b, r, t)`
  or `sprite.borderLeft/...`), then set `sr.drawMode = "Sliced"` and resize
  freely — corners keep their pixel borders while edges/center stretch,
  like Unity's Sliced draw mode.
- **TextMesh**: `go:AddTextMesh()` gives `text`, `fontSize` (pixel height),
  and `color`, rendered with a built-in 5x7 bitmap font (no font files
  needed). Text is centered on the transform.
- **Screenshots**: `Engine.CaptureScreenshot("shot.bmp")` saves the next
  rendered frame as a 24-bit BMP; the CLI flag `--screenshot shot.bmp` saves
  the final frame before exit (combine with `--frames N` for automated
  captures).

### Zig usage

*(GameObject facade for Unity-style code; prefer the ECS API above for
new scenes.)*

```zig
var engine = try basic2d.Engine.init(alloc, .{ .title = "Game", .width = 800, .height = 600 });
defer engine.deinit();

const player = try engine.createGameObject("Player");
player.transform().position = Vec2.init(100, 100);
const sr = try player.addSpriteRenderer();
sr.color = Color.init(1, 0.5, 0, 1);
sr.size = Vec2.init(32, 32);
sr.shape = .circle;

while (!engine.shouldClose()) {
    const dt = engine.update(); // pumps input, advances Time, runs systems
    player.transform().position.x += 200 * dt;
    engine.render(); // draws everything and presents the frame
}
```

### Notes

- Physics2D is **query-only** (no simulation): colliders are checked by
  `OverlapCircle`/`OverlapBox` against other active colliders.
- Sprites can be solid-color quads/circles or textured; drawing is grouped by
  texture (one draw call per texture per frame).
- `go:Destroy()` / `Destroy(go)` is deferred to the end of the frame. After
  that the entity's slot is recycled with a bumped generation counter, so
  any stale handle (Lua userdata or Zig `GameObject`) fails with a
  Unity-style "has been destroyed" error instead of dangling.
- Every entity automatically owns a `Transform` (like Unity); components are
  optional and added via `AddComponent`/`AddXxx`. Component userdata expose
  `gameObject` back to their owner, like Unity's `Component.gameObject`.
- The embedded Lua runs all standard libraries **except** `package`/`require`
  (games are single-file or concatenated scripts).
- ESC quits by default (configurable: see `Engine.update`).

## Troubleshooting

- **"driver rejects GL_FRAGMENT_SHADER"**: some NVIDIA driver builds reject
  the spec enum `GL_FRAGMENT_SHADER` with `GL_INVALID_ENUM`. The engine
  detects this at startup and switches to a verified working enum (it links a
  probe program and reads a pixel back to make sure rendering actually
  works).
- **Zig version**: the build files target Zig 0.16.0 (new build API:
  `b.addModule`, module-level `addCSourceFiles`, `link_libc` field, etc.).
