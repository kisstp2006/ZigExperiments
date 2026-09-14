-- Pong in Lua, on top of Basic2D's ECS — the canonical way to author a
-- scene. Entities + components come from the World facade; gameplay is a
-- set of systems registered with World.AddSystem, querying components
-- with World.Query / World.Get.

local W, H = 800, 600

Engine.background = Color(0.09, 0.09, 0.13, 1.0)
Debug.Log("Lua Pong (ECS) started - arrows/WASD move the left paddle, ESC quits")

-- ---------------------------------------------------------------------
-- Scene: entities + components (World = the ECS)
-- ---------------------------------------------------------------------

local leftPaddle = World.Spawn("LeftPaddle")
World.Get(leftPaddle, "Transform").position = Vector2(40, H / 2)
local lp = World.Add(leftPaddle, "SpriteRenderer")
lp.color = Color(0.35, 0.85, 1.0, 1.0)
lp.size = Vector2(18, 120)
lp.sortingOrder = 1
World.Add(leftPaddle, "BoxCollider2D", 18, 120)

local rightPaddle = World.Spawn("RightPaddle")
World.Get(rightPaddle, "Transform").position = Vector2(W - 40, H / 2)
local rp = World.Add(rightPaddle, "SpriteRenderer")
rp.color = Color(1.0, 0.45, 0.65, 1.0)
rp.size = Vector2(18, 120)
rp.sortingOrder = 1
World.Add(rightPaddle, "BoxCollider2D", 18, 120)

local ball = World.Spawn("Ball")
World.Get(ball, "Transform").position = Vector2(W / 2, H / 2)
local bs = World.Add(ball, "SpriteRenderer")
bs.color = Color(1.0, 1.0, 1.0, 1.0)
bs.size = Vector2(28, 28)
bs.shape = "Circle"
bs.sortingOrder = 2
World.Add(ball, "CircleCollider2D", 13)

-- Textured sprite: Engine.LoadSprite (like Unity's Resources.Load<Sprite>).
local ok, ballSprite = pcall(Engine.LoadSprite, "examples/lua_pong/assets/ball.bmp")
if ok then
    bs.sprite = ballSprite
    bs.size = Vector2(28, 28)
    Debug.Log("Loaded ball.bmp sprite (" .. ballSprite.width .. "x" .. ballSprite.height .. ")")
else
    Debug.Log("ball.bmp not found, using plain yellow circle")
end

-- Score display: a TextMesh component on a 9-sliced panel (Sliced
-- draw mode with a sprite border).
local okPanel, panelSprite = pcall(Engine.LoadSprite, "examples/lua_pong/assets/panel.bmp")
local panel = World.Spawn("Panel")
World.Get(panel, "Transform").position = Vector2(W / 2, H - 36)
local panelRenderer = World.Add(panel, "SpriteRenderer")
panelRenderer.sortingOrder = 5
if okPanel then
    panelSprite:SetBorder(16, 16, 16, 16)
    panelRenderer.sprite = panelSprite
    panelRenderer.drawMode = "Sliced"
    panelRenderer.size = Vector2(300, 64)
    Debug.Log("Loaded panel.bmp (9-sliced)")
else
    Debug.Log("panel.bmp not found, skipping panel")
end

local scoreText = World.Spawn("ScoreText")
World.Get(scoreText, "Transform").position = Vector2(W / 2, H - 36)
local scoreMesh = World.Add(scoreText, "TextMesh")
scoreMesh.fontSize = 32
scoreMesh.sortingOrder = 10
scoreMesh.text = "0 - 0"

-- ---------------------------------------------------------------------
-- Gameplay as ECS systems (World.AddSystem runs every frame with dt).
-- ---------------------------------------------------------------------

local leftScore, rightScore = 0, 0
local ballVel = Vector2(320, 240)
local flashTimer = 0

-- ---------------------------------------------------------------------
-- Screen-space UI: customizable UI elements (UIImage / UIText / UIButton).
-- Anchored to the screen (anchor + pixel offset), drawn on top of the
-- world, unaffected by the camera zoom.
-- ---------------------------------------------------------------------

local uiTitle = World.Spawn("UITitle")
local title = World.Add(uiTitle, "UIText")
title.text = "PONG"
title.fontSize = 40
title.color = Color(0.75, 0.85, 1.0, 1.0)
title.anchor = "BottomCenter"
title.offset = Vector2(0, 18)

local uiBar = World.Spawn("UIBar")
local bar = World.Add(uiBar, "UIImage")
bar.size = Vector2(220, 12)
bar.color = Color(0.3, 0.8, 0.4, 1.0)
bar.anchor = "BottomLeft"
bar.offset = Vector2(130, 22)

local quitBtn = World.Spawn("QuitButton")
local qb = World.Add(quitBtn, "UIButton")
qb.label = "Quit"
qb.size = Vector2(110, 40)
qb.anchor = "TopRight"
qb.offset = Vector2(-70, -30)
qb.onClick = function()
    Engine.Quit()
end

local restartBtn = World.Spawn("RestartButton")
local rb = World.Add(restartBtn, "UIButton")
rb.label = "Restart"
rb.size = Vector2(130, 40)
rb.anchor = "TopLeft"
rb.offset = Vector2(80, -30)
rb.onClick = function()
    leftScore, rightScore = 0, 0
    scoreMesh.text = "0 - 0"
    World.Get(ball, "Transform").position = Vector2(W / 2, H / 2)
    ballVel = Vector2(320, 240)
end

-- System 1: ball movement, wall bounce, scoring and paddle collision.
World.AddSystem(function(dt)
    local t = World.Get(ball, "Transform")
    t.position = t.position + ballVel * dt
    local p = t.position

    -- Bounce off the top and bottom walls.
    if p.y < 14 or p.y > H - 14 then
        ballVel = Vector2(ballVel.x, -ballVel.y)
    end

    -- Scoring.
    if p.x < -40 then
        rightScore = rightScore + 1
        scoreMesh.text = leftScore .. " - " .. rightScore
        Debug.Log("Right scores!  " .. leftScore .. " - " .. rightScore)
        t.position = Vector2(W / 2, H / 2)
        ballVel = Vector2(320, 240)
    elseif p.x > W + 40 then
        leftScore = leftScore + 1
        scoreMesh.text = leftScore .. " - " .. rightScore
        Debug.Log("Left scores!  " .. leftScore .. " - " .. rightScore)
        t.position = Vector2(W / 2, H / 2)
        ballVel = Vector2(320, 240)
    end

    -- Paddle collision via a Physics2D circle query (query only, no
    -- simulation), skipping the ball itself.
    local hit = Physics2D.OverlapCircle(p, 13, ball)
    if hit ~= nil and (hit == leftPaddle or hit == rightPaddle) then
        local offset = (p.y - World.Get(hit, "Transform").position.y) / 60
        ballVel = Vector2(-ballVel.x * 1.05,
                          Mathf.Clamp(ballVel.y + offset * 160, -520, 520))
    end
end)

-- System 2: player paddle, AI paddle, mouse controls.
World.AddSystem(function(dt)
    -- Player paddle: Unity-style Input.GetAxisRaw("Vertical").
    local lt = World.Get(leftPaddle, "Transform")
    local move = Input.GetAxisRaw("Vertical")
    lt.position = lt.position + Vector2(0, 420) * move * dt
    lt.position = Vector2(lt.position.x, Mathf.Clamp(lt.position.y, 60, H - 60))

    -- AI paddle follows the ball.
    local rt = World.Get(rightPaddle, "Transform")
    local diff = World.Get(ball, "Transform").position.y - rt.position.y
    rt.position = rt.position + Vector2(0, Mathf.Clamp(diff, -520, 520)) * dt
    rt.position = Vector2(rt.position.x, Mathf.Clamp(rt.position.y, 60, H - 60))

    -- Mouse demo: left click teleports the ball to the cursor.
    if Input.GetMouseButtonDown(0) then
        World.Get(ball, "Transform").position = Input.mousePosition
    end

    -- Right click flips the ball sprite horizontally (flipX).
    if Input.GetMouseButtonDown(1) then
        bs.flipX = not bs.flipX
    end

    -- Mouse wheel zooms the camera.
    local scroll = Input.mouseScrollDelta.y
    if scroll ~= 0 then
        Engine.SetZoom(Engine.zoom + scroll * 0.1)
    end
end)

-- System 3: an ECS query over ALL SpriteRenderer components — flash the
-- ball green for a moment, once per second.
World.AddSystem(function(dt)
    flashTimer = flashTimer + dt
    if flashTimer >= 1.15 then flashTimer = 0 end
    for entity, sr in World.Query("SpriteRenderer") do
        if entity.name == "Ball" then
            if flashTimer < 0.15 then
                sr.color = Color(0.3, 1.0, 0.4, 1.0)
            else
                sr.color = Color(1.0, 0.9, 0.3, 1.0)
            end
        end
    end
end)

Debug.Log("ECS world: " .. World.EntityCount() .. " entities")

-- The engine can generate this API reference file for editor tooling:
--   zig build run -- --generate-api basic2d_api.lua
-- or from a script: Engine.GenerateApi("basic2d_api.lua").
-- Loading it is safe; it returns the Basic2D_API index table.
local okApi, api = pcall(dofile, "basic2d_api.lua")
if okApi then
    Debug.Log("Loaded basic2d_api.lua: " .. #api.components .. " component types")
else
    Debug.Log("basic2d_api.lua not found (generate it with --generate-api)")
end
