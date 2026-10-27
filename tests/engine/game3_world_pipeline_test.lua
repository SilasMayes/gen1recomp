-- The Gen 3 world render-pipeline seam (src/core/game3/world_pipeline.lua).
--
-- Pins the contract a Gen 3 3D renderer leans on: which records a boot may
-- serve (a drawWorld written for the Gen 1 / Gen 2 ctx never runs on Gen 3,
-- one that names `generations = { 3 }` does), that the field still draws
-- flat underneath and the pipeline's canvas replaces it only when it answers,
-- that it sits transitions out, that a throw retires it back to 2D, and that
-- the ctx's cells, atlases and actors agree with the flat field's own.
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

local T = require("tests.harness")
local check, eq = T.check, T.eq
local G = love.graphics
local noop = function() end

local Schemas = require("src.mods.Schemas")
local Pipelines = require("src.render.Pipelines")
local Tilt = require("src.render.Tilt")

local function canvas(w, h) return G.newCanvas(w or 4, h or 4) end

-- ------- schema: generations

do
  local spec = Schemas.REGISTRIES.render_pipelines
  local fn = function() end
  check(Schemas.check(spec, "render_pipelines", "a",
    { label = "A", drawWorld = fn, generations = { 3 } }, "register"),
    "generations = { 3 } validates")
  check(Schemas.check(spec, "render_pipelines", "b",
    { label = "B", drawWorld = fn, generations = { 1, 2, 3 } }, "register"),
    "every generation may be listed")
  local ok, err = Schemas.check(spec, "render_pipelines", "c",
    { label = "C", drawWorld = fn, generations = { 4 } }, "register")
  check(not ok and tostring(err):find("expected 1, 2 or 3", 1, true),
    "an unknown generation is rejected: " .. tostring(err))
  ok, err = Schemas.check(spec, "render_pipelines", "d",
    { label = "D", drawWorld = fn, generations = {} }, "register")
  check(not ok and tostring(err):find("empty", 1, true), "an empty list is rejected")
  ok, err = Schemas.check(spec, "render_pipelines", "e",
    { label = "E", present = fn, generations = { 3 } }, "register")
  check(not ok and tostring(err):find("drawWorld", 1, true),
    "generations without a drawWorld is rejected")
end

-- ------- which world each boot serves

local outCanvas = canvas(8, 8)
local seen = {}
local function records()
  return { render_pipelines = {
    voxel = { label = "VOXEL", drawWorld = function() return outCanvas end },
    relief = { label = "RELIEF", priority = 5, generations = { 3 }, levels = { "OFF", "A", "B" },
      drawWorld = function(ctx) seen[#seen + 1] = ctx; return seen.answer end },
    gold = { label = "GOLD", generations = { 2 }, drawWorld = function() end },
    every = { label = "EVERY", generations = { 1, 2, 3 }, drawWorld = function() end },
    grade = { label = "GRADE", present = function(c) return c end },
  } }
end

do
  local gen3 = records()
  Schemas.bindGen3(gen3, "emerald")
  Pipelines.install(gen3)
  eq(Pipelines.generation(), 3, "a Gen 3 dataset installs generation 3")
  check(not Pipelines.servesWorld("voxel"), "a Gen 1/2 world pipeline is not served on Gen 3")
  check(Pipelines.servesWorld("relief"), "generations = { 3 } is served on Gen 3")
  check(Pipelines.servesWorld("every"), "a record listing 3 among others is served on Gen 3")
  check(not Pipelines.servesWorld("gold"), "a Gen 2-only record is not served on Gen 3")
  eq(Pipelines.setLevel("voxel", 1), 0, "an unserved world-only pipeline cannot be switched on")
  check(not Pipelines.offered("voxel", 3), "the Gen 3 menu does not offer it")
  check(Pipelines.offered("relief", 3), "the Gen 3 menu offers the Gen 3 world pipeline")
  check(Pipelines.offered("grade", 3), "post-processes are still offered")

  Tilt.applyOptions({ tilt = 1 })
  eq(Pipelines.setLevel("relief", 1), 1, "the Gen 3 world pipeline switches on")
  eq(Tilt.level, 0, "switching it on switches TILT off, as on Gen 1")
  local id = Pipelines.worldPipeline()
  eq(id, "relief", "it owns the world pass")
  Pipelines.setLevel("every", 1)
  eq(Pipelines.level("relief"), 0, "one world pipeline at a time")
  local opts = { tilt = 1 }
  Pipelines.syncOptions(opts)
  eq(opts.tilt, 0, "the saved options drop TILT for a served world pipeline")
  Pipelines.applyOptions({ pipelines = { relief = 1, voxel = 1 } })
  eq(Pipelines.level("relief"), 1, "a stored level restores")
  eq(Pipelines.level("voxel"), 0, "an unserved world pipeline restores to OFF")
  local o = { pipelines = { relief = 1 } }
  Pipelines.yieldToTilt(o)
  eq(Pipelines.level("relief"), 0, "TILT switched on switches the world pipeline off")
  eq(o.pipelines.relief, 0, "and the saved options follow")
  check(Pipelines.inert("voxel") and not Pipelines.inert("relief") and not Pipelines.inert("grade"),
    "inert names the records with nothing to do here")
  Tilt.reset()

  local gold = records()
  Pipelines.install(gold, 2)
  eq(Pipelines.generation(), 2, "Game2 installs generation 2")
  check(Pipelines.servesWorld("voxel"), "unlisted records keep their Gen 2 world")
  check(Pipelines.servesWorld("gold"), "a Gen 2 record is served on Gen 2")
  check(not Pipelines.servesWorld("relief"), "a Gen 3-only record is not served on Gen 2")
  local rowIds = {}
  for _, row in ipairs(Pipelines.rows({})) do rowIds[row.id] = true end
  check(rowIds["pipeline:voxel"] and not rowIds["pipeline:relief"],
    "the Gen 1 / Gen 2 options rows leave out a Gen 3-only world pipeline")

  Pipelines.install(records())
  eq(Pipelines.generation(), nil, "an unnamed non-Gen-3 dataset has no generation")
  check(Pipelines.servesWorld("voxel"), "unlisted records are served where the generation is unknown")
  check(Pipelines.servesWorld("gold"), "so is a record listing a shared generation")
  check(not Pipelines.servesWorld("relief"), "a Gen 3-only record is not")
  Pipelines.install(nil)
end

-- ------- the display seam

local worldCanvas, uiCanvas = canvas(240, 160), canvas(240, 160)
local Renderer = { canvas = uiCanvas, worldCanvas = worldCanvas }
function Renderer:init() end
function Renderer:setUISize() end
function Renderer:beginFrame() self.override = nil end
function Renderer:worldViewSize() return 240, 160 end
function Renderer:beginWorldPass() self.worldActive = true; G.setCanvas(self.worldCanvas) end
function Renderer:exchangeWorldCanvas() return false end
function Renderer:endWorldPass() G.setCanvas(self.canvas) end
function Renderer:endFrame() end
function Renderer:setWorldOverride(c) self.override = c end
function Renderer:frameRects() return { pw = 960, ph = 640, Sp = 4 } end

local transitioning = false
local fieldDraws = 0
local FieldViewStub = {
  draw = function() fieldDraws = fieldDraws + 1 end,
  _camX = 100, _camY = 50,
  bgMosaicLevel = function() return 0 end,
  playerPixels = function() return 208, 128, "up", 0, false, { cellX = 13, cellY = 8, elevation = 3 }, -4 end,
  actorList = function() return { { x = 1, y = 2 } } end,
  flashRadius = function() return 56 end,
}
local stubs = {
  ["src.render.Renderer"] = Renderer,
  ["src.render.PaletteFX"] = { mode = "gbc" },
  ["src.ui.game3.help_system"] = { isOpen = function() return false end },
  ["src.core.game3.battle"] = { isActive = function() return false end },
  ["src.core.game3.bg"] = { hasVisible = function() return false end },
  ["src.core.game3.oam"] = {
    resetFrame = noop, setLayer = function() return "world" end, animateSprites = noop,
    buildOamBuffer = noop, flush = noop, flushPriority = noop,
  },
  ["src.core.game3.field_view"] = FieldViewStub,
  ["src.core.game3.battle_transition"] = { isActive = function() return transitioning end,
    drawWorld = noop },
}
local saved = {}
for name, mod in pairs(stubs) do
  saved[name] = package.loaded[name]
  package.loaded[name] = mod
end
package.loaded["src.core.game3.display"] = nil
package.loaded["src.core.game3.world_pipeline"] = nil
local Display = require("src.core.game3.display")
Display.setUiRenderer(noop)

local function frame()
  Display.planesBroken = false
  Renderer.override = nil
  Display.present({ options = {} }, 960, 640)
  check(not Display.planesBroken, "the plane path did not fall back")
end

do
  local data = records()
  Schemas.bindGen3(data, "emerald")
  Pipelines.install(data)

  frame()
  eq(#seen, 0, "no pipeline switched on: drawWorld never runs")
  eq(Renderer.override, nil, "and nothing replaces the world")

  Pipelines.setLevel("relief", 2)
  seen.answer = outCanvas
  local before = fieldDraws
  frame()
  eq(fieldDraws, before + 1, "the flat field still draws under the pipeline")
  eq(#seen, 1, "the Gen 3 world pipeline ran once")
  eq(Renderer.override, outCanvas, "its canvas replaces the world")
  local ctx = seen[1]
  eq(ctx.generation, 3, "ctx.generation")
  eq(ctx.level, 2, "ctx.level")
  eq(ctx.width, 960, "ctx.width is the playfield in framebuffer pixels")
  eq(ctx.height, 640, "ctx.height")
  eq(ctx.vw, 240, "ctx.vw is the flat view")
  eq(ctx.cam.x, 100, "ctx.cam is the camera the field drew with")
  eq(ctx.flat, worldCanvas, "ctx.flat is the finished flat field")
  eq(ctx.mirrored, false, "ctx.mirrored follows Renderer.mirrorsWorldOverride (absent: false)")
  eq(ctx.player.x, 216, "ctx.player.x is the foot")
  eq(ctx.player.ground, 144, "ctx.player.ground is the foot on the ground")
  eq(ctx.player.y, 140, "ctx.player.y carries the hop")
  eq(ctx.player.lift, 4, "ctx.player.lift is the hop height")
  eq(ctx.player.facing, "up", "ctx.player.facing")
  eq(ctx.flashRadius(), 56, "ctx.flashRadius reads the field's flash")
  eq(#ctx.actors(), 1, "ctx.actors is the field's actor list")
  check(ctx.actors() == ctx.actors(), "collected once per frame")
  for _, k in ipairs({ "cell", "walkable", "atlas", "world", "door", "drawWeather" }) do
    eq(type(ctx[k]), "function", "ctx." .. k .. " is offered")
  end

  seen.answer = nil
  frame()
  eq(#seen, 2, "the pipeline was asked again")
  eq(Renderer.override, nil, "a nil answer leaves the flat field")

  seen.answer = outCanvas
  transitioning = true
  frame()
  eq(#seen, 2, "a battle transition is drawn on the flat field: the pipeline sits it out")
  eq(Renderer.override, nil, "and nothing replaces it")
  transitioning = false

  FieldViewStub._camX = nil
  frame()
  eq(#seen, 2, "a frame where the field placed no camera (no layout) is sat out too")
  FieldViewStub._camX = 100

  data.render_pipelines.relief.drawWorld = function() error("boom") end
  frame()
  eq(Renderer.override, nil, "a pipeline that throws leaves the flat field")
  check(not Pipelines.eligible("relief"), "and is retired for the session")
  Pipelines.install(nil)
end

for name in pairs(stubs) do package.loaded[name] = saved[name] end
package.loaded["src.core.game3.display"] = nil
package.loaded["src.core.game3.world_pipeline"] = nil

-- ------- cells: connected maps, behaviors, void fill

do
  local Map = require("src.core.game3.map")
  local function layout(w, h, mids, pair, border)
    local cells = {}
    for i = 1, w * h do cells[i] = { mid = mids[i] or 1, coll = (i % 2 == 0) and 0x07 or 0x00, elev = 3 } end
    return {
      width = w, height = h, pair = pair, cells = cells, overrides = {}, _revision = 7,
      cellAt = function(self, x, y)
        if x >= 0 and y >= 0 and x < w and y < h then return self.cells[y * w + x + 1] end
        return { mid = border or 9, coll = 0xff, elev = 0 }
      end,
      midAt = function(self, x, y) return self:cellAt(x, y).mid end,
    }
  end
  local home = { pair = "town", midLayout = layout(2, 2, { 11, 12, 13, 14 }, "town") }
  local north = { pair = "route", midLayout = layout(2, 3, { 21, 22, 23, 24, 25, 26 }, "route") }
  local savedList, savedWorld = Map.neighborList, Map.world
  Map.neighborList = { { dir = "north", def = north, offset = 0 } }
  Map.world = { { id = "NORTH", def = north, ox = 0, oy = -3 } }

  local cell, pair, void = Map.worldCellAt(1, -1, home)
  eq(cell.mid, 26, "worldCellAt reads the connected map across the seam")
  eq(pair, "route", "with the neighbour's pair")
  eq(void, nil, "a connected cell is not void")
  eq(Map.worldMidAt(1, -1, home), 26, "worldMidAt agrees")
  -- each route on its own: the depth-1 connection, then the placed world
  Map.world = {}
  eq(Map.worldCellAt(1, -1, home).mid, 26, "through the connection alone")
  Map.neighborList = {}
  Map.world = { { id = "NORTH", def = north, ox = 0, oy = -3 } }
  eq(Map.worldCellAt(0, -3, home).mid, 21, "through the placed world alone")
  Map.neighborList = { { dir = "north", def = north, offset = 0 } }
  cell, pair = Map.worldCellAt(1, 1, home)
  eq(cell.mid, 14, "an in-map cell is the layout's own")
  eq(cell.coll, 0x07, "with its collision")
  cell, pair, void = Map.worldCellAt(5, 5, home)
  eq(void, true, "a cell no map covers is void")
  eq(cell.mid, 9, "and samples the border, as worldMidAt does")
  eq(Map.worldMidAt(5, 5, home), 9, "worldMidAt agrees on the border")

  local Scripts = require("src.core.game3.scripting.interaction_scripts")
  local MB = require("src.core.game3.mb")
  local savedBeh = Scripts.behaviors
  Scripts.behaviors = { route = { [26] = MB.require("TALL_GRASS") } }
  package.loaded["src.core.game3.world_pipeline"] = nil
  local WP = require("src.core.game3.world_pipeline")
  local mid, p, coll, elev, beh, isVoid = WP.sampleCell(home, 1, -1)
  eq(mid, 26, "ctx.cell: mid")
  eq(p, "route", "ctx.cell: pair")
  eq(coll, 0x07, "ctx.cell: collision")
  eq(elev, 3, "ctx.cell: elevation")
  eq(beh, "TALL_GRASS", "ctx.cell: the behavior by name")
  eq(isVoid, false, "ctx.cell: not void")
  check(WP.walkable(0x00) and not WP.walkable(0x07), "ctx.walkable reads collision")

  local VoidFill = require("src.core.game3.void_fill")
  local mode = VoidFill.mode
  VoidFill.mode = "black"
  local m2, _, c2, _, _, v2 = WP.sampleCell(home, 5, 5)
  eq(m2, nil, "BLACK void fill blanks a void cell")
  eq(c2, 0xff, "and makes it solid")
  eq(v2, true, "and says it is void")
  VoidFill.mode = mode

  Scripts.behaviors = savedBeh
  Map.neighborList, Map.world = savedList, savedWorld
end

-- ------- atlases: slot origins and overhead coverage

do
  package.loaded["src.core.game3.world_pipeline"] = nil
  local NativeTileset = require("src.core.game3.tileset_native")
  local savedReady, savedGet = NativeTileset.ready, NativeTileset.get
  -- an over pack with 2 mids: slot 0 fully transparent, slot 1 a quarter opaque
  local header = string.char(0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0) .. string.char(0, 0, 1, 0)
  local slot1 = string.rep("\1", 64) .. string.rep("\0", 192)
  local ts = {
    pair = "town", cols = 2, rows = 1, layered = true,
    midToSlot = { [40] = 0, [41] = 1 },
    image = canvas(32, 16), overImage = canvas(32, 16),
    overBlob = header .. string.rep("\0", 256) .. slot1,
  }
  local savedPairs, savedPrefetch, savedStream = NativeTileset._pairs, NativeTileset.prefetch, NativeTileset._stream
  local prefetched, synced = {}, 0
  NativeTileset._pairs = { town = ts }
  NativeTileset._stream = { decoded = function(_, p) return p == "dune" end }
  NativeTileset.ready = function(p) return p == "town" or p == "cave" or p == "dune" end
  NativeTileset.get = function(p)
    if p ~= "town" then synced = synced + 1 end
    return p == "town" and ts or nil
  end
  NativeTileset.prefetch = function(p) prefetched[#prefetched + 1] = p end
  local WP = require("src.core.game3.world_pipeline")
  local a = WP.atlas("town")
  check(a ~= nil, "a resident pair has an atlas")
  eq(WP.atlas("cave"), nil, "a pair not yet resident has none yet")
  eq(prefetched[1], "cave", "it is queued on the asset stream instead")
  eq(synced, 0, "and never loaded on the frame's time")
  WP.atlas("dune")
  eq(synced, 1, "a pair the worker already decoded is only uploaded")
  check(WP.pinned.town and WP.pinned.cave, "every pair asked for is pinned for the next trim")
  eq(a.imageData, nil, "imageData mirrors the ts (absent here)")
  eq(a.width, 32, "atlas width in pixels")
  eq(a.image, ts.image, "atlas.image is the live under image")
  local x, y = a.origin(41)
  eq(x, 16, "origin x of slot 1")
  eq(y, 0, "origin y of slot 1")
  eq(a.slot(99), nil, "a metatile the pair lacks has no slot")
  eq(a.coverage(40), 0, "nothing overhead")
  eq(a.coverage(41), 0.25, "a quarter of the overhead layer is opaque")
  local flipped = canvas(32, 16)
  ts.image = flipped
  eq(WP.atlas("town").image, flipped, "an animation flip is picked up on the next call")
  NativeTileset.ready, NativeTileset.get = savedReady, savedGet
  NativeTileset._pairs, NativeTileset.prefetch, NativeTileset._stream = savedPairs, savedPrefetch, savedStream
end

-- ------- actors: the foot lands where the compositor asks

do
  package.loaded["src.core.game3.field_view"] = nil
  local FieldView = require("src.core.game3.field_view")
  local function up(fn, wanted, replacement)
    for i = 1, 200 do
      local name, value = debug.getupvalue(fn, i)
      if not name then break end
      if name == wanted then
        if replacement then debug.setupvalue(fn, i, replacement) end
        return value
      end
    end
    error("missing upvalue " .. wanted)
  end
  local placed = {}
  local hopper = { kind = "npc", x = 64, y = 30, eventObject = { raiseY = -6 } }
  hopper.draw = function(self, camX, camY)
    placed[#placed + 1] = { camX = camX, camY = camY, billboard = FieldView._billboard }
  end
  up(FieldView.actorList, "collectGame3Actors", function()
    return { hopper }, { { kind = "player", x = 0, y = 0, draw = noop } }
  end)
  up(FieldView.actorList, "resolveMapDef", function() return { width = 1 } end)
  up(FieldView.actorList, "playerPixels", function() return 0, 0, "down", 0, false, nil, -3 end)
  FieldView._camX, FieldView._camY = 10, 20
  FieldView._billboard = { vw = 1, vh = 1 }
  local list = FieldView.actorList({})
  eq(#list, 2, "under and over actors are both listed")
  eq(list[1].x, 72, "foot x is the cell's bottom centre")
  eq(list[1].y, 46, "foot y is the cell's bottom edge")
  eq(list[1].ground, 52, "ground takes the jump arc back out")
  eq(list[1].over, false, "an under actor")
  eq(list[2].over, true, "an over actor")
  eq(list[2].ground - list[2].y, 3, "the player's hop is its lift")
  list[1].draw(32, 60)
  eq(placed[1].camX, 64 + 8 - 32, "draw(ox, oy) picks the camera that lands the foot on ox")
  eq(placed[1].camY, 30 + 16 - 60, "and on oy")
  eq(placed[1].billboard, nil, "the tilt billboard is off while drawing for a compositor")
  check(FieldView._billboard ~= nil, "and restored afterwards")
  FieldView._camX = nil
  eq(#FieldView.actorList({}), 0, "before any field draw there is nothing to list")
  package.loaded["src.core.game3.field_view"] = nil
end

T.finish("game3_world_pipeline")
