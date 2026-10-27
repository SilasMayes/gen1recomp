-- Gen 3 half of the world render-pipeline seam (src/render/Pipelines.lua).
--
-- Gen 1 and Gen 2 hand a pipeline their world as they draw it
-- (src/world/OverworldController.lua, src/world/gen2/World.lua).  The Gen 3
-- field is a GBA compositor -- BG layers and OAM flushed by priority -- with
-- no single world renderer to lend out, so this module hands a pipeline what
-- it needs to draw the field itself: the camera, every cell (metatile, pair,
-- collision, elevation, behavior) with connected maps already stitched in,
-- the metatile atlases baked from the player's ROM, the actors as drawable
-- entries, and the screen-space overlays.
--
-- The vanilla field still draws first, every frame, into the world canvas.
-- That draw is where the field's per-frame bookkeeping lives (the session's
-- position, connected-map streaming, which tilesets animate, void fades), and
-- it is the frame the engine falls back to: a pipeline that returns nil, or
-- throws and is retired, leaves exactly the 2D field on screen.
--
-- Battle transitions, the barn-door wipe and BG mosaic are drawn into the
-- flat world canvas, so a pipeline sits those frames out -- the rule TILT
-- already follows on Gen 3 (src/core/game3/display.lua drawFieldPlane).
-- Screen fades are Renderer.screenVeil and land on top of either.
--
-- Spec: docs/modding.md (Rendering pipelines, "On Gen 3")

local Pipelines = require("src.render.Pipelines")

local WorldPipeline = {}

local CELL = 16

local function loaded(name)
  return package.loaded[name]
end

local function need(name)
  local m = package.loaded[name]
  if m ~= nil then return m end
  local ok, mod = pcall(require, name)
  return ok and mod or nil
end

-- ------- when the pipeline sits a frame out

--- Why the world pipeline must not draw this frame, or nil.  Everything here
-- is an effect that exists only as pixels on the flat world canvas.
function WorldPipeline.blocked()
  local Transition = loaded("src.core.game3.battle_transition")
  if Transition and Transition.isActive and Transition.isActive() then
    return "transition"
  end
  local Fade = loaded("src.ui.game3.fade")
  if Fade and Fade.barnDoorWipeActive and Fade.barnDoorWipeActive() then
    return "wipe"
  end
  local FieldView = loaded("src.core.game3.field_view")
  if FieldView and FieldView.bgMosaicLevel and FieldView.bgMosaicLevel() > 0 then
    return "mosaic"
  end
  local Seagallop = loaded("src.ui.game3.seagallop")
  if Seagallop and Seagallop.isActive and Seagallop.isActive() then
    return "seagallop"
  end
  return nil
end

-- ------- cells

local function currentMapId(game)
  local Runtime = loaded("src.core.game3.runtime")
  local session = Runtime and Runtime.getSession and Runtime.getSession()
  if session and session.map then return session.map end
  local world = game and (game.overworld or game.world)
  if world and world.map and world.map.id then return world.map.id end
  return nil
end

local function mapDefFor(game, mapId)
  local maps = game and game.data and game.data.maps
  return maps and mapId and maps[mapId] or nil
end

local function behaviorName(pair, mid)
  local Scripts = need("src.core.game3.scripting.interaction_scripts")
  local byPair = Scripts and Scripts.behaviors and Scripts.behaviors[pair]
  local id = byPair and byPair[mid]
  if id == nil then return nil end
  local MB = need("src.core.game3.mb")
  return MB and MB.nameOf(id) or nil
end

local function walkable(coll)
  local P = need("src.world.gen2.Permissions")
  if P and P.isWalkable then return P.isWalkable(coll) == true end
  return coll ~= 0x07 and coll ~= 0xff and coll ~= 0x29
end
WorldPipeline.walkable = walkable

-- One cell in current-map space: mid, pair, coll, elev, behavior name, void.
-- The void fill the flat field applies (src/core/game3/void_fill.lua) is
-- applied here too, so a pipeline shows the same border the 2D field does;
-- a cell the BLACK fill blanks comes back as (nil, nil, 0xff, 0, nil, true).
-- What a void cell turns into under the VOID FILL option, worked out once
-- per frame rather than per cell: nil for MAP (the border, as sampled).
local function voidFiller(mapDef)
  local VoidFill = need("src.core.game3.void_fill")
  local mode = VoidFill and VoidFill.normalize(VoidFill.mode) or "map"
  if mode == "map" or not mapDef then return nil end
  local NativeTileset = need("src.core.game3.tileset_native")
  local primary = mapDef.pair or (mapDef.midLayout and mapDef.midLayout.pair)
  local ts = NativeTileset and NativeTileset._pairs and NativeTileset._pairs[primary]
  local function hasMid(m) return ts ~= nil and ts.midToSlot ~= nil and ts.midToSlot[m] ~= nil end
  local okP, fillPrimary = pcall(VoidFill.primaryFor, primary)
  if not okP then fillPrimary = nil end
  return function(cx, cy)
    return VoidFill.fillAt(mode, cx, cy, hasMid, fillPrimary), primary
  end
end

-- `fill` is voidFiller's answer for this frame (nil: none).
local function sampleCell(mapDef, cx, cy, fill)
  local Map = need("src.core.game3.map")
  if not (Map and Map.worldCellAt and mapDef) then return nil end
  local cell, pair, void = Map.worldCellAt(cx, cy, mapDef)
  if not cell then return nil end
  local mid, coll, elev = cell.mid or 0, cell.coll or 0xff, cell.elev or 0
  if void then
    if fill == nil then fill = voidFiller(mapDef) or false end
    if fill then
      local filled, primary = fill(cx, cy)
      if filled == false then return nil, nil, 0xff, 0, nil, true end
      if filled then mid, pair = filled, primary end
    end
  end
  return mid, pair, coll, elev, behaviorName(pair, mid), void == true
end
WorldPipeline.sampleCell = sampleCell

-- ------- atlases

-- Pairs the pipeline drew from last frame.  FieldView.trimNative keeps them
-- resident (its own keep set is only what the flat view shows), so a camera
-- that sees further than the flat field does not make the two fight over the
-- resident budget and reload a pair every frame.
WorldPipeline.pinned = {}

local views = {}   -- pair -> view; replaced whenever the pair's ts is
local coverage = setmetatable({}, { __mode = "k" })

-- Fraction of a metatile's overhead (BG1) layer that is opaque: 0 for a
-- metatile with nothing over the actors, 1 for a solid roof tile.  Read off
-- the indexed over pack, where byte 0 is the transparent colour.
local function overCoverage(ts, slot)
  local blob = ts.overBlob
  if type(blob) ~= "string" or #blob < 12 or slot == nil then return 0 end
  local cache = coverage[ts]
  if not cache then
    cache = {}
    coverage[ts] = cache
  end
  local c = cache[slot]
  if c then return c end
  local midCount = blob:byte(7) + blob:byte(8) * 256
  local base = 13 + midCount * 2 + slot * 256
  local seg = blob:sub(base, base + 255)
  if #seg < 256 then
    c = 0
  else
    local _, zeros = seg:gsub("%z", "")
    c = (256 - zeros) / 256
  end
  cache[slot] = c
  return c
end

-- Keyed by pair, not by ts: a view's functions close over its ts, and a
-- weak-keyed table whose values reach their own key never lets go of it.
local function atlasView(pair, ts)
  local view = views[pair]
  if not (view and view._ts == ts) then
    view = {
      _ts = ts,
      pair = ts.pair or pair,
      cols = ts.cols, rows = ts.rows,
      width = (ts.cols or 0) * CELL, height = (ts.rows or 0) * CELL,
      layered = ts.layered == true,
    }
    -- atlas slot for a metatile, nil when the pair does not carry it
    view.slot = function(mid) return ts.midToSlot and ts.midToSlot[mid] end
    -- pixel origin of a metatile's 16x16 cell, the same in both images
    view.origin = function(mid)
      local slot = ts.midToSlot and (ts.midToSlot[mid] or ts.midToSlot[0])
      if not slot then return nil end
      return (slot % ts.cols) * CELL, math.floor(slot / ts.cols) * CELL
    end
    view.coverage = function(mid)
      return overCoverage(ts, ts.midToSlot and ts.midToSlot[mid])
    end
    views[pair] = view
  end
  -- tileset animation flips these between frames, so they are re-read on
  -- every call rather than captured: bind whatever is here when you draw
  view.image = ts.image
  view.overImage = ts.overImage
  -- the under layer's pixels on the CPU (read-only), for a pipeline that
  -- derives art of its own from the ROM's (cut-outs, edge colours)
  view.imageData = ts.imageData
  return view
end

-- A pair that is not resident is never loaded here on the frame's time: it
-- is queued on the asset stream and answers nil until the off-thread decode
-- is done, when only the upload is left.
local function atlasFor(pair)
  local NativeTileset = need("src.core.game3.tileset_native")
  if not (NativeTileset and pair and NativeTileset.ready(pair)) then return nil end
  WorldPipeline.pinned[pair] = true
  local stream = NativeTileset._stream
  local resident = NativeTileset._pairs and NativeTileset._pairs[pair] ~= nil
  if not resident and not (stream and stream.decoded and stream:decoded(pair)) then
    if NativeTileset.prefetch then NativeTileset.prefetch(pair, 2) end
    return nil
  end
  local ts = NativeTileset.get(pair)
  if not (ts and ts.image) then return nil end
  return atlasView(pair, ts)
end
WorldPipeline.atlas = atlasFor

-- ------- the placed maps

local function revisionOf(def)
  local L = def and def.midLayout
  return L and (L._revision or 0) or 0
end

local function sizeOf(def)
  local L = def and def.midLayout
  return (L and L.width) or 0, (L and L.height) or 0
end

local function placedMaps(mapId, mapDef)
  local Map = need("src.core.game3.map")
  local w, h = sizeOf(mapDef)
  local out = { { id = mapId, ox = 0, oy = 0, width = w, height = h,
    revision = revisionOf(mapDef) } }
  for _, e in ipairs((Map and Map.world) or {}) do
    if e.def ~= mapDef then
      local ew, eh = sizeOf(e.def)
      out[#out + 1] = { id = e.id, ox = e.ox, oy = e.oy, width = ew, height = eh,
        revision = revisionOf(e.def) }
    end
  end
  return out
end

-- ------- the ctx

local function playerState(game)
  local FieldView = need("src.core.game3.field_view")
  local px, py, facing, _, _, avatar, yOff = 0, 0, "down", nil, nil, nil, 0
  if FieldView and FieldView.playerPixels then
    px, py, facing, _, _, avatar, yOff = FieldView.playerPixels(game)
  end
  px, py, yOff = px or 0, py or 0, yOff or 0
  local P = type(avatar) == "table" and avatar or {}
  return {
    -- foot: the bottom centre of the cell the sprite is drawn against
    x = px + CELL / 2, y = py + CELL + yOff, ground = py + CELL, lift = -yOff,
    cellX = tonumber(P.cellX) or math.floor(px / CELL),
    cellY = tonumber(P.cellY) or math.floor(py / CELL),
    facing = facing or "down",
    elevation = tonumber(P.elevation) or 3,
    surfing = P.surfing == true, biking = P.biking == true,
    moving = P.moving == true,
  }
end

local function doorOverlay()
  local Doors = loaded("src.core.game3.doors")
  local anim = Doors and Doors._activeAnim
  if not (anim and Doors.draw) then return nil end
  local x, y = anim.x * CELL + CELL / 2, anim.y * CELL + CELL
  return {
    cx = anim.x, cy = anim.y, x = x, y = y,
    -- the door art with its bottom centre on (ox, oy), same contract as an
    -- actor entry's draw
    draw = function(ox, oy)
      Doors.draw(x - ox, y - oy, math.huge, math.huge)
      love.graphics.setColor(1, 1, 1, 1)
    end,
  }
end

--- The ctx a Gen 3 drawWorld receives.  Exposed for tests and tools.
function WorldPipeline.context(game, Renderer, id, vw, vh)
  local FieldView = need("src.core.game3.field_view")
  local Zoom = require("src.render.Zoom")
  local r = Renderer:frameRects()
  local mapId = currentMapId(game)
  local mapDef = mapDefFor(game, mapId)
  local camX = FieldView and FieldView._camX or 0
  local camY = FieldView and FieldView._camY or 0
  local Profile = need("src.core.game3.profile")
  local okV, profile = pcall(function() return Profile and Profile.forSession(nil) end)
  local scale = Zoom.scale(r.Sp)
  local ctx = {
    generation = 3,
    version = okV and profile and profile.id or nil,
    game = game,
    level = Pipelines.level(id),
    -- the image the engine composites 1:1 over the playfield, in
    -- framebuffer pixels: make the canvas this size with dpiscale = 1
    width = math.floor(r.pw + 0.5), height = math.floor(r.ph + 0.5),
    -- framebuffer pixels per world pixel in the flat field (survey zoom in)
    scale = scale,
    -- the flat pass: its view in world pixels and its top-left corner
    vw = vw, vh = vh,
    cam = { x = camX, y = camY },
    -- the finished 2D field (vw x vh), for a fallback or an inset
    flat = Renderer.worldCanvas,
    -- true where the composite mirrors a world override (LOVE 12 on iOS,
    -- Renderer.mirrorsWorldOverride): a pipeline pre-flips its 3D pass for
    -- LOVE 11 as everywhere, and mirrors its own 2D drawing (drawWeather
    -- included) about the canvas height so it comes out the right way up
    mirrored = Renderer.mirrorsWorldOverride and Renderer.mirrorsWorldOverride() == true or false,
    mapId = mapId,
    -- the cart's MAP_TYPE_* number, and what pret's overworld.c makes of it
    mapType = mapDef and tonumber(mapDef.mapType) or nil,
    outdoors = (function()
      local Dataset = need("src.core.game3.dataset")
      return mapDef ~= nil and Dataset ~= nil and Dataset.isOutdoorMapType(mapDef.mapType) == true
    end)(),
    player = playerState(game),
    voidMode = (function()
      local VoidFill = loaded("src.core.game3.void_fill")
      return VoidFill and VoidFill.normalize(VoidFill.mode) or "map"
    end)(),
  }
  local fill = voidFiller(mapDef) or false
  ctx.cell = function(cx, cy) return sampleCell(mapDef, cx, cy, fill) end
  ctx.walkable = walkable
  ctx.atlas = atlasFor
  ctx.world = function() return placedMaps(mapId, mapDef) end
  -- collected once per frame however often it is asked
  local actors
  ctx.actors = function()
    if not actors then
      actors = FieldView and FieldView.actorList and FieldView.actorList(game) or {}
    end
    return actors
  end
  ctx.door = doorOverlay
  -- Flash darkness: the lit circle's radius in world pixels, centred on the
  -- player, or nil when the map is lit
  ctx.flashRadius = function()
    return FieldView and FieldView.flashRadius and FieldView.flashRadius() or nil
  end
  -- Weather sprites over the bound canvas in screen space, at `s` canvas
  -- pixels per world pixel (ctx.scale by default) across a w x h canvas
  -- (ctx.width x ctx.height by default), in the current transform
  ctx.drawWeather = function(s, w, h)
    local FieldWeather = loaded("src.core.game3.field_weather")
    if not (FieldWeather and FieldWeather.drawOverlay) then return end
    s = s or scale
    if not s or s <= 0 then return end
    love.graphics.push("all")
    love.graphics.scale(s, s)
    FieldWeather.drawOverlay(camX, camY, (w or ctx.width) / s, (h or ctx.height) / s)
    love.graphics.pop()
  end
  return ctx
end

--- Run the active world pipeline over this frame's field.  Returns the
-- canvas to composite, or nil for the flat field already in the world canvas.
function WorldPipeline.draw(game, Renderer, vw, vh)
  local id = Pipelines.worldPipeline()
  if not id then
    if next(WorldPipeline.pinned) then WorldPipeline.pinned = {} end
    return nil
  end
  if WorldPipeline.blocked() then return nil end
  -- the field drew nothing this frame (no layout yet): nothing to stand on
  local FieldView = loaded("src.core.game3.field_view")
  if not (FieldView and FieldView._camX) then return nil end
  WorldPipeline.pinned = {}
  local ok, ctx = pcall(WorldPipeline.context, game, Renderer, id, vw, vh)
  if not ok then
    local Logger = need("src.core.Logger")
    if Logger then Logger.error("game3 world pipeline ctx failed: %s", tostring(ctx)) end
    return nil
  end
  local canvas = Pipelines.drawWorld(id, ctx)
  if canvas then canvas = Pipelines.worldPresent(canvas, ctx) end
  return canvas
end

return WorldPipeline
