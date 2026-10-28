-- Hoenn Voxel: the Ruby, Sapphire and Emerald overworld in 3D, built from
-- the player's own ROM.
--
-- The method is two others', mimicked rather than copied:
--   * Emerald 3DS (ZallaxDev/emerald-3ds, MIT): every drawn point stands at
--     (u, h, v + h), so the 45-degree view is the drawing whatever the
--     heights; terrain counted in whole levels from the tiles a mountain is
--     drawn with; buildings and trees modelled once from written specs and
--     reused wherever the tiles recur.
--   * Gen2Recomped Dramatic Shapes (its Gen 3 path): read the cartridge
--     first - behaviour, collision, elevation, the layer drawn over the
--     player, the warps - and the art only where the cart says nothing, with
--     one place that decides every cell's height.
--
-- This file is glue: options, the pipeline record, exports for tests.
local mod = ...

local libs = {}
local function lib(name)
  local m = libs[name]
  if m ~= nil then return m end
  local path = (name:find("/", 1, true) and name or "lib/" .. name) .. ".lua"
  local src = mod:read(path)
  if not src then error("hoenn_voxel: missing " .. path, 2) end
  local chunk, err = load(src, "@" .. path)
  if not chunk then error(err, 2) end
  m = chunk(lib, mod)
  libs[name] = m
  return m
end

local Source = lib("Source")
local Camera = lib("Camera")
local Render = lib("Render")
local World = lib("World")
local Actors = lib("Actors")
local Analysis = lib("Analysis")
local Scene = lib("Scene")

local PITCH = { 45, 40, 34 }          -- the ladder, degrees down from level

local camera = Camera.new()
local focusH                          -- the player's ground height, eased
local ready = false
local last = {}

local function sky(ctx)
  if ctx.outdoors then return { 0.53, 0.74, 0.93 } end
  return { 0, 0, 0 }
end

local function drawWorld(ctx)
  if not Render.ok() then return nil end
  local change = Source.begin(ctx)
  if change == "warp" then focusH = nil; ready = false end
  Scene.frame(ctx, change)
  if not ready and not Scene.ready(ctx) then return nil end

  -- the focus: the centre of the flat field's view, at the player's height
  local u, v = Source.toAbs(ctx.cam.x + ctx.vw / 2, ctx.cam.y + ctx.vh / 2)
  local p = Source.player()
  local h = Analysis.groundAt(p.x, p.ground)
  if not focusH or change == "warp" then focusH = h end
  focusH = focusH + (h - focusH) * 0.2
  if math.abs(focusH - h) < 0.05 then focusH = h end

  local w, hgt = ctx.width, ctx.height
  if w <= 0 or hgt <= 0 then return nil end
  camera:frame(u, focusH, v + focusH, w, hgt, ctx.vw)

  -- the cells in view, generously (raised ground is drawn further north)
  local x0, x1, z0, z1 = camera:groundBounds(focusH - 48, focusH + 64)
  local cx0, cx1 = math.floor(x0 / 16) - 1, math.floor(x1 / 16) + 1
  -- a cell drawn at row v stands at z = v + h: rows as far north as the
  -- highest ground reaches
  local cy0, cy1 = math.floor((z0 - focusH - 112) / 16) - 1, math.floor((z1 - focusH + 48) / 16) + 1
  local list, current = World.update(cx0, cy0, cx1, cy1, u / 16, v / 16, ready)
  if not current and not ready then
    -- the first frame of a map: building blocks the flat field shows meanwhile
    return nil
  end
  ready = true

  local canvas = Render.canvas(w, hgt)
  local cards = Actors.collect(ctx)
  Render.begin(camera, sky(ctx))
  World.draw(list)
  Actors.draw(cards, Analysis.groundAt)
  Render.finish()
  last = { chunks = #list, tris = World.stats.tris, actors = #cards }
  return canvas
end

mod.content.render_pipelines:register("hoenn_voxel", {
  label = "VOXEL",
  levels = { "OFF", "45", "40", "34" },
  hotkey = "7",
  priority = 30,
  generations = { 3 },
  available = function() return Render.ok() end,
  update = function(dt, level)
    if level and level > 0 and not camera.lock then camera:update(dt, PITCH[level] or PITCH[1]) end
  end,
  drawWorld = drawWorld,
  invalidate = function()
    World.flush()
    ready = false
  end,
})

mod.exports.ready = function() return ready end
mod.exports.stats = function()
  return ("chunks=%d tris=%d actors=%d built=%d"):format(last.chunks or 0, last.tris or 0,
    last.actors or 0, World.stats.built)
end
mod.exports.lib = lib
-- a debug view: { yaw = degrees, pitch = degrees } overrides the ladder
mod.exports.debugCamera = function(v)
  camera.yaw = v and v.yaw or nil
  camera.oblique = v ~= nil and v.oblique or nil
  camera.lock = v ~= nil and v.pitch ~= nil
  if v and v.pitch then camera.pitch, camera.want = v.pitch, v.pitch end
end
