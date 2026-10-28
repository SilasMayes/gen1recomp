-- Hoenn Diorama: the Gen 3 overworld as a 3D diorama, built from the
-- metatile art your own ROM import already baked.
--
-- All of the drawing is a render pipeline (docs/modding.md, "Rendering
-- pipelines"): the engine supplies the OFF/45/35/25 ladder, the options row,
-- the hotkey, persistence, and the promise that a renderer which fails
-- costs a display mode, never the game.  `generations = { 3 }` asks for the
-- Gen 3 world pass (src/core/game3/world_pipeline.lua, engine change "Gen 3
-- world render pipelines").  An engine without it ignores the field and
-- serves this record nothing on Gen 3, so there the mod is simply inert: no
-- OPTION row, no hotkey, nothing drawn.
local mod = ...

-- lib/ modules load through here rather than package.path: each one is a
-- chunk that receives this loader as its argument and returns its table.
local loaded = {}
local function lib(name)
  local m = loaded[name]
  if m then return m end
  local rel = "lib/" .. name .. ".lua"
  local source = mod:read(rel)
  if not source then error("hoenn_diorama: missing " .. rel, 2) end
  local chunk, err = load(source, "@" .. tostring(mod.path) .. "/" .. rel)
  if not chunk then error(err, 2) end
  m = chunk(lib)
  loaded[name] = m
  return m
end

mod.options:define({
  { key = "height", label = "STRUCTURE HEIGHT", type = "choice", default = "normal",
    choices = { { "LOW", "low" }, { "NORMAL", "normal" }, { "TALL", "tall" } } },
  { key = "grass", label = "GRASS TUFTS", type = "toggle", default = true },
  { key = "shadows", label = "SHADOWS", type = "toggle", default = true },
  { key = "relief", label = "TERRAIN HEIGHT", type = "toggle", default = true },
  { key = "profile", label = "BUILDING PROFILE", type = "toggle", default = true },
})

-- The building profile (data/buildings.lua): drawings a person has read.
-- A profile that fails to load costs the profile, never the mod.
local Buildings = lib("Buildings")
local profile
do
  local source = mod:read("data/buildings.lua")
  local chunk = source and load(source, "@" .. tostring(mod.path) .. "/data/buildings.lua")
  local ok, data = false, nil
  if chunk then ok, data = pcall(chunk) end
  if ok and type(data) == "table" then
    profile = Buildings.new(data)
    if #profile.errors > 0 and mod.log and mod.log.warn then
      for _, e in ipairs(profile.errors) do pcall(mod.log.warn, mod.log, "building profile: %s", e) end
    end
  end
end

local CAPS = { low = 1, normal = 2, tall = 3 }

local function params()
  return {
    cap = CAPS[mod.options:get("height")] or 2,
    tuft = mod.options:get("grass") == false and 0 or 5,
    shadows = mod.options:get("shadows") ~= false,
    relief = mod.options:get("relief") ~= false,
    buildings = mod.options:get("profile") ~= false and profile or nil,
  }
end

local Scene = lib("Scene")
local scene = Scene.new(params())

mod.events:on("mod.options_changed", function(ev)
  if ev == nil or ev.mod == nil or ev.mod == mod.id then
    scene:setParams(params())
  end
end)

mod.content.render_pipelines:register("hoenn_diorama", {
  label = "DIORAMA",
  levels = { "OFF", "45", "35", "25" },
  hotkey = "6",
  priority = 40,
  generations = { 3 },
  available = function() return scene:available() end,
  update = function(dt, level) scene:update(dt, level) end,
  drawWorld = function(ctx) return scene:draw(ctx) end,
  invalidate = function() scene:invalidate() end,
})

mod.exports.scene = scene
