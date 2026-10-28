-- Standalone, from the engine root:
--   luajit mods/hoenn_voxel/tests/hoenn_voxel_test.lua
--
-- Headless.  The mod is loaded through the real loader on a Gen 3 dataset
-- to check what it registers; the geometry, the terrain count and the camera
-- are pure Lua and are tested on small hand-made maps.  Rendering itself is
-- checked on a GPU with real ROM art (README, "Checking a change").
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local ROOT = "mods/hoenn_voxel"

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- ------- through the loader

do
  local run = T.sdk.loadMod(ROOT, { generation = 3, data = T.sdk.gen3Data() })
  eq(#run.errors, 0, "loads clean on a Gen 3 boot (" .. tostring(run.errors[1]) .. ")")
  local rec = run.data.render_pipelines and run.data.render_pipelines.hoenn_voxel
  check(rec ~= nil, "registers the hoenn_voxel render pipeline")
  if rec then
    eq(rec.label, "VOXEL", "its options row reads VOXEL")
    eq(rec.generations and rec.generations[1], 3, "it asks for the Gen 3 ctx")
    eq(#rec.levels, 4, "OFF and three angles")
    check(type(rec.drawWorld) == "function", "it draws the world")
  end
  local manifest = assert(load("return " .. readFile(ROOT .. "/manifest.json")
    :gsub('"([%w_]+)":', '%1 =')
    :gsub("%[", "{"):gsub("%]", "}")))()
  eq(manifest.id, "hoenn_voxel", "the manifest names the mod")
  eq(manifest.permissions[1], "background", "it asks for background jobs")
end

-- ------- the libs, standalone

local loaded = {}
local function lib(name)
  if loaded[name] == nil then
    local path = (name:find("/", 1, true) and name or "lib/" .. name) .. ".lua"
    local chunk = assert(loadstring(readFile(ROOT .. "/" .. path), "@" .. path))
    loaded[name] = chunk(lib, nil)
  end
  return loaded[name]
end

local Relief = lib("Relief")
local Builder = lib("Builder")
local Terrain = lib("Terrain")
local Mat = lib("Mat")
local Camera = lib("Camera")
local TD = lib("data/terrain")

-- ------- the lift identity: every surface the builder lays is the drawing
-- at 45 degrees, z - y = v for every vertex, whatever its height

local ATLAS = { width = 256, height = 1024 }
function ATLAS.slot(mid) return mid end
function ATLAS.origin(mid) return (mid % 16) * 16, math.floor(mid / 16) * 16 end

local function scene(cells, reliefs)
  return {
    cell = function(ax, ay)
      local c = cells[ay * 100 + ax]
      if c then return c end
      return { mid = 1, pair = "p" }
    end,
    relief = function(ax, ay) return reliefs[ay * 100 + ax] or Relief.FLAT end,
    atlas = function() return ATLAS end,
    over = function() return false end,
  }
end

-- the drawn pixel of each vertex, back from its texture coordinates
local function drawn(v, cellOf)
  local s, t = v[4] * ATLAS.width, v[5] * ATLAS.height
  return s, t
end

local function checkIdentity(b, label, cellAt)
  local bad, total = 0, 0
  for _, key in ipairs(b.order) do
    for _, v in ipairs(b.batches[key].verts) do
      total = total + 1
      -- the vertex's texel, as a world position: the cell it is in (from its
      -- x and its drawn row) plus the texel inside the metatile
      local s, t = v[4] * ATLAS.width, v[5] * ATLAS.height
      local lu, lv = s % 16, t % 16
      if lu == 0 and s > 0 and (s / 16) % 1 == 0 then lu = 16 end
      if lv == 0 and t > 0 and (t / 16) % 1 == 0 then lv = 16 end
      local x, y, z = v[1], v[2], v[3]
      local v2d = z - y
      local cy = cellAt(x, v2d)
      local expect = cy * 16 + lv
      if math.abs(v2d - expect) > 1e-6 and math.abs(v2d - (expect - 16)) > 1e-6
          and math.abs(v2d - (expect + 16)) > 1e-6 then
        bad = bad + 1
      end
    end
  end
  check(total > 0, label .. ": something was built")
  eq(bad, 0, label .. ": every vertex is its drawn pixel at 45 degrees")
end

do
  for kind in pairs(Relief.PIECES) do
    local reliefs = { [5 * 100 + 5] = Relief.piece(kind, 32) }
    local b = Builder.new(scene({}, reliefs))
    b:surface("p", 1, "under", reliefs[505], 5, 5)
    checkIdentity(b, "piece " .. kind, function(_, v) return math.floor(v / 16) end)
  end
  -- a profiled cell (a ledge's berm)
  local r = Relief.profile("v", { { 0, 0 }, { 2, 0 }, { 10, 6 }, { 16, 0 } }, "ledge")
  local b = Builder.new(scene({}, { [505] = r }))
  b:surface("p", 1, "under", r, 5, 5)
  checkIdentity(b, "a berm", function(_, v) return math.floor(v / 16) end)
end

-- the steps between cells: a plateau with a face, a band and a drop
do
  local reliefs = {}
  for x = 2, 6 do
    reliefs[2 * 100 + x] = Relief.flat(16)
    reliefs[3 * 100 + x] = Relief.piece("S", 16)
  end
  reliefs[2 * 100 + 7] = Relief.piece("E", 16)
  reliefs[3 * 100 + 7] = Relief.piece("cSE", 16)
  reliefs[2 * 100 + 1] = Relief.piece("W", 16)
  reliefs[5 * 100 + 9] = Relief.flat(16)     -- a lone block: a drop on every side
  local b = Builder.new(scene({}, reliefs))
  b:block(0, 0, 12, 8)
  -- every quad but the run-ons under a higher cell (never seen at 45): the
  -- run-on is shade 1 and lies flat, so check only what is not flat and lit
  local keep = Builder.new(scene({}, reliefs))
  for _, key in ipairs(b.order) do
    local list = b.batches[key].verts
    local out = keep:batch({ key = key, kind = "atlas", pair = "p", layer = "under" }).verts
    for i = 1, #list, 3 do
      local a, c, d = list[i], list[i + 1], list[i + 2]
      local flatLit = a[2] == c[2] and c[2] == d[2] and a[6] == 1
      local runOn = flatLit and a[2] < 16 and (a[3] - a[2]) % 16 ~= 0
      if not runOn then out[#out + 1] = a; out[#out + 1] = c; out[#out + 1] = d end
    end
  end
  checkIdentity(keep, "a plateau and its steps", function(_, v) return math.floor(v / 16) end)
  check(b.tris > 12 * 8 * 2, "the steps were closed (" .. b.tris .. " triangles)")
end

-- edges of reliefs
do
  local r = Relief.piece("S", 32)
  local e = Relief.edge(r, "W")
  eq(e[1][2], 32, "a face's west edge starts at its top")
  eq(e[2][2], 16, "and ends a level down")
  local p = Relief.profile("u", { { 0, 0 }, { 6, 6 }, { 16, 0 } }, "ridge")
  eq(#Relief.edge(p, "N"), 3, "a ridge's north edge follows its profile")
  eq(Relief.edge(p, "W")[1][2], 0, "its west edge is level")
  eq(Relief.at(p, 6 / 16, 0.5), 6, "it peaks where its profile does")
end

-- ------- terrain: counted levels

-- a reading of a metatile: shares of top and face, as Tiles.lua writes them
local function reading(t, f)
  local cls = {}
  for i = 1, 256 do
    local r = (i - 1) / 256
    cls[i] = r < t and "T" or (r < t + f and "F" or "G")
  end
  return { t = t, f = f, faceLow = math.floor(f * 224), rim = 0, gTop = 0, leafU = 0, leafO = 0,
    cover = 0, cls = table.concat(cls) }
end

local function map(rows, legend)
  local h, w = #rows, #rows[1]
  local cells, tiles = {}, {}
  for y = 1, h do
    for x = 1, w do
      local ch = rows[y]:sub(x, x)
      local spec = legend[ch]
      cells[(y - 1) * w + x] = { m = spec.m, walk = spec.walk, water = spec.water or false }
      tiles[spec.m] = tiles[spec.m] or spec.tile
    end
  end
  return { w = w, h = h, general = true, cells = cells, tiles = tiles }
end

local LEGEND = {
  ["."] = { m = 0x001, walk = true, tile = reading(0, 0) },          -- grass
  T = { m = 0x071, walk = false, tile = reading(1, 0) },             -- a top
  t = { m = 0x071, walk = true, tile = reading(1, 0) },              -- a walked top
  F = { m = 0x07c, walk = false, tile = reading(0, 1) },             -- a face
  W = { m = 0x070, walk = false, tile = reading(0.5, 0.4) },         -- a band falling west
  E = { m = 0x072, walk = false, tile = reading(0.5, 0.4) },         -- a band falling east
}

do
  local input = map({
    "..........",
    ".WttttttE.",
    ".WttttttE.",
    ".FFFFFFFF.",
    "..........",
    "..........",
  }, LEGEND)
  local r = Terrain.solve(input, TD)
  local function at(x, y) return y * input.w + x + 1 end
  eq(r.top[at(0, 0)], 0, "the grass is the ground")
  eq(r.top[at(4, 1)], 16, "the plateau's top stands a level up")
  eq(r.kind[at(4, 1)], "F", "and is level")
  eq(r.kind[at(4, 3)], "S", "its face is a face")
  eq(r.top[at(4, 3)], 16, "hanging from the top")
  eq(r.kind[at(1, 1)], "W", "its west band falls west")
  eq(r.kind[at(8, 1)], "E", "its east band falls east")
  eq(r.top[at(1, 1)], 16, "from the plateau's level")
  eq(r.top[at(4, 5)], 0, "the grass south of the face is the ground again")
end

do
  -- two levels: a terrace on a terrace
  local input = map({
    "........",
    "..tttt..",
    "..FFFF..",
    ".tttttt.",
    ".tttttt.",
    ".FFFFFF.",
    "........",
  }, LEGEND)
  local r = Terrain.solve(input, TD)
  local function at(x, y) return y * input.w + x + 1 end
  eq(r.top[at(3, 1)], 32, "the upper terrace stands two levels up")
  eq(r.top[at(3, 3)], 16, "the lower one level up")
  eq(r.kind[at(3, 2)], "S", "the upper face")
  eq(r.top[at(3, 2)], 32, "hangs from the upper terrace")
end

-- ------- the camera frames the flat field's width at the focus

do
  local cam = Camera.new()
  cam:update(0, 45)
  cam:frame(1000, 0, 2000, 720, 480, 240)
  local sx, sy = cam:project(1000, 0, 2000)
  check(math.abs(sx - 360) < 1e-6 and math.abs(sy - 240) < 1e-6, "the focus is the canvas's centre")
  -- points on the plane square to the view at the focus, vw apart
  local right = { Mat.norm(cam.view[1][1], cam.view[1][2], cam.view[1][3]) }
  local ex = cam:project(1000 + right[1] * 120, right[2] * 120, 2000 + right[3] * 120)
  check(math.abs(ex - 720) < 1e-3, "half the flat field's width east of it is the canvas's edge")
  local x0, x1 = cam:groundBounds(-48, 64)
  check(x0 < 1000 - 120 and x1 > 1000 + 120, "the bounds cover the view")
end

T.finish()
