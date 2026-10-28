-- Standalone, from the engine root:
--   luajit mods/hoenn_diorama/tests/hoenn_diorama_test.lua
--
-- Headless: the shapes, the mesher, the camera and the chunk cache are pure
-- Lua and are tested on small hand-made maps; the mod itself is loaded
-- through the real loader on a Gen 3 dataset to check what it registers.
-- Rendering is exercised separately on a real GPU (see README, "Checking a
-- change").
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local check, eq = T.check, T.eq

local ROOT = "mods/hoenn_diorama"

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local loaded = {}
local function lib(name)
  if not loaded[name] then
    local chunk = assert(loadstring(readFile(ROOT .. "/lib/" .. name .. ".lua"), "@" .. name))
    loaded[name] = chunk(lib)
  end
  return loaded[name]
end

local Shape = lib("Shape")
local Mesher = lib("Mesher")
local Camera = lib("Camera")
local World = lib("World")
local Cutouts = lib("Cutouts")
local Hip = lib("Hip")

-- ------- a tiny map language
--
--   .  floor          #  structure (blocked, elevation 0)
--   o  overhang       s  object (blocked, elevation 3)
--   ~  water          g  tall grass       v  ledge
--   D  door           (space) blank
-- Anything outside the drawing is floor.
local function grid(rows)
  local cells = {}
  for y, row in ipairs(rows) do
    for x = 1, #row do
      local ch = row:sub(x, x)
      cells[(x - 1) .. "," .. (y - 1)] = ch
    end
  end
  local memo = {}
  return function(cx, cy)
    local k = cx .. "," .. cy
    local c = memo[k]
    if c then return c end
    local ch = cells[k] or "."
    c = { mid = 1, pair = "p", elev = 3, walk = true, over = 0 }
    if ch == "#" then c.walk, c.elev = false, 0
    elseif ch == "s" then c.walk = false
    elseif ch == "o" then c.over = 0.5
    elseif ch == "~" then c.walk, c.beh = false, "POND_WATER"
    elseif ch == "g" then c.beh = "TALL_GRASS"
    elseif ch == "v" then c.beh = "JUMP_SOUTH"
    elseif ch == "D" then c.walk, c.elev, c.beh = false, 0, "WARP_DOOR"
    elseif ch == " " then c.mid = nil end
    c.kind = Shape.classify(c)
    memo[k] = c
    return c
  end
end

local function build(info, x0, y0, x1, y1, params)
  local quads = {}
  Shape.build(info, x0, y0, x1, y1, params or { cap = 2, tuft = 5 }, function(q)
    quads[#quads + 1] = q
  end)
  return quads
end

local function pick(quads, kind, layer)
  local out = {}
  for _, q in ipairs(quads) do
    if q.kind == kind and (layer == nil or q.layer == layer) then out[#out + 1] = q end
  end
  return out
end

-- a quad's or a polygon's corners as {x, y, z}
local function corners(q)
  local out = {}
  if q.poly then
    for i, v in ipairs(q.poly) do out[i] = { v[1], v[2], v[3] } end
  else
    for i = 0, 3 do out[i + 1] = { q.p[i * 3 + 1], q.p[i * 3 + 2], q.p[i * 3 + 3] } end
  end
  return out
end

local function extent(q, k)
  local lo, hi = math.huge, -math.huge
  for _, c in ipairs(corners(q)) do
    lo, hi = math.min(lo, c[k]), math.max(hi, c[k])
  end
  return lo, hi
end

-- every opaque quad that is not upright (a floor, a roof, a slope): the
-- cells under its footprint, as a set
local function coverage(quads)
  local covered = {}
  for _, q in ipairs(quads) do
    local x0, x1 = extent(q, 1)
    local z0, z1 = extent(q, 3)
    if q.layer == "u" and x1 - x0 > 0.01 and z1 - z0 > 0.01 then
      for cx = math.floor(x0 / 16), math.ceil(x1 / 16) - 1 do
        for cz = math.floor(z0 / 16 + 1e-6), math.ceil(z1 / 16 - 1e-6) - 1 do
          covered[cx .. "," .. cz] = true
        end
      end
    end
  end
  return covered
end

-- The 45 degree camera sees a point (y, z) at screen row z - y: a quad
-- whose every corner keeps z - y on its art row is exactly where the 2D
-- field drew it.
local function onArt(q)
  local p = q.p
  local top, bottom = p[3] - p[2], p[9] - p[8]
  return top, bottom
end

-- ------- classification

do
  eq(Shape.classify({ mid = 1, walk = true, over = 0 }), "floor", "walkable is floor")
  eq(Shape.classify({ mid = 1, walk = true, over = 0.3 }), "overhang", "walkable under BG1 art is an overhang")
  eq(Shape.classify({ mid = 1, walk = true, over = 0.01 }), "floor", "a stray overhead pixel is not a canopy")
  eq(Shape.classify({ mid = 1, walk = false, elev = 0 }), "solid", "blocked on the structure layer is solid")
  eq(Shape.classify({ mid = 1, walk = false, elev = 3 }), "object", "blocked on the walking layer is an object")
  eq(Shape.classify({ mid = 1, walk = false, beh = "DEEP_WATER" }), "water", "unwalkable water")
  eq(Shape.classify({ mid = 1, walk = true, beh = "SHALLOW_WATER" }), "floor", "shallow water is ground")
  eq(Shape.classify({ mid = 1, walk = false, beh = "JUMP_SOUTH" }), "ledge", "a ledge")
  eq(Shape.classify({ mid = 1, walk = true, elev = 3, beh = "WARP_DOOR" }), "solid", "a door is structure")
  eq(Shape.classify({ mid = nil }), "blank", "a blanked void cell")
end

-- ------- Hip: the solids

do
  -- Littleroot's house: 5 cells wide, drawn in 5 rows over 4 of collision,
  -- its walls 28 high
  local b = Hip.block({ x0 = 0, x1 = 80, zf = 80, zb = 16, vt = 0, hw = 28, building = true })
  eq(b.kind, "hip", "a building is hipped")
  check(math.abs(b.t - (2 * (80 - 28) / 64 - 1)) < 1e-9, "at the slope that lays the drawn roof over the front half")
  eq(b.zr, 48, "its ridge over the middle of the footprint")
  check(math.abs(Hip.height(b, 40, 48) - (28 + b.t * 32)) < 1e-9, "as high as the slope makes it")
  eq(Hip.height(b, 0, 60), 28, "its eaves at the walls")
  -- every point of the roof is covered once: the faces' footprints and,
  -- piece by piece, what the drawing's cells give them
  local foot = 0
  for _, poly in pairs(b.roof) do foot = foot + math.abs(Hip.area(poly)) end
  check(math.abs(foot - 80 * 64) < 1e-6, "the faces tile the footprint")
  local covered = 0
  for cy = 0, 4 do
    for cx = 0, 4 do
      for _, pc in ipairs(Hip.pieces(b, cx, cy, 16)) do
        if pc.face ~= "wall" and pc.face ~= "foot" then
          local xz = {}
          for i, v in ipairs(pc.poly) do xz[i] = { v[1], v[3] } end
          covered = covered + math.abs(Hip.area(xz))
        end
      end
    end
  end
  check(math.abs(covered - 80 * 64) < 1e-3, "the drawing and its mirror cover the whole roof (" .. covered .. ")")

  -- a drawing too shallow for its footprint (every row of it collision): the
  -- solid only as deep as the drawing makes it at a sensible slope, its
  -- walls as drawn, the collision behind it open
  local low = Hip.block({ x0 = 0, x1 = 64, zf = 64, zb = 0, vt = 0, hw = 32, building = true })
  check(math.abs(low.t - Hip.T_LOW) < 1e-9 and low.hw == 32, "a shallow drawing keeps its walls and a sloped roof")
  check(low.open and math.abs(low.zb - (64 - 2 * 32 / (1 + Hip.T_LOW))) < 1e-9, "standing short of the collision's back")
  local foot = 0
  for _, poly in pairs(low.roof) do foot = foot + math.abs(Hip.area(poly)) end
  check(math.abs(foot - 64 * (64 - low.zb)) < 1e-6, "its faces tile its own footprint")
  -- too little roof drawn to stand even that deep: lower walls instead
  local lower = Hip.block({ x0 = 0, x1 = 64, zf = 64, zb = 0, vt = 16, hw = 38, building = true })
  check(not lower.open and lower.t >= Hip.T_MIN - 1e-9 and lower.hw < 38, "lower walls keep the roof sloped")
  local wall = Hip.block({ x0 = 0, x1 = 64, zf = 64, zb = 16, vt = 0, hw = 32 })
  eq(wall.kind, "flat", "without a door: a flat top")
  eq(Hip.back(wall)[1][3] - Hip.back(wall)[1][2], 0, "and its back edge-on at 45 degrees")
end

-- ------- Relief: the height of the ground, counted off the drawing

local Relief = lib("Relief")
do
  -- a map language for the relief, on the General tileset's pieces:
  --   .  ground     T  mountain top     F  face      c  corner piece
  --   W  band, high side east           E  band, high side west
  --   ~  water      o  a tree           v  a ledge
  local PIECE = {
    ["."] = { mid = 0x001, walk = true },
    T = { mid = 0x071, walk = true, beh = "MOUNTAIN_TOP" },
    F = { mid = 0x07c }, c = { mid = 0x07b }, W = { mid = 0x070 }, E = { mid = 0x072 },
    ["~"] = { mid = 0x170, beh = "OCEAN_WATER" },
    o = { mid = 0x00b }, v = { mid = 0x001, beh = "JUMP_SOUTH" },
    R = { mid = 0x271, beh = "MOUNTAIN_TOP" },   -- a town's own cliff
  }
  local function solve(rows)
    local function sample(x, y)
      local p = PIECE[rows[y + 1]:sub(x + 1, x + 1)]
      return { mid = p.mid, pair = "gTileset_General+gTileset_Petalburg", walk = p.walk == true, beh = p.beh }
    end
    return Relief.solve(sample, #rows[1], #rows)
  end
  local function at(r, x, y) return table.concat({ r.corners(x, y) }, ",") end
  local G = "gTileset_General+gTileset_Petalburg"

  eq(Relief.classify({ mid = 0x07c, pair = G }), "rock", "a face is rock")
  eq(select(2, Relief.classify({ mid = 0x07c, pair = G })), "face", "with its role")
  eq(select(2, Relief.classify({ mid = 0x070, pair = G })), "bandW", "a band falling west")
  eq(select(2, Relief.classify({ mid = 0x072, pair = G })), "bandE", "a band falling east")
  eq(Relief.classify({ mid = 0x071, pair = G, walk = true, beh = "MOUNTAIN_TOP" }), "top", "a mountain top")
  eq(Relief.classify({ mid = 0x07c, pair = "gTileset_Building+gTileset_Shop" }), "other",
    "the same number on another tileset is not a mountain")
  eq(Relief.classify({ mid = 0x07c, pair = G, beh = "OCEAN_WATER" }), "water", "rock art over water is water")
  eq(Relief.classify({ mid = 0x093, pair = G }), "other", "a boulder stands")
  eq(Relief.classify({ mid = 0x001, pair = G, beh = "JUMP_SOUTH" }), "ledge", "a ledge")
  eq(Relief.classify({ mid = 0x001, pair = G, walk = true }), "ground", "ground")
  eq(Relief.classify({ mid = nil }), "void", "nothing")

  -- a terrace: a face between a top and the ground in front; behind it,
  -- ground of its own
  local r = solve({ "....", "TTTT", "FFFF", "...." })
  eq(at(r, 0, 1), "16,16,16,16", "the top a level up")
  eq(at(r, 1, 2), "16,16,0,0", "the face hangs from it, a vertical wall")
  check(r.surface(1, 2) and not r.surface(1, 1), "the face is its own surface, the top is not")
  eq(at(r, 2, 3), "0,0,0,0", "the ground in front at 0")
  eq(at(r, 2, 0), "0,0,0,0", "the ground behind on its own, at 0")
  eq(r.levels, 2, "two levels")

  -- two faces: two levels
  r = solve({ "TTT", "FFF", "FFF", "..." })
  eq(at(r, 1, 0), "32,32,32,32", "two faces under a top: two levels")
  eq(at(r, 1, 1), "32,32,16,16", "the upper face")
  eq(at(r, 1, 2), "16,16,0,0", "the lower face")

  -- a band: a 45 degree slope a level across
  r = solve({ "..WTT", "..WTT", "....." })
  eq(at(r, 3, 0), "16,16,16,16", "the top beside a band a level up")
  eq(at(r, 2, 0), "0,16,16,0", "the band rises east")
  r = solve({ "TTE..", "TTE..", "....." })
  eq(at(r, 2, 1), "16,0,0,16", "and the other way")

  -- a rock in the sea: two bands back to back, a crest a level over the sea
  r = solve({ "~~~~", "~WE~", "~cc~", "~~~~" })
  eq(at(r, 1, 1), "0,16,16,0", "the crest rises from the sea")
  eq(at(r, 2, 1), "16,0,0,16", "and falls to it")
  check(r.surface(1, 2), "its foot meets them")

  -- rocks in the sea: the sea is one level on both sides
  r = solve({ "~~~~", "cFFc", "~~~~" })
  eq(at(r, 0, 0), at(r, 0, 2), "rocks in the sea do not raise the sea")

  -- a wood on a cliff, no ground in sight: the faces under it count
  r = solve({ "oooo", "oooo", "FFFF", "...." })
  eq(at(r, 1, 0), "16,16,16,16", "trees over a face stand on its top")
  eq(at(r, 1, 2), "16,16,0,0", "and the face hangs from them")
  -- corner pieces stacked down a terrace's diagonal edge are no levels
  r = solve({ ".o..", ".c..", ".c..", "...." })
  eq(at(r, 1, 0), "0,0,0,0", "two corner pieces under a tree raise nothing")

  -- what stands between a top in front and ground behind stands on that
  -- ground (the top's north edge is its back)
  r = solve({ ".....", "ooooo", "TTTTT", "FFFFF", "....." })
  eq(at(r, 2, 2), "16,16,16,16", "the top a level up")
  eq(at(r, 2, 1), "0,0,0,0", "the trees behind it on the ground")
  -- but in front of a face, on the cliff's top
  r = solve({ "TTTTT", "ooooo", "FFFFF", "....." })
  eq(at(r, 2, 1), "16,16,16,16", "trees at a cliff's edge on its top")

  -- mountains drawn with a town's own tiles are not counted: the map lies
  -- flat rather than half counted
  r = solve({ "RRRRR", "RTTTR", "RFFFR", "....." })
  eq(at(r, 2, 1), "0,0,0,0", "a map of the town's own cliffs lies flat")
  eq(r.levels, 1, "one level")
  r = solve({ "RRR..", "TTTTT", "FFFFF", "....." })
  eq(at(r, 2, 1), "16,16,16,16", "a few of them do not flatten the General's mountains")

  -- past the map's edge: the level most of that edge has
  r = solve({ "TT...", "FF...", "....." })
  eq(at(r, 1, -1), "0,0,0,0", "the border north lies at the edge's usual level")
  eq(at(r, 1, 5), "0,0,0,0", "and south")
  r = solve({ "TTTT.", "FFFF.", "....." })
  eq(at(r, 1, -3), "16,16,16,16", "whatever the edge's usual level is")
end

-- relief in the shapes: corners lift a cell, steps close what differs
do
  local cells = {}
  local function put(x, y, kind, h, extra)
    local c = { mid = 1, pair = "p", elev = 3, walk = kind == "floor", over = 0, kind = kind,
      rNW = h[1], rNE = h[2], rSE = h[3], rSW = h[4] }
    if kind == "water" then c.beh = "POND_WATER" end
    for k, v in pairs(extra or {}) do c[k] = v end
    cells[x .. "," .. y] = c
  end
  local function info(x, y)
    return cells[x .. "," .. y] or { mid = 1, pair = "p", elev = 3, walk = true, over = 0, kind = "floor",
      rNW = 0, rNE = 0, rSE = 0, rSW = 0 }
  end
  -- a face (relief) at (1, 1) under a top at 16; the ground in front at 0;
  -- water east of the face; the top east of the top
  for x = 0, 3 do put(x, 0, "floor", { 16, 16, 16, 16 }) end
  put(1, 1, "solid", { 16, 16, 0, 0 }, { relief = true })
  put(0, 1, "solid", { 16, 16, 0, 0 }, { relief = true })
  put(2, 1, "water", { 0, 0, 0, 0 })
  local quads = build(info, 0, 0, 4, 3)
  local face
  for _, q in ipairs(pick(quads, "relief", "u")) do
    local x0, x1 = extent(q, 1)
    if x0 == 16 and x1 == 32 then face = face or {} face[#face + 1] = q end
  end
  check(face and #face >= 1, "a relief cell is drawn as its own surface")
  local top, bottom = math.huge, -math.huge
  for _, q in ipairs(face or {}) do
    for _, v in ipairs(corners(q)) do
      top, bottom = math.min(top, v[3] - v[2]), math.max(bottom, v[3] - v[2])
      check(math.abs(v[1] - 16) < 1e-6 or math.abs(v[1] - 32) < 1e-6, "on its cell")
    end
  end
  eq(top, 16, "seen at 45 degrees from its drawing's top row")
  eq(bottom, 32, "to its bottom row")
  -- the top behind, lifted by 16 and moved 16 south: still where it was drawn
  local lifted
  for _, q in ipairs(pick(quads, "floor", "u")) do
    local x0 = extent(q, 1)
    local y0 = extent(q, 2)
    local z0 = extent(q, 3)
    if x0 == 0 and y0 == 16 then lifted = z0 end
  end
  eq(lifted, 16, "a lifted cell slides south as far as it rises")
  -- the step from the face down to the water east of it meets the water
  -- line straight down (the water is not slid)
  local drop = Shape.defaults.waterDrop
  local low
  for _, q in ipairs(pick(quads, "step", "u")) do
    local x0, x1 = extent(q, 1)
    if x0 == 32 and x1 == 32 then
      for _, v in ipairs(corners(q)) do
        if v[2] < 0 then low = low or {} low[#low + 1] = v end
      end
    end
  end
  check(low ~= nil, "a step closes the face's side over the water")
  for _, v in ipairs(low or {}) do
    eq(v[2], -drop, "down to the water line")
    check(v[3] >= 16 and v[3] <= 32, "on the cell's own edge, not slid")
  end
end

-- a ground lifted as a whole moves every quad by (0, h, h) and nothing else
-- (a house, a wall with overhead art, a sign, water, a ledge)
do
  local flat = grid({
    "..........",
    ".ooo..oo..",
    ".###..##.~",
    ".###..##.~",
    ".#D#.....~",
    "..s..v...~",
    "..........",
  })
  local function raised(h)
    local memo = {}
    return function(x, y)
      local k = x .. "," .. y
      if not memo[k] then
        local c = {}
        for kk, v in pairs(flat(x, y)) do c[kk] = v end
        c.rNW, c.rNE, c.rSE, c.rSW = h, h, h, h
        memo[k] = c
      end
      return memo[k]
    end
  end
  local function key(q, h)
    local parts = { q.kind, q.layer, tostring(q.mid), tostring(q.art) }
    for _, v in ipairs(corners(q)) do
      parts[#parts + 1] = string.format("%.2f,%.2f,%.2f", v[1], v[2] - h, v[3] - h)
    end
    return table.concat(parts, " ")
  end
  local a, b = {}, {}
  for _, q in ipairs(build(raised(0), -1, -1, 11, 8)) do a[#a + 1] = key(q, 0) end
  for _, q in ipairs(build(raised(48), -1, -1, 11, 8)) do b[#b + 1] = key(q, 48) end
  table.sort(a)
  table.sort(b)
  eq(#b, #a, "as many quads lifted as flat")
  local same, first = #a == #b, nil
  for i = 1, math.min(#a, #b) do
    if a[i] ~= b[i] then same = false first = first or (a[i] .. " / " .. b[i]) end
  end
  check(same, "every quad lifted by (0, 48, 48), overhead copies once (" .. tostring(first) .. ")")
end

-- ------- a two-storey house: its upper storey stands on a skirt

do
  -- Littleroot's: 80 wide, drawn 80 high over 64 of collision, walls 28
  -- high, the upper storey's front a band of wall rows 36..44 set 14 in
  local b = Hip.block({ x0 = 0, x1 = 80, zf = 80, zb = 16, vt = 0, hw = 28, building = true,
    tier = { vtop = 36, vb = 45, inset = 14 } })
  eq(b.kind, "hip", "a building")
  check(b.upper ~= nil, "two storeys")
  if b.upper then
    local u = b.upper
    check(math.abs(u.y1 - u.y0 - 9) < 1e-6, "the upper walls as high as the band")
    check(u.x0 == 14 and u.x1 == 66, "set in as the drawing sets them")
    check(u.y0 > 28, "standing on the skirt, over the eaves")
    local foot = 0
    for _, f in ipairs(b.faces) do foot = foot + math.abs(Hip.area(f.foot)) end
    check(math.abs(foot - 80 * 64) < 1e-6, "skirt and upper roof tile the footprint")
    local covered, exact, band = 0, true, true
    local bandLo, bandHi = math.huge, -math.huge
    for cy = 0, 4 do
      for cx = 0, 4 do
        for _, pc in ipairs(Hip.pieces(b, cx, cy, 16)) do
          if pc.face ~= "wall" and pc.face ~= "foot" and pc.face ~= "upper" then
            local xz = {}
            for i, v in ipairs(pc.poly) do xz[i] = { v[1], v[3] } end
            covered = covered + math.abs(Hip.area(xz))
          end
          if not pc.mirror then
            for _, v in ipairs(pc.poly) do
              if math.abs(v[4] - (v[1] - cx * 16)) > 1e-6
                  or math.abs(v[5] - ((v[3] - v[2]) - cy * 16)) > 1e-6 then exact = false end
              if pc.face == "upper" then
                if (v[3] - v[2]) < 36 - 0.2 or (v[3] - v[2]) > 45 + 1e-6 then band = false end
                bandLo, bandHi = math.min(bandLo, v[3] - v[2]), math.max(bandHi, v[3] - v[2])
              end
            end
          end
        end
      end
    end
    check(math.abs(covered - 80 * 64) < 1e-3, "the drawing and its mirror cover the whole roof (" .. covered .. ")")
    check(exact, "every face shows the drawing at 45 degrees")
    check(band, "the upper storey's front is the band")
    check(bandLo <= 36 and bandHi >= 45 - 1e-6, "all of it")
    check(Hip.height(b, 40, 48) > u.y1, "its ridge over the upper walls")
    check(math.abs(Hip.height(b, 2, 48) - (28 + (b.skirt.west[2]) * 2)) < 1e-6, "the skirt at the side")
  end
  -- a band the slopes cannot stand up: one hip, as before
  local one = Hip.block({ x0 = 0, x1 = 80, zf = 80, zb = 16, vt = 0, hw = 28, building = true,
    tier = { vtop = 3, vb = 50, inset = 14 } })
  eq(one.upper, nil, "a band with no roof over it is not a storey")

  -- read off the drawing: rows of roof, a band of the walls' plaster set in
  -- from the sides, a skirt, the eaves' dark line and the walls
  local PLASTER, DARK, ROOF1, ROOF2 = 0xd5d5c5, 0x414a6a, 0xdeac73, 0x9c6a73
  local function colourAt(bx, r)
    -- bx: 0..79 across the house, r: 0..79 down its drawing
    if r >= 52 then return (r == 52 or r == 53 or r >= 76) and DARK or PLASTER end
    if r >= 36 and r <= 44 and bx >= 14 and bx < 66 then return (r == 36 or r == 44) and DARK or PLASTER end
    return (bx + r) % 2 == 0 and ROOF1 or ROOF2
  end
  local flat = grid({ ".......", ".ooooo.", ".#####.", ".#####.", ".#####.", ".##D##.", "......." })
  local function cells(cx, cy)
    local c = flat(cx, cy)
    if cx >= 1 and cx <= 5 and cy >= 1 and cy <= 5 then
      local d = {}
      for k, v in pairs(c) do d[k] = v end
      d.mid = 100 + cy * 10 + cx
      return d
    end
    return c
  end
  local function px(c)
    if not c.mid or c.mid < 100 then
      local t = {}
      for i = 0, 255 do t[i] = 0x55aa55 end
      return t
    end
    local cy, cx = math.floor((c.mid - 100) / 10), (c.mid - 100) % 10
    local t = {}
    for y = 0, 15 do
      for x = 0, 15 do t[y * 16 + x] = colourAt((cx - 1) * 16 + x, (cy - 1) * 16 + y) end
    end
    return t
  end
  local q = build(cells, 0, 0, 7, 7, { cap = 2, tuft = 0, pixels = px, composite = px })
  local upper, sides = 0, 0
  for _, f in ipairs(q) do
    if f.face == "upper" and not f.mirror then upper = upper + 1 end
  end
  for _, f in ipairs(pick(q, "side", "u")) do
    local _, y1 = extent(f, 2)
    if y1 > 30 then sides = sides + 1 end
  end
  check(upper > 0, "the band is read as an upper storey's front")
  check(sides > 0, "with side walls up there")
  -- without the band (a plain roof), one hip
  local plainRoof = function(c)
    local t = px(c)
    for i = 0, 255 do if t[i] == PLASTER and c.mid and c.mid < 140 then t[i] = ROOF1 end end
    return t
  end
  local q2 = build(cells, 0, 0, 7, 7, { cap = 2, tuft = 0, pixels = plainRoof, composite = plainRoof })
  local up2 = 0
  for _, f in ipairs(q2) do if f.face == "upper" then up2 = up2 + 1 end end
  eq(up2, 0, "a plain roof is one storey")
end

-- ------- the eaves read past a strip of glass across the front (a shop's
-- sign under its awning, the tops of a row of windows)

do
  local PLASTER, GLASS, ROOF1, ROOF2 = 0xd5d5c5, 0x6aa4e6, 0x3a62b4, 0x2a4a8c
  local function colourAt(bx, r)
    local up = 63 - r
    if up >= 28 then return (bx + r) % 2 == 0 and ROOF1 or ROOF2 end
    if up >= 14 and up <= 17 then return GLASS end
    return PLASTER
  end
  local flat = grid({ "......", ".oooo.", ".####.", ".####.", ".#D##.", "......" })
  local function cells(cx, cy)
    local c = flat(cx, cy)
    if cx >= 1 and cx <= 4 and cy >= 1 and cy <= 4 then
      local d = {}
      for k, v in pairs(c) do d[k] = v end
      d.mid = 100 + cy * 10 + cx
      return d
    end
    return c
  end
  local function px(c)
    local t = {}
    if not c.mid or c.mid < 100 then
      for i = 0, 255 do t[i] = 0x55aa55 end
      return t
    end
    local cy, cx = math.floor((c.mid - 100) / 10), (c.mid - 100) % 10
    for y = 0, 15 do
      for x = 0, 15 do t[y * 16 + x] = colourAt((cx - 1) * 16 + x, (cy - 1) * 16 + y) end
    end
    return t
  end
  local q = build(cells, 0, 0, 6, 6, { cap = 2, tuft = 0, pixels = px })
  local top = 0
  for _, f in ipairs(pick(q, "facade", "u")) do
    if f.face == "wall" then
      local _, y1 = extent(f, 2)
      top = math.max(top, y1)
    end
  end
  check(math.abs(top - 28) < 0.5, "the walls reach the roof, past the glass (" .. top .. ")")
end

-- ------- a house: overhang ridge, three solid rows, a door in front

-- the area of a polygon's projection at 45 degrees (u = x, v = z - y)
local function projArea(q)
  local pts = {}
  for i, c in ipairs(corners(q)) do pts[i] = { c[1], c[3] - c[2] } end
  local s = 0
  for i = 1, #pts do
    local a, b = pts[i], pts[i % #pts + 1]
    s = s + a[1] * b[2] - b[1] * a[2]
  end
  return math.abs(s / 2)
end

do
  local info = grid({
    ".....",
    ".ooo.",
    ".###.",
    ".###.",
    ".#D#.",
    ".....",
  })
  local q = build(info, 0, 0, 5, 6)
  -- the block: x 16..64, the drawing from v = 16 (the overhang row) to the
  -- front at z = 80, the collision from z = 32; walls 32 high
  local facade = pick(q, "facade", "u")
  check(#facade > 0, "the front wall stands")
  for _, f in ipairs(facade) do
    local z0, z1 = extent(f, 3)
    check(math.abs(z0 - 80) < 1e-6 and math.abs(z1 - 80) < 1e-6, "on the house's front edge")
  end
  local roof = pick(q, "roof", "u")
  local faces, ridge, eave = {}, 0, math.huge
  for _, r in ipairs(roof) do
    faces[r.face] = true
    local y0, y1 = extent(r, 2)
    ridge, eave = math.max(ridge, y1), math.min(eave, y0)
  end
  check(faces.front and faces.west and faces.east and faces.back, "a roof hipped on all four sides")
  eq(eave, 32, "its eaves at the walls' height")
  check(ridge > 36, "rising to a ridge (" .. ridge .. ")")
  local opaque = #roof > 0
  local topOver, lowerOver = false, false
  for _, r in ipairs(roof) do
    opaque = opaque and (r.art == "roof" or r.art == "roofo")
    if r.cy == 1 and r.art == "roofo" then topOver = true end
    if r.cy and r.cy > 1 and r.art == "roofo" then lowerOver = true end
  end
  check(opaque, "both layers in one opaque copy")
  check(topOver and not lowerOver, "the walkable top row's from its overhead art alone")
  eq(#pick(q, "roof", "o"), 0, "so no separate overhead roof")

  -- at 45 degrees every texel lands where the 2D field drew it
  local exact, area = true, 0
  for _, x in ipairs(q) do
    if x.layer == "u" and x.poly and x.cx and not x.mirror and x.face ~= "foot" then
      for _, v in ipairs(x.poly) do
        if math.abs(v[1] - v[4] - x.cx * 16) > 1e-6 or math.abs(v[3] - v[2] - v[5] - x.cy * 16) > 1e-6 then
          exact = false
        end
      end
      area = area + projArea(x)
    end
  end
  check(exact, "every corner's texel is its own projection")
  check(area >= 48 * 64 - 1e-6 and area <= 48 * 64 + 48 * 0.2, "covering the drawing once, no gap (" .. area .. ")")
  -- past the drawing's top row, the back of the roof, mirrored
  local mirrored, ridgeZ, ridgeY = 0, nil, -math.huge
  for _, r in ipairs(roof) do
    if not r.mirror then
      for _, c in ipairs(corners(r)) do
        if c[2] > ridgeY + 1e-9 then ridgeY, ridgeZ = c[2], c[3] end
      end
    end
  end
  for _, r in ipairs(roof) do
    if r.mirror then
      mirrored = mirrored + 1
      for _, c in ipairs(corners(r)) do
        check(c[3] - c[2] <= 16 + 1e-6, "the mirrored back lies past the drawing's top")
        check(c[3] <= ridgeZ + 1e-6, "behind the ridge")
      end
    end
  end
  check(mirrored > 0, "the back of the roof takes the front's texels mirrored")

  local sides = pick(q, "side")
  check(#sides > 0, "side walls")
  local west, east = false, false
  for _, sq in ipairs(sides) do
    local x0, x1 = extent(sq, 1)
    if math.abs(x0 - 16) < 1e-6 and math.abs(x1 - 16) < 1e-6 then west = true end
    if math.abs(x0 - 64) < 1e-6 and math.abs(x1 - 64) < 1e-6 then east = true end
    local z0 = extent(sq, 3)
    check(z0 >= 32 - 1e-6, "within the footprint")
  end
  check(west and east, "on both ends")
  eq(#pick(q, "back", "u"), 1, "and a back wall")
  local cov = coverage(q)
  for y = 0, 5 do
    for x = 0, 4 do
      check(cov[x .. "," .. y], ("ground or roof covers cell %d,%d (no hole to the sky)"):format(x, y))
    end
  end

  -- without a door it is not a house: a flat top, edge-on behind
  local wall = build(grid({ ".....", ".ooo.", ".###.", ".###.", ".###.", "....." }), 0, 0, 5, 6)
  local top = pick(wall, "roof", "u")
  for _, r in ipairs(top) do
    local y0, y1 = extent(r, 2)
    check(math.abs(y0 - 32) < 1e-6 and math.abs(y1 - 32) < 1e-6, "a flat top at the walls' height")
  end
  local back = pick(wall, "back", "u")
  check(#back >= 1, "a back plane behind it")
  for _, c in ipairs(corners(back[1])) do
    check(math.abs((c[3] - c[2]) - 16) < 1e-6, "edge-on to the 45 degree camera")
  end

  -- in a room the same block standing free is furniture: low, and in
  -- the shallow fold
  local flat = build(info, 0, 0, 5, 6, { cap = 2, tuft = 5, indoor = true })
  local fr = pick(flat, "roof", "u")
  eq(fr[1].p[2], 16, "indoors: at the low front's height")
  eq(fr[1].p[3], 3 * 16, "slid forward one row to meet it")
  eq(#pick(flat, "back", "u"), 0, "with no back slope")
end

-- ------- a sign standing one row out under two houses side by side
-- (Lavaridge's): its own card, not a column of the houses run down to it

do
  local q = build(grid({
    "..........",
    ".oooooooo.",
    ".########.",
    ".########.",
    ".#D##D###.",
    "....s.....",
    "..........",
  }), 0, 0, 10, 7)
  local column = false
  for _, f in ipairs(q) do
    if f.kind == "facade" or f.kind == "roof" or f.kind == "side" then
      local _, z1 = extent(f, 3)
      if z1 > 5 * 16 + 1 then column = true end
    end
  end
  check(not column, "no column of the houses runs down to the sign")
  check(#pick(q, "object") > 0, "the sign is a card of its own")
end

-- ------- the side walls are dressed from a plain stretch of the front

do
  local info = grid({ ".....", ".###.", ".###.", ".#D#.", "....." })
  -- the front: one plain colour, a dark window in the middle cell
  local function px(c)
    local t = {}
    for i = 0, 255 do t[i] = 1 end
    if c.mid == 2 then for i = 0, 255 do t[i] = 9 end end
    return t
  end
  local cells = function(cx, cy)
    local c = info(cx, cy)
    if cx == 2 and cy == 3 then
      local d = {}
      for k, v in pairs(c) do d[k] = v end
      d.mid = 2
      return d
    end
    return c
  end
  local q = build(cells, 0, 0, 5, 5, { cap = 2, tuft = 0, pixels = px })
  local sides = pick(q, "side", "u")
  check(#sides > 0, "side walls")
  local window = false
  for _, sq in ipairs(sides) do
    if sq.mid == 2 then window = true end
    for _, v in ipairs(sq.poly) do
      check(v[4] >= -0.2 and v[4] <= 16.2, "texels inside one cell")
    end
  end
  check(not window, "never the window: the plaster beside it")
end

-- ------- neighbours with an eave on one and not the other are different boxes

do
  local info = grid({
    ".o#.",
    ".##.",
    ".##.",
    ".##.",
    "....",
  })
  local q = build(info, 0, 0, 4, 5)
  local between = 0
  for _, sq in ipairs(pick(q, "side")) do
    local x0, x1 = extent(sq, 1)
    if math.abs(x0 - 2 * 16) < 0.1 and math.abs(x1 - 2 * 16) < 0.1 then between = between + 1 end
  end
  check(between > 0, "the deeper box shows its wall where the other column is only an eave")
  local cov = coverage(q)
  for y = 0, 4 do
    for x = 0, 3 do
      check(cov[x .. "," .. y], ("ground or roof covers cell %d,%d beside the eave"):format(x, y))
    end
  end
end

-- ------- a tree: canopy over trunk stands as one card

do
  local info = grid({
    "...",
    ".o.",
    ".#.",
    "...",
  })
  local q = build(info, 0, 0, 3, 4)
  local facade = pick(q, "facade")
  local heights = {}
  for _, f in ipairs(facade) do heights[#heights + 1] = f.p[2] end
  table.sort(heights)
  eq(#pick(q, "roof"), 0, "a two-row tree has no roof")
  eq(heights[#heights], 32, "the canopy stands on top of the trunk")
  for _, f in ipairs(facade) do
    check(math.abs(f.p[3] - 3 * 16) < 0.1, "on the trunk's front edge")
  end
  eq(#pick(q, "side"), 0, "a card has no sides")
end

-- ------- a sign under a building is its own card

do
  local info2 = grid({
    "#####",
    "#####",
    "..#..",
  })
  check(Shape.detached(info2, 2, 2), "a structure cell jutting out under a wide building is detached")
  local q = build(info2, 0, 0, 5, 3)
  local cards = pick(q, "object")
  eq(#cards, 1, "it stands alone as a card")
  eq(cards[1].p[3], 3 * 16, "on its own front edge")
  local facade = pick(q, "facade")
  for _, f in ipairs(facade) do
    local z0, z1 = extent(f, 3)
    check(math.abs(z0 - 2 * 16) < 1e-6 and math.abs(z1 - 2 * 16) < 1e-6,
      "the building's facade stays straight behind it")
  end
end

-- ------- water, banks, grass, ledges

do
  local info = grid({
    "...",
    "...",
    "~~~",
  })
  local q = build(info, 0, 0, 3, 3)
  local water = pick(q, "water")
  eq(#water, 3, "three water cells")
  eq(water[1].p[2], -4, "water sits below its bank")
  eq(#pick(q, "bank"), 3, "the land in front shows its edge down to the water")

  local g = grid({ "g" })
  local tufts = pick(build(g, 0, 0, 1, 1), "tuft")
  eq(#tufts, 1, "tall grass grows a tuft")
  eq(tufts[1].p[2], 5, "five pixels tall")
  eq(#pick(build(g, 0, 0, 1, 1, { cap = 2, tuft = 0 }), "tuft"), 0, "GRASS TUFTS off grows none")

  local l = grid({ ".v." })
  local ledge = pick(build(l, 0, 0, 3, 1), "ledge")
  check(#ledge >= 2, "a ledge is a raised step with a face")
  eq(#pick(build(l, 0, 0, 3, 1), "side"), 2, "with ends where the ledge stops")
end

-- ------- an endless forest folds the same way whichever cell asks first

do
  local info = function(cx, cy)
    local c = { mid = 1, pair = "p", elev = 0, walk = cy >= 100, over = 0 }
    c.kind = Shape.classify(c)
    return c
  end
  local a = build(info, 0, 40, 2, 42, { cap = 2, maxRun = 8 })
  eq(#pick(a, "facade"), 0, "deep inside a forest there is no facade")
  eq(#pick(a, "side"), 0, "and no wall between identical columns")
  eq(#pick(a, "roof"), 0, "no roof waiting on a bottom row out of reach")
  eq(#pick(a, "flat"), 4, "what is not a tree lies flat, where the 2D field drew it")
  local alone = pick(build(info, 0, 41, 2, 42, { cap = 2, maxRun = 8 }), "flat")
  local again = {}
  for _, q in ipairs(a) do
    if q.kind == "flat" and q.p[3] == 41 * 16 then again[#again + 1] = q end
  end
  eq(#alone, #again, "the same whichever cell asked first")
  eq(alone[1].p[2], again[1].p[2], "at the same height")
  local b = build(info, 0, 98, 2, 100, { cap = 2, maxRun = 8 })
  eq(#pick(b, "facade"), 4, "the forest's real edge still stands up")
end

-- ------- cut-outs: trees, hedges and buildings by their art
--
-- A legend of named metatiles, each with the share of its art in the
-- ground's colours (what Cutouts measures from the atlas): tree cells are
-- partly grass, a hedge mostly, a wall not at all.

local LEGEND = {
  ["."] = { mid = 1, frac = 1 },                               -- grass
  A = { mid = 10, solid = true, frac = 0.10 },                 -- canopy
  B = { mid = 11, solid = true, frac = 0.14, over = 0.1 },     -- trunk, next tree's top
  b = { mid = 12, solid = true, frac = 0.14 },                 -- last trunk row
  H = { mid = 20, solid = true, frac = 0.78 },                 -- hedge
  W = { mid = 30, solid = true, frac = 0 },                    -- wall
  S = { mid = 50, object = true, frac = 0.3 },                 -- sign
  ["~"] = { mid = 60, water = true, frac = 0 },                -- pond
  r = { mid = 70, frac = 0 },                                  -- a rug
  T = { mid = 71, solid = true, frac = 0.05, rugFrac = 0.4 },  -- a table on it
  V = { mid = 80, solid = true, frac = 0, void = true },       -- border, past the edge
  X = { mid = 10, solid = true, frac = 0.10, void = true },    -- a border tree's canopy
  Y = { mid = 11, solid = true, frac = 0.14, over = 0.1, void = true }, -- its trunk
  M = { mid = 90, solid = true, frac = 0 },                    -- a shop's wall
  m = { mid = 91, solid = true, frac = 0.14 },                 -- its round edge, some grass
  n = { mid = 95, solid = true, frac = 0.14 },                 -- and over it
  Q = { mid = 96, solid = true, frac = 1, over = 0.9, shown = 0.09 }, -- a canopy drawn overhead (Dewford)
  q = { mid = 97, solid = true, frac = 0.3, shown = 0.3 },     -- its trunk
  K = { mid = 98, solid = true, frac = 0, wet = 0.3 },         -- a rock in the sea, its top
  k = { mid = 99, solid = true, frac = 0, wet = 0.3 },         -- and its foot
  D = { mid = 92, solid = true, frac = 0, door = true },       -- its door
  o = { mid = 93, frac = 0.5, over = 0.5 },                    -- its roof's top, walkable
  t = { mid = 94, solid = true, frac = 0.14, over = 0.3 },     -- a tree's foot over its roof
  N = { mid = 100, solid = true, frac = 1, over = 1, shown = 0.02 }, -- a narrow tree's canopy, overhead
  u = { mid = 101, solid = true, frac = 0.09 },                -- its trunk
  p = { mid = 102, frac = 0.5, over = 0.5 },                   -- the tops of trees in front, walkable
  R = { mid = 103, solid = true, frac = 1, over = 0.8, shown = 0.1 }, -- a roof's top row drawn overhead
  G = { mid = 104, solid = true, frac = 0.79, over = 0.875, shown = 0.09 }, -- a hedge, on both layers
  J = { mid = 106, solid = true, frac = 0, wet = 0.02 },       -- a rock's top in a fence's shadow
  E = { mid = 107, solid = true, frac = 0.44 },                -- a cliff's edge in the ground's colours
  e = { mid = 108, solid = true, frac = 0.16 },                -- its foot
  P = { mid = 109, solid = true, frac = 0.25, wet = 0.1 },     -- a trunk at a pond's edge
  g = { mid = 105, solid = true, frac = 0.18 },               -- its foot
}

local function tiles(rows)
  local cells = {}
  for y, row in ipairs(rows) do
    for x = 1, #row do cells[(x - 1) .. "," .. (y - 1)] = row:sub(x, x) end
  end
  local memo = {}
  return function(cx, cy)
    local k = cx .. "," .. cy
    if memo[k] then return memo[k] end
    local d = LEGEND[cells[k] or "."]
    local c = { mid = d.mid, pair = "p", elev = 3, walk = true, over = d.over or 0, frac = d.frac,
      rugFrac = d.rugFrac, void = d.void, shown = d.shown, wet = d.wet }
    if d.solid then c.walk, c.elev = false, 0 end
    if d.object then c.walk = false end
    if d.water then c.walk, c.beh = false, "POND_WATER" end
    if d.door then c.beh = "WARP_DOOR" end
    c.kind = Shape.classify(c)
    memo[k] = c
    return c
  end
end

local GRASS = { mid = 1, pair = "p", kind = "floor" }
local function art(extra)
  local p = { cap = 2, tuft = 0,
    keyFraction = function(c, keyMid)
      if keyMid == 1 then return c.frac end
      if keyMid == 60 then return c.mid == 60 and 1 or (c.wet or 0) end
      if keyMid == 70 then return c.mid == 70 and 1 or (c.rugFrac or 0) end
      return nil
    end,
    keyColours = function(c) return c.mid == 70 and 3 or 12 end,
    groundOf = function() return GRASS end }
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end

-- ------- a wood whose canopies are drawn on the overhead layer over plain
-- ground (Dewford's hill): judged as the field shows it, still a wood

do
  local info = tiles({
    "QQQQ",
    "qqqq",
    "QQQQ",
    "qqqq",
    "....",
  })
  local shown = art({ shownFraction = function(c, keyMid) if keyMid == 1 then return c.shown end end })
  local q = build(info, 0, 0, 4, 5, shown)
  eq(#pick(q, "roof"), 0, "no roof over it")
  check(#pick(q, "forest") > 0, "tree cards")
  local plain = build(info, 0, 0, 4, 5, art())
  check(#pick(plain, "forest") == 0, "judged by its ground layer alone it is no wood")
end

-- ------- a wood behind a building whose roof's top row is drawn on the
-- overhead layer over grass (Petalburg's gym): that row is roof, not trees

do
  local info = tiles({
    ".AAAA.",
    ".BBBB.",
    ".AAAA.",
    ".bbbb.",
    ".RRRR.",
    ".WWWW.",
    ".WDWW.",
    "......",
  })
  local shown = art({ shownFraction = function(c, keyMid) if keyMid == 1 then return c.shown end end })
  local q = build(info, 0, 0, 6, 8, shown)
  local roofTop, stray = false, false
  for _, f in ipairs(q) do
    if f.kind == "roof" and f.cy == 4 then roofTop = true end
    if f.kind == "forest" then
      local z0 = extent(f, 3)
      if z0 > 4 * 16 + 1 then stray = true end
    end
  end
  check(roofTop, "the overhead-drawn top row is the building's roof")
  check(not stray, "and no tree stands in it")
end

-- ------- a hedge drawn on both layers, mostly in the grass's colours, its
-- overhead over most of it (Petalburg's): a box, not a row of trees

do
  local info = tiles({
    "......",
    ".GG...",
    ".GG...",
    ".GG...",
    ".GG...",
    ".gg...",
    "......",
  })
  local shown = art({ shownFraction = function(c, keyMid) if keyMid == 1 then return c.shown end end })
  local q = build(info, 0, 0, 6, 7, shown)
  eq(#pick(q, "forest"), 0, "no tree cards")
  check(#pick(q, "side") > 0, "a box with sides")
end

-- ------- rocks in the sea one after another down a column (Route 110's)
-- stand one by one in the water, not as one block

do
  local info = tiles({
    "~~~~",
    "~K~~",
    "~kK~",
    "~Kk~",
    "~kK~",
    "~~k~",
    "~~~~",
  })
  local q = build(info, 0, 0, 4, 7, art())
  local boxed, rocks, sea = false, 0, 0
  for _, f in ipairs(q) do
    local x0, x1 = extent(f, 1)
    if (f.kind == "roof" or f.kind == "facade" or f.kind == "side") and x0 >= 16 - 1e-6 and x1 <= 48 + 1e-6 then
      boxed = true
    end
    if f.kind == "forest" then rocks = rocks + 1 end
    if f.kind == "ground" and f.mid == 60 then
      local y0 = extent(f, 2)
      if y0 < 0 then sea = sea + 1 end
    end
  end
  check(not boxed, "no block of rock and water")
  check(rocks > 0, "each rock stands")
  check(sea > 0, "in the sea, at the water line")
  local greenBank = false
  for _, f in ipairs(pick(q, "bank")) do
    if f.mid == 1 then greenBank = true end
  end
  check(not greenBank, "with no grass bank between them")
  -- with the shore right behind them, still in the sea
  local shore = tiles({
    "....",
    "~K~~",
    "~k~~",
    "~K~~",
    "~k~~",
    "~~~~",
  })
  local onGrass, inSea = false, false
  for _, f in ipairs(build(shore, 0, 0, 4, 6, art())) do
    local x0, x1 = extent(f, 1)
    local z0 = extent(f, 3)
    if f.kind == "ground" and x0 >= 16 - 1e-6 and x1 <= 32 + 1e-6 and z0 >= 16 - 1e-6 then
      if f.mid == 1 then onGrass = true end
      if f.mid == 60 then inSea = true end
    end
  end
  check(inSea and not onGrass, "rocks off a shore stand in the sea, not on grass")
end

-- ------- a cliff's edge drawn in the ground's colours, one tile down
-- every row (Sootopolis's): no tree tiling, a block

do
  local q = build(tiles({ "......", ".E....", ".E....", ".E....", ".E....", ".e....", "......" }),
    0, 0, 6, 7, art())
  eq(#pick(q, "forest"), 0, "a tile repeated every row is no wood")
end

-- ------- a rock in the sea right under a fence that runs on past it on
-- both sides (Route 110's): the rock stands on its own, in the water

do
  local q = build(tiles({
    "......",
    "WWWWWW",
    "~~JJ~~",
    "~~kk~~",
    "~~~~~~",
  }), 0, 0, 6, 5, art())
  local tall, rock, boxed, grass = false, 0, false, false
  for _, f in ipairs(q) do
    local x0, x1 = extent(f, 1)
    local z0, z1 = extent(f, 3)
    if f.mid == 30 and z1 > 2 * 16 + 1 then tall = true end
    if f.mid == 106 or f.mid == 99 then
      rock = rock + 1
      if f.art ~= "tree" then boxed = true end
    end
    if f.kind == "ground" and f.mid == 1 and x0 >= 32 - 1e-6 and x1 <= 64 + 1e-6 and z0 >= 32 - 1e-6 then
      grass = true
    end
  end
  check(not tall, "the fence stands alone, not down to the rock")
  check(rock > 0 and not boxed, "the rock stands on its own, cut out against the water")
  check(not grass, "with the sea under it, not the grass over the fence")
end

-- ------- trees at a pond's edge, their trunks drawn over a little of the
-- water (Route 104's): still trees on the grass, not rocks in the pond

do
  local q = build(tiles({
    "AAAA..",
    "BBBB..",
    "AAAA..",
    ".PP...",
    "~~~~~~",
  }), 0, 0, 6, 5, art())
  local wet = false
  for _, f in ipairs(q) do
    local x0, x1 = extent(f, 1)
    local z0 = extent(f, 3)
    if (f.kind == "ground" or f.kind == "bank") and f.mid == 60 and x0 >= 16 - 1e-6 and x1 <= 48 + 1e-6
        and z0 < 4 * 16 - 1e-6 then
      wet = true
    end
  end
  check(not wet, "no water under the trees at the pond's edge")
end

-- ------- a shop by a wood, a tree of it drawn over the roof's corner
-- (Petalburg's Mart): one building, its edge no tree, the tree's foot roof

do
  local info = tiles({
    "..AAAA",
    "oottBB",
    "MMMMAA",
    "MMMnBB",
    "MDMmAA",
    "....BB",
    "....AA",
    "....bb",
  })
  local q = build(info, 0, 0, 6, 8, art())
  local strayTree, roofAt, wide, trunk, leafy = false, {}, 0, false, false
  for _, f in ipairs(q) do
    local x0, x1 = extent(f, 1)
    local z0 = extent(f, 3)
    local y0 = extent(f, 2)
    if f.kind == "forest" and x1 <= 64 + 1e-6 and z0 >= 32 - 1e-6 then strayTree = true end
    local _, z1 = extent(f, 3)
    if (f.kind == "forest" or f.kind == "facade") and x0 >= 32 - 1e-6 and x1 <= 64 + 1e-6
        and math.abs(z0 - 32) < 0.1 and math.abs(z1 - 32) < 0.1 and y0 < 1 then trunk = true end
    if f.kind == "roof" and f.cx then
      roofAt[f.cx .. "," .. f.cy] = true
      if f.cy == 1 and (f.cx == 2 or f.cx == 3) and f.mid ~= 93 then leafy = true end
    end
    if f.kind == "roof" then wide = math.max(wide, x1) end
  end
  check(not strayTree, "the shop's round edge beside the wood is no tree")
  check(roofAt["2,1"] and roofAt["3,1"], "the roof's top row under the tree is roof")
  check(not trunk, "and no trunk stands in it")
  check(not leafy, "that row's roof from the roof beside it, without the tree's leaves")
  eq(wide, 64, "one roof over the whole shop")
end

-- ------- a narrow tree beside a house, under the foot of the wood behind
-- (Route 116's): it is no column of the house; the house's roof starts at
-- its own wall

do
  local info = tiles({
    "..A.....",
    "..B.....",
    "..A.....",
    "..bWWW..",
    "..NWWW..",
    "..NWWW..",
    "..uWDW..",
    "........",
  })
  local shown = art({ shownFraction = function(c, keyMid) if keyMid == 1 then return c.shown end end })
  local q = build(info, 0, 0, 8, 8, shown)
  local wall, treeRoof = false, false
  for _, f in ipairs(pick(q, "side")) do
    local x0, x1 = extent(f, 1)
    if f.mid == 30 and math.abs(x0 - 48) < 0.1 and math.abs(x1 - 48) < 0.1 then wall = true end
  end
  for _, f in ipairs(pick(q, "roof")) do
    local x0, x1 = extent(f, 1)
    if f.mid == 30 and x0 < 48 - 1e-6 then treeRoof = true end
  end
  check(wall, "the house has its west wall beside the narrow tree")
  check(not treeRoof, "the tree is not under the house's roof")
end

-- ------- a house with the tops of the trees in front of it under its
-- front row (Oldale's): the house is one building, the trees their own

do
  local info = tiles({
    "......",
    ".oooo.",
    ".WWWW.",
    ".WWWW.",
    ".WDWW.",
    "...pp.",
    "...AA.",
    "...bb.",
    "......",
  })
  local q = build(info, 0, 0, 6, 9, art())
  local wide, treeInHouse, trees = 0, false, 0
  for _, f in ipairs(q) do
    local x0, x1 = extent(f, 1)
    local z0 = extent(f, 3)
    if f.kind == "roof" then wide = math.max(wide, x1) end
    if f.kind == "forest" then
      trees = trees + 1
      if z0 < 5 * 16 - 1e-6 then treeInHouse = true end
    end
  end
  eq(wide, 80, "one roof over the whole house")
  check(not treeInHouse, "none of the house stands as trees")
  check(trees > 0, "the trees in front stand")
end

local function only(quads, field, value)
  for _, q in ipairs(quads) do
    if q[field] ~= value then return false end
  end
  return #quads > 0
end

do
  -- two rows of trees, two trees wide
  local forest = tiles({
    "......",
    ".AAAA.",
    ".BBBB.",
    ".AAAA.",
    ".bbbb.",
    "......",
  })
  local q = build(forest, 0, 0, 6, 6, art())
  eq(#pick(q, "facade") + #pick(q, "roof") + #pick(q, "side"), 0, "a forest is no box")
  local under = pick(q, "forest", "u")
  eq(#under, 16, "every tree cell stands")
  check(only(under, "art", "tree"), "cut out against the grass, with their shadow")
  check(only(under, "key", 1), "keyed on the ground metatile")
  local planes = {}
  for _, t in ipairs(under) do
    local key = t.mid .. "@" .. t.p[3] .. ":" .. math.min(t.p[2], t.p[8]) .. "-" .. math.max(t.p[2], t.p[8])
    planes[key] = (planes[key] or 0) + 1
  end
  eq(planes["12@80:0-16"], 4, "the front trunks stand on their own front edge")
  eq(planes["10@80:16-32"], 4, "their canopies stand on top of them")
  eq(planes["11@48:0-16"], 4, "the trees behind: trunk")
  eq(planes["10@48:16-32"], 4, "and canopy, one row further back")
  local tops = pick(q, "forest", "o")
  eq(#tops, 4, "the overhead art on the back trunks")
  eq(math.floor(tops[1].p[3]), 80, "is the top of the tree in front")
  eq(math.min(tops[1].p[2], tops[1].p[8]), 32, "above its canopy")
  local floors = pick(q, "ground")
  eq(#floors, 16, "ground under every tree")
  check(only(floors, "mid", 1), "the grass")
end

do
  local house = tiles({
    "......",
    ".WWW..",
    ".WWW..",
    ".WWW..",
    "......",
  })
  local q = build(house, 0, 0, 6, 5, art())
  local facade = pick(q, "facade", "u")
  check(#facade > 0, "a building stays a box")
  for _, f in ipairs(facade) do
    local z0, z1 = extent(f, 3)
    check(math.abs(z0 - 64) < 1e-6 and math.abs(z1 - 64) < 1e-6, "its front on its front edge")
  end
  check(only(facade, "art", "fill"), "its facade keeps solid, the stray lawn painted over")
  check(only(pick(q, "roof", "u"), "art", "fill"), "and its top")
  local sides = pick(q, "side")
  check(#sides > 0, "it has side walls")
  local stretch = true
  for _, sq in ipairs(sides) do
    local x0, x1 = extent(sq, 1)
    if not (sq.art == "fill" and x0 == x1 and (x0 == 16 or x0 == 64)) then stretch = false end
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(sq.poly) do lo, hi = math.min(lo, v[4]), math.max(hi, v[4]) end
    if hi - lo > 8 + 0.2 then stretch = false end
  end
  check(stretch, "sides repeat a stretch of the front along the wall, never one column smeared")
end

do
  -- trees behind a hedge: a column of blocked cells, two things
  local q = build(tiles({
    "......",
    ".AA...",
    ".bb...",
    ".HH...",
    ".HH...",
    ".HH...",
    "......",
  }), 0, 0, 6, 7, art())
  local cut, fill = 0, 0
  for _, f in ipairs(pick(q, "facade", "u")) do
    if f.art == "tree" then
      cut = cut + 1
      eq(f.p[3], 3 * 16, "the trees stand on their own front edge")
    elseif f.art == "fill" then
      fill = fill + 1
      local z0, z1 = extent(f, 3)
      check(math.abs(z0 - 6 * 16) < 1e-6 and math.abs(z1 - 6 * 16) < 1e-6, "the hedge on its own")
    end
  end
  eq(cut, 4, "the row of trees is cut off as a card")
  check(fill > 0, "and the hedge is a box")
end

do
  local q = build(tiles({ "...", ".S.", "..." }), 0, 0, 3, 3, art())
  local sign = pick(q, "object", "u")
  eq(#sign, 1, "a sign is a card")
  eq(sign[1].art, "tree", "with its own outline")
end

do
  -- a box beside a forest of the same height still has its wall
  local q = build(tiles({
    "......",
    ".AAWW.",
    ".BBWW.",
    ".AAWW.",
    ".bbWW.",
    "......",
  }), 0, 0, 6, 6, art())
  local wall = 0
  for _, sq in ipairs(pick(q, "side")) do
    local x0, x1 = extent(sq, 1)
    if math.abs(x0 - 3 * 16) < 0.1 and math.abs(x1 - 3 * 16) < 0.1 then wall = wall + 1 end
  end
  check(wall > 0, "the box's west wall faces the trees")
end

do
  -- a rock in a pond is cut out against the water
  local q = build(tiles({ "~~~~~~", "~~~~~~", "~~WW~~", "~~WW~~", "~~~~~~", "~~~~~~" }),
    0, 0, 6, 6, art())
  local rock = pick(q, "facade", "u")
  check(#rock >= 4, "the rock stands")
  check(only(rock, "key", 60), "keyed on the water around it")
end

do
  -- ground left at the water line next to dry ground gets a bank
  local q = build(tiles({
    "~~~~~",
    "~~~~~",
    "~WW..",
    "~WW..",
    "~~~~~",
  }), 0, 0, 5, 5, art())
  local steps = 0
  for _, bq in ipairs(pick(q, "bank")) do
    if math.abs(bq.p[1] - 32) < 0.1 and math.abs(bq.p[4] - 32) < 0.1
        and math.abs(math.min(bq.p[2], bq.p[8]) + 4) < 0.1 then steps = steps + 1 end
  end
  eq(steps, 2, "the sunken ground behind the rock's wet half closes its step to the dry half")
  -- and nothing at the water line is left open to the sky
  for _, gq in ipairs(pick(q, "ground")) do
    check(gq.p[2] == 0 or gq.p[2] == -4, "vacated ground lies at the ground or the water line")
  end
end

-- ------- STRUCTURE HEIGHT

do
  local info = grid({
    ".###.",
    ".###.",
    ".###.",
    ".....",
  })
  local function height(q)
    local h = 0
    for _, f in ipairs(pick(q, "facade")) do h = math.max(h, select(2, extent(f, 2))) end
    return h
  end
  check(math.abs(height(build(info, 0, 0, 5, 4, { cap = 1 })) - 16) < 0.2, "LOW: a one-row facade")
  check(math.abs(height(build(info, 0, 0, 5, 4, { cap = 3 })) - 48) < 0.2, "TALL: three rows")
end

-- ------- the void past a map's edge, and rooms

do
  -- outdoors: a building ends at the edge; border trees stand, the rest
  -- of the border lies flat
  local q = build(tiles({
    "VVVV",
    "WWWW",
    "WWWW",
    "WWWW",
    "....",
  }), 0, 0, 4, 5, art())
  local roofs, flats = pick(q, "roof", "u"), pick(q, "flat", "u")
  eq(#flats, 4, "plain border tiles lie flat")
  local onEdge = true
  for _, r in ipairs(roofs) do
    if extent(r, 3) < 16 - 1e-6 then onEdge = false end
  end
  check(#roofs > 0 and onEdge, "the building's roof stays inside the map")
  local t = build(tiles({ "XX", "YY", "XX", "YY", ".." }), 0, 0, 2, 5, art())
  local cards = pick(t, "forest", "u")
  eq(#cards, 8, "border trees stand")
  check(only(cards, "art", "tree"), "cut out with their shadow")
  local lifted = 0
  for _, c in ipairs(cards) do
    if c.mid == 10 and math.min(c.p[2], c.p[8]) == 16 then lifted = lifted + 1 end
  end
  eq(lifted, 4, "a border canopy sits on its trunk")

  -- indoors: nothing past the edge
  local room = build(tiles({ "VVVV", "WWWW", "WWWW", "....", "...." }), 0, 0, 4, 5, art({ indoor = true }))
  for _, x in ipairs(room) do
    if math.min(x.p[3], x.p[6], x.p[9], x.p[12]) < 16 and x.kind ~= "facade" then
      check(false, "a room draws nothing past its edge (" .. x.kind .. ")")
    end
  end
  local wall = pick(room, "facade", "u")
  eq(#wall, 8, "a two-row back wall stands whole")
  check(only(wall, "art", "fill"), "and stays solid: nothing walkable behind it")
end

do
  -- a table on a rug in a room: low, keyed on the rug
  local q = build(tiles({
    "......",
    ".rrrr.",
    ".rTTr.",
    ".rTTr.",
    ".rrrr.",
    "......",
  }), 0, 0, 6, 6, art({ indoor = true }))
  local front = pick(q, "facade", "u")
  eq(#front, 2, "an untagged table is a low block: one row of front")
  eq(math.max(front[1].p[2], front[1].p[8]), 16, "sixteen pixels tall")
  check(only(front, "key", 70), "cut out against the rug it stands on")
  eq(#pick(q, "roof", "u"), 2, "and a top")
  local function arts(list)
    local a = {}
    for _, x in ipairs(list) do a[#a + 1] = x.art end
    table.sort(a)
    return table.concat(a, ",")
  end
  -- trimmed, not cut: only the rug joined to its open edges goes
  -- (1 north, 2 east, 4 south, 8 west)
  eq(arts(front), "trim12,trim6", "its front is trimmed from the south and its outer sides")
  eq(arts(pick(q, "roof", "u")), "trim3,trim9", "its top from the north and its outer sides")
  local sides = pick(q, "side", "u")
  eq(#sides, 2, "it shows its outer sides")
  eq(arts(sides), "trim12,trim6", "trimmed as its front is (a table shows its legs)")
  local under = 0
  for _, x in ipairs(q) do
    if x.layer == "u" and x.kind == "ground" and x.p[3] >= 32 and x.p[9] <= 64
        and x.p[1] >= 32 and x.p[7] <= 64 then
      under = under + 1
    end
  end
  check(under >= 4, "the floor runs under all of it (" .. under .. ")")
  -- the rug only on one side (the edge of a rug, floorboards behind)
  local edge = build(tiles({ "......", "..TT..", "..TT..", ".rrrr.", "......" }), 0, 0, 6, 5,
    art({ indoor = true }))
  check(only(pick(edge, "facade", "u"), "key", 70), "the rug in front is its key")
  -- a plant pushed up against the table: not trimmed on that side
  local pushed = build(tiles({ "......", ".TTS..", ".TTr..", "......" }), 0, 0, 6, 4,
    art({ indoor = true }))
  eq(pick(pushed, "object", "u")[1].art, "trim7", "trimmed from the floor's sides only")

  -- what the game tags as a shelf stands; a counter is a low block
  local shelf = build(tiles({ "......", ".rBBr.", ".rbbr.", "......" }), 0, 0, 6, 4,
    art({ indoor = true }))
  eq(#pick(shelf, "facade", "u"), 2, "an untagged pair of rows is low")
  local function tagged(beh)
    local base = tiles({ "rrrrrr", "rrTTrr", "rrTTrr", "rrrrrr", "......" })
    return function(cx, cy)
      local c = base(cx, cy)
      if c.mid == 71 and cy == 2 and not c.tagged then
        local t = {}
        for k, v in pairs(c) do t[k] = v end
        t.beh, t.tagged = beh, true
        return t
      end
      return c
    end
  end
  local tall = build(tagged("BOOKSHELF"), 0, 0, 6, 5, art({ indoor = true }))
  eq(#pick(tall, "facade", "u"), 4, "a bookshelf stands whole")
  check(only(pick(tall, "facade", "u"), "key", 70), "cut out against the rug it stands on")
  local counter = build(tagged("COUNTER"), 0, 0, 6, 5, art({ indoor = true }))
  eq(#pick(counter, "facade", "u"), 2, "a counter is a low block: one row of front")
  eq(#pick(counter, "roof", "u"), 2, "and a top")
  local plant = build(tiles({ "...", ".S.", "..." }), 0, 0, 3, 3, art({ indoor = true }))
  eq(#pick(plant, "object", "u"), 1, "a piece on its own is a small card")
  eq(pick(plant, "object", "u")[1].art, "trim15", "trimmed from every edge, without the outdoor shadow")
  local base = tiles({ "...", ".S.", "..." })
  local tv = build(function(cx, cy)
    local c = base(cx, cy)
    if c.mid == 50 then
      local t = {}
      for k, v in pairs(c) do t[k] = v end
      t.beh = "TELEVISION"
      return t
    end
    return c
  end, 0, 0, 3, 3, art({ indoor = true }))
  eq(pick(tv, "object", "u")[1].art, "trim15", "a television stands, trimmed, without the outdoor shadow cut")
end

-- ------- mesher

do
  local atlas = {
    width = 64, height = 32, layered = false,
    origin = function(mid) return (mid % 4) * 16, math.floor(mid / 4) * 16 end,
  }
  local quads = {
    { pair = "a", layer = "u", mid = 5, p = { 0, 0, 0, 16, 0, 0, 16, 0, 16, 0, 0, 16 },
      u0 = 0, v0 = 0, u1 = 16, v1 = 16, shade = 1, low = 0.5 },
    { pair = "a", layer = "o", mid = 5, p = { 0, 0, 0, 16, 0, 0, 16, 0, 16, 0, 0, 16 },
      u0 = 0, v0 = 0, u1 = 16, v1 = 16, shade = 1 },
  }
  local groups, missing = Mesher.build(quads, function(pair) return pair == "a" and atlas or nil end)
  eq(missing, nil, "every pair has an atlas")
  eq(#groups, 1, "an unlayered atlas drops the overhead quad")
  local v = groups[1].verts
  eq(#v, 4, "four corners")
  eq(#groups[1].idx, 6, "two triangles")
  check(math.abs(v[1][4] - (16 + 0.02) / 64) < 1e-9, "u is the metatile's origin, pulled in a hair")
  check(math.abs(v[3][5] - (32 - 0.02) / 32) < 1e-9, "v reaches the bottom of the metatile, pulled in")
  eq(v[1][6], 1, "top edge light")
  eq(v[3][6], 0.5, "bottom edge light")
  local _, miss = Mesher.build({ { pair = "b", layer = "u", mid = 1, p = quads[1].p,
    u0 = 0, v0 = 0, u1 = 16, v1 = 16 } }, function() return nil end)
  check(miss and miss.b, "a pair still streaming is reported, so the chunk waits")
end

-- ------- camera

do
  local cam = Camera.new()
  for _, deg in ipairs({ 45, 35, 25 }) do
    cam.pitch = nil
    cam:update(0, deg)
    cam:frame(100, 0, 100, 960, 640, 3, false)
    local sx, sy = cam:project(100, 0, 100)
    check(math.abs(sx - 480) < 1e-6 and math.abs(sy - 320) < 1e-6, deg .. ": the focus is the canvas centre")
    local _, top = cam:project(100, 8, 100)
    local _, bottom = cam:project(100, -8, 100)
    check(math.abs((bottom - top) - 48) < 0.1, deg .. ": upright art keeps its pixel size at the focus (16 px -> 48)")
    local right = cam:project(116, 0, 100)
    check(math.abs((right - sx) - 48) < 1e-6, deg .. ": so does horizontal art")
    local _, near = cam:project(100, 0, 116)
    local want = 48 * math.tan(math.rad(deg))
    check(math.abs((near - sy) - want) < 1.5, deg .. ": ground depth shortens by tan(pitch)")
    local minX, maxX, minZ, maxZ = cam:groundBounds(0)
    check(minX < 100 and maxX > 100 and minZ < 100 and maxZ > 100, deg .. ": the ground under the focus is in view")
  end
  cam:frame(100, 0, 100, 960, 640, 3, true)
  local _, flippedTop = cam:project(100, 16, 100)
  check(flippedTop < 320, "project() answers in canvas rows whether or not clip y is pre-flipped")
end

do
  -- quads asking for derived art are placed on its page instead
  local atlas = {
    width = 64, height = 32, layered = false,
    origin = function(mid) return (mid % 4) * 16, math.floor(mid / 4) * 16 end,
  }
  local p = { 0, 0, 0, 16, 0, 0, 16, 0, 16, 0, 0, 16 }
  local quads = {
    { pair = "a", layer = "u", mid = 5, p = p, u0 = 0, v0 = 0, u1 = 16, v1 = 16, art = "cut", key = 1 },
    { pair = "a", layer = "u", mid = 6, p = p, u0 = 0, v0 = 0, u1 = 16, v1 = 16 },
    { pair = "a", layer = "u", mid = 7, p = p, u0 = 0, v0 = 0, u1 = 16, v1 = 16, art = "fill", key = 1 },
  }
  local asked = {}
  local groups = Mesher.build(quads, function() return atlas end, function(view, q)
    asked[#asked + 1] = q.art .. ":" .. q.mid .. ":" .. q.key
    if q.mid == 7 then return nil end
    return 2, 32, 48, 512
  end)
  eq(table.concat(asked, ","), "cut:5:1,fill:7:1", "only quads that ask are placed")
  eq(#groups, 2, "the atlas and one page")
  local onPage
  for _, g in ipairs(groups) do
    if g.page then onPage = g end
  end
  eq(onPage and onPage.page, 2, "grouped by page")
  check(math.abs(onPage.verts[1][4] - (32 + 0.02) / 512) < 1e-9, "u lands on the page's cell")
  check(math.abs(onPage.verts[3][5] - (48 + 16 - 0.02) / 512) < 1e-9, "v too")
  local plain
  for _, g in ipairs(groups) do
    if not g.page then plain = g end
  end
  eq(#plain.verts, 8, "art that cannot be made falls back to the atlas")
end

-- ------- cut-outs, on fake pixels

do
  local pages, uploads = {}, 0
  local function imageData(w, h)
    local px = {}
    return {
      w = w, h = h,
      getPixel = function(_, x, y)
        local c = px[y * w + x] or { 0, 0, 0, 1 }
        return c[1], c[2], c[3], c[4]
      end,
      setPixel = function(_, x, y, r, g, b, a) px[y * w + x] = { r, g, b, a } end,
    }
  end
  local saved = rawget(_G, "love")
  love = {
    image = { newImageData = function(w, h) local d = imageData(w, h); pages[#pages + 1] = d; return d end },
    graphics = { newImage = function()
      return { setFilter = function() end, replacePixels = function() uploads = uploads + 1 end }
    end },
  }

  local function rgb(r, g, b) return { r / 255, g / 255, b / 255, 1 } end
  local GRASS1, GRASS2 = rgb(115, 197, 164), rgb(65, 180, 131)
  local SHADE = rgb(24, 164, 106)        -- the grass's own darker hue
  local LEAF = rgb(131, 197, 98)
  local WALL = rgb(200, 180, 120)
  local atlasData = imageData(112, 16)
  local function paint(mid, f)
    for y = 0, 15 do
      for x = 0, 15 do
        local c = f(x, y)
        atlasData:setPixel(mid * 16 + x, y, c[1], c[2], c[3], c[4])
      end
    end
  end
  paint(0, function(x, y) return (x + y) % 2 == 0 and GRASS1 or GRASS2 end)
  -- a tree: leaves in the middle, a ring of shade, grass in the corners,
  -- and one shade pixel sealed inside the leaves
  paint(1, function(x, y)
    local d = math.max(math.abs(x - 7.5), math.abs(y - 7.5))
    if x == 7 and y == 7 then return SHADE end
    if d < 5 then return LEAF end
    if d < 6.5 then return SHADE end
    return GRASS1
  end)
  -- a wall with a strip of lawn down its left edge
  paint(2, function(x) return x == 0 and GRASS2 or WALL end)
  -- a wall down the middle of the grass
  paint(3, function(x) return x == 8 and WALL or GRASS1 end)
  -- a crate: its outline encloses more of the ground's colour
  paint(4, function(x, y)
    local d = math.max(math.abs(x - 7.5), math.abs(y - 7.5))
    if d > 4 and d < 5.5 then return WALL end
    return GRASS1
  end)
  local view = { pair = "p", imageData = atlasData,
    origin = function(mid) return mid * 16, 0 end }

  local cuts = Cutouts.new()
  local f = cuts:fraction(view, 1, 0)
  check(f > 0 and f < 0.5, "a tree is partly grass")
  eq(cuts:fraction(view, 2, 0), 16 / 256, "the wall is one column of it")
  eq(cuts:fraction(view, 0, 0), 1, "the ground is all ground")

  local page, x, y = cuts:resolve(view, 1, 0, "tree")
  eq(page, 1, "the first cut-out opens a page")
  local data = pages[1]
  local function alpha(px, py) local _, _, _, a = data:getPixel(x + px, y + py); return a end
  eq(alpha(0, 0), 0, "grass is cut away")
  eq(alpha(2, 7), 0, "and the ring of shade around the tree")
  eq(alpha(7, 4), 1, "the leaves stay")
  eq(alpha(7, 7), 1, "and shade sealed inside them is the tree's own")

  local p2, x2, y2 = cuts:resolve(view, 2, 0, "fill")
  check(p2 == 1 and (x2 ~= x or y2 ~= y), "the next cell on the same page")
  local r, g, b, a = data:getPixel(x2, y2 + 5)
  check(a == 1 and math.abs(r - WALL[1]) < 1e-9 and math.abs(b - WALL[3]) < 1e-9,
    "fill paints the lawn strip with the wall beside it")
  local p3, x3, y3 = cuts:resolve(view, 1, 0, "tree")
  eq(p3 .. ":" .. x3 .. ":" .. y3, page .. ":" .. x .. ":" .. y, "asking again reuses the copy")
  local p4, x4, y4 = cuts:resolve(view, 1, 0, "cut")
  local _, _, _, ringA = data:getPixel(x4 + 2, y4 + 7)
  eq(ringA, 1, "a plain cut leaves the shade alone")
  check(p4 ~= page or x4 ~= x or y4 ~= y, "and is a copy of its own")
  local function alphaAt(mode, mid, px, py)
    local pg, cx0, cy0 = cuts:resolve(view, mid, 0, mode)
    local _, _, _, al = pages[pg]:getPixel(cx0 + px, cy0 + py)
    return al
  end
  eq(alphaAt("trim15", 4, 0, 0), 0, "trim: the ground around a crate goes")
  eq(alphaAt("trim15", 4, 7, 7), 1, "what its outline encloses stays")
  eq(alphaAt("trim8", 3, 2, 5) .. alphaAt("trim8", 3, 12, 5), "01", "only what joins an open edge goes (west)")
  eq(alphaAt("trim2", 3, 2, 5) .. alphaAt("trim2", 3, 12, 5), "10", "(east)")
  eq(alphaAt("trim0", 3, 2, 5) .. alphaAt("trim0", 3, 12, 5), "11", "no open edge: nothing goes")
  eq(alphaAt("tree", 4, 0, 0) .. alphaAt("tree", 4, 7, 7), "01",
    "a card cuts the ground round it, and keeps what its outline encloses")
  -- a roof drawn on the overhead layer over the grass: one opaque copy
  local overData = imageData(112, 16)
  for y = 0, 15 do
    for x = 0, 15 do
      if x >= 4 then
        overData:setPixel(5 * 16 + x, y, WALL[1], WALL[2], WALL[3], 1)
      else
        overData:setPixel(5 * 16 + x, y, 0, 0, 0, 0)
      end
    end
  end
  paint(5, function() return GRASS1 end)
  local roofView = { pair = "r", imageData = atlasData, overImageData = overData,
    origin = function(mid) return mid * 16, 0 end }
  local rp, rx, ry = cuts:resolve(roofView, 5, 0, "roof")
  local function at(px, py) return pages[rp]:getPixel(rx + px, ry + py) end
  local r1, _, _, a1 = at(8, 8)
  check(a1 == 1 and math.abs(r1 - WALL[1]) < 1e-9, "the overhead art lies over the ground")
  local r2, _, _, a2 = at(1, 8)
  check(a2 == 1 and math.abs(r2 - WALL[1]) < 1e-9, "and the ground beside it is painted over with it")
  -- a walkable roof row over grass of another shade than the key: with both
  -- layers the shade stays; from the overhead alone, it is roof too
  for y = 0, 15 do
    for x = 0, 15 do
      if x >= 4 then
        overData:setPixel(6 * 16 + x, y, WALL[1], WALL[2], WALL[3], 1)
      else
        overData:setPixel(6 * 16 + x, y, 0, 0, 0, 0)
      end
    end
  end
  paint(6, function(x) return x < 4 and SHADE or GRASS1 end)
  local function red(mode)
    local pg, ox, oy = cuts:resolve(roofView, 6, 0, mode)
    local rr = pages[pg]:getPixel(ox + 1, oy + 8)
    return rr
  end
  check(math.abs(red("roof") - SHADE[1]) < 1e-9, "both layers: a shade off the key stays")
  check(math.abs(red("roofo") - WALL[1]) < 1e-9, "a walkable row's overhead alone: painted over with the roof")
  check(cuts:resolve({ pair = "q", origin = view.origin }, 1, 0, "cut") == nil,
    "no pixels on the CPU: no cut-out (the atlas is drawn as baked)")

  cuts:flush()
  eq(uploads, 1, "a changed page uploads once")
  cuts:flush()
  eq(uploads, 1, "and not again until it changes")
  cuts:release()
  eq(#cuts.pages, 0, "release drops the pages")
  love = saved
end

-- ------- the usual ground of a pair

do
  local mids = { [0] = { 1, 1, 7, 1 }, { 9, 1, 7, 7 } }
  local ctx = {
    mapId = "A",
    world = function() return { { id = "A", ox = 0, oy = 0, width = 4, height = 2, revision = 0 } } end,
    cell = function(cx, cy)
      local row = mids[cy]
      local mid = row and row[cx + 1] or 1
      return mid, "p", mid == 9 and 1 or 0, 3, nil, false
    end,
    walkable = function(coll) return coll == 0 end,
  }
  local atlas = { width = 16, height = 16, layered = false, origin = function() return 0, 0 end,
    coverage = function() return 0 end }
  local w = World.new({ cap = 2 })
  w:follow(ctx)
  local g = w:groundOf(ctx, function() return atlas end, "p")
  eq(g and g.mid, 1, "the floor the map shows most")
  mids[0] = { 7, 7, 7, 7 }
  w:markStale()
  eq(w:groundOf(ctx, function() return atlas end, "p").mid, 1, "kept until the next warp")
  eq(w:groundOf(ctx, function() return atlas end, "other"), nil, "a pair with no floor has none")
end

-- ------- the world's relief: cells carry their corners, actors stand on them

do
  local G = "gTileset_General+gTileset_Petalburg"
  local rows = { "TTTT", "FFFF", "....", "...." }
  local PIECE = { T = { 0x071, 0, "MOUNTAIN_TOP" }, F = { 0x07c, 1 }, ["."] = { 0x001, 0 } }
  local ctx = {
    mapId = "A", outdoors = true,
    world = function() return { { id = "A", ox = 0, oy = 0, width = 4, height = 4, revision = 0 } } end,
    cell = function(cx, cy)
      local row = rows[cy + 1]
      local p = PIECE[row and row:sub(cx + 1, cx + 1) or "."] or PIECE["."]
      local void = not row or cx < 0 or cx > 3
      return p[1], G, p[2], 3, p[3], void
    end,
    walkable = function(coll) return coll == 0 end,
  }
  local atlas = { width = 16, height = 16, layered = false, origin = function() return 0, 0 end,
    coverage = function() return 0 end }
  local function atlasOf() return atlas end
  local w = World.new({ cap = 2 })
  w:follow(ctx)
  local top, face = w:info(ctx, atlasOf, 1, 0), w:info(ctx, atlasOf, 1, 1)
  eq(top.rNW, 16, "a top a level up")
  check(face.relief and face.rNW == 16 and face.rSW == 0, "the face its own surface, hanging from it")
  eq(w:heightAt(ctx, atlasOf, 24, 16 + 8), 8, "halfway down the face, halfway up")
  eq(w:heightAt(ctx, atlasOf, 24, 40), 0, "the ground in front at 0")
  eq(w:info(ctx, atlasOf, 1, -3).rNW, 16, "the border north at the edge's level")
  local flat = World.new({ cap = 2, relief = false })
  flat:follow(ctx)
  eq(flat:info(ctx, atlasOf, 1, 0).rNW, nil, "TERRAIN HEIGHT off: no relief")
  local room = World.new({ cap = 2 })
  ctx.outdoors = false
  room:follow(ctx)
  eq(room:info(ctx, atlasOf, 1, 0).rNW, nil, "and none in a room")
end

-- ------- the chunk cache follows the player across a seam

do
  local cellsAsked = 0
  local placed = {
    { id = "A", ox = 0, oy = 0, width = 20, height = 20, revision = 0 },
    { id = "B", ox = 0, oy = -20, width = 20, height = 20, revision = 0 },
  }
  local ctx = {
    mapId = "A",
    world = function() return placed end,
    cell = function() cellsAsked = cellsAsked + 1; return 1, "p", 0, 3, nil, false end,
    walkable = function() return true end,
  }
  local w = World.new({ cap = 2 })
  w:follow(ctx)
  eq(w.originX .. "," .. w.originY, "0,0", "the first map is the origin")
  local gen = w.generation
  ctx.mapId = "B"
  placed = {
    { id = "B", ox = 0, oy = 0, width = 20, height = 20, revision = 0 },
    { id = "A", ox = 0, oy = 20, width = 20, height = 20, revision = 0 },
  }
  w:follow(ctx)
  eq(w.originY, -20, "walking north into B moves the origin by B's offset")
  eq(w.space, 1, "a seam keeps the same space")
  check(w.generation > gen, "and refreshes the void-dependent cells")
  ctx.mapId = "C"
  placed = { { id = "C", ox = 0, oy = 0, width = 10, height = 10, revision = 0 } }
  w:follow(ctx)
  eq(w.space, 2, "a warp starts a new space")
  eq(w.originX .. "," .. w.originY, "0,0", "at a fresh origin")
  local before = w.generation
  placed[1].revision = 1
  w:follow(ctx)
  check(w.generation > before, "a metatile write anywhere marks the built chunks stale")

  -- a chunk builds a row at a time and resumes where it stopped
  local atlas = { width = 16, height = 16, layered = false, origin = function() return 0, 0 end,
    coverage = function() return 0 end }
  local built = 0
  local saved = World.step
  local steps = 0
  local ticks = 0
  local yields = setmetatable({}, { __mode = "k" })
  local co = coroutine.create(function()
    return w:buildChunk(ctx, function() return atlas end, 0, 0, function() ticks = ticks + 1; coroutine.yield() end)
  end)
  while coroutine.status(co) ~= "dead" do
    local ok, groups = coroutine.resume(co)
    assert(ok, groups)
    steps = steps + 1
    if coroutine.status(co) == "dead" then built = groups and #groups or 0 end
  end
  eq(ticks, 16, "one tick per row of a 16-row chunk")
  check(built >= 1, "and the chunk lands at the end")
  World.step = saved

  -- a chunk whose tileset is still streaming waits its turn instead of
  -- eating every frame's budget
  local w2 = World.new({ cap = 2 })
  w2:follow(ctx)
  local tries = 0
  local realBuild = w2.buildChunk
  w2.buildChunk = function(self, ...)
    tries = tries + 1
    return realBuild(self, ...)
  end
  local noAtlas = function() return nil end
  local _, fresh, total = w2:prepare(ctx, noAtlas, 0, 0, 0, 0, 0, 0, 1e9, nil)
  eq(fresh, 0, "nothing lands while the atlas streams")
  local first = tries
  check(first == total, "every wanted chunk was tried once")
  w2:prepare(ctx, noAtlas, 0, 0, 0, 0, 0, 0, 1e9, nil)
  eq(tries, first, "and none is retried on the very next frame")
  for _ = 1, 20 do w2:prepare(ctx, noAtlas, 0, 0, 0, 0, 0, 0, 1e9, nil) end
  check(tries > first, "but they are retried a little later")
end

-- ------- the building profile (data/buildings.lua, lib/Buildings.lua)

local Buildings = lib("Buildings")

-- a map in the tiny language with the cells of a rectangle given their own
-- metatiles (ids row by row from `first`), every cell in `pair`
local function gridWith(rows, x0, y0, w, h, first, pair)
  local base = grid(rows)
  local memo = {}
  return function(cx, cy)
    local k = cx .. "," .. cy
    if memo[k] then return memo[k] end
    local c = {}
    for kk, v in pairs(base(cx, cy)) do c[kk] = v end
    c.pair = pair
    if cx >= x0 and cx < x0 + w and cy >= y0 and cy < y0 + h and c.mid then
      c.mid = first + (cy - y0) * w + (cx - x0)
    end
    memo[k] = c
    return c
  end
end

local HOUSE = {
  ".....",
  ".ooo.",
  ".###.",
  ".###.",
  ".#D#.",
  ".....",
}

do
  -- the shipped profile
  local data = assert(loadstring(readFile(ROOT .. "/data/buildings.lua"), "@buildings"))()
  local errs = Buildings.check(data)
  eq(#errs, 0, "the shipped profile checks out (" .. tostring(errs[1]) .. ")")
  local idx = Buildings.new(data)
  eq(#idx.entries, #data.buildings, "every entry is indexed")
  -- a drawing that shows its ridge is built from it wherever it stands, even
  -- with its top row walkable (the shallowest footprint it is listed with)
  for _, e in ipairs(idx.entries) do
    if e.ridge then
      local H = (#e.grid + (e.cap or 0)) * 16
      local k = #e.bands
      while k > 1 and Buildings.UPRIGHT[e.bands[k - 1][1]] do k = k - 1 end
      local b = Hip.block({ x0 = 0, x1 = #e.grid[1] * 16, zf = H, zb = 16, vt = e.bands[1][2],
        hw = H - e.bands[k][2], building = true, ridge = e.ridge })
      check(b.drawn and b.kind == "hip", e.id .. ": stands on its drawn ridge (t " .. tostring(b.t) .. ")")
    end
  end

  -- what the check catches
  local function bad(entry) return #Buildings.check({ buildings = { entry } }) > 0 end
  local ok = { id = "x", primary = "t", grid = { { 1, 2 }, { 3, 4 } },
    bands = { { "slope", 0, 15 }, { "wall", 16, 31 } } }
  eq(#Buildings.check({ buildings = { ok } }), 0, "a well-formed entry")
  check(bad({ id = "x", primary = "t", grid = { { 1, 2 }, { 3, 4 } },
    bands = { { "wall", 0, 15 }, { "slope", 10, 31 } } }), "overlapping bands")
  check(bad({ id = "x", primary = "t", grid = { { 1, 2 }, { 3, 4 } },
    bands = { { "slope", 0, 15 }, { "wall", 16, 40 } } }), "a band past the drawing")
  check(bad({ id = "x", primary = "t", grid = { { 1, 2 }, { 3, 4 } },
    bands = { { "roofish", 0, 15 }, { "wall", 16, 31 } } }), "an unknown kind")
  check(bad({ id = "x", primary = "t", grid = { { 1, 2 }, { 3, 4 } },
    bands = { { "wall", 0, 15 }, { "slope", 16, 31 } } }), "a drawing that does not end on its front wall")
  check(bad({ id = "x", primary = "t", grid = { { 1, 2 }, { 3, 4 } }, ridge = 8,
    bands = { { "slope", 0, 15 }, { "wall", 16, 31 } } }), "a ridge with no back slope drawn")
  check(bad({ id = "x", primary = "t", grid = { { 0x201, 2 }, { 3, 4 } },
    bands = { { "slope", 0, 15 }, { "wall", 16, 31 } } }), "secondary ids with no secondary named")
  check(bad({ id = "x", primary = "t", grid = { { 1, 2 }, { 3 } },
    bands = { { "slope", 0, 15 }, { "wall", 16, 31 } } }), "a ragged grid")
  check(bad({ id = "x", primary = "t", grid = { { 1, 2 }, { 3, 4 } }, parts = { { cols = { 1, 2 } } },
    bands = { { "slope", 0, 15 }, { "wall", 16, 31 } } }), "a part past the grid")

  local a, b = Buildings.tilesets("general__petalburg")
  check(a == "general" and b == "petalburg", "a pair's tilesets from its name")
  eq(Buildings.tilesets("p"), nil, "a pair named otherwise says nothing")
end

do
  -- finding a drawing: from any cell of it, the open cells too, and only in
  -- the tilesets it is drawn with
  local entry = { id = "house", primary = "t", secondary = "x",
    grid = { { 0x201, 0x202, 0x203 }, { 0x204, 0x205, 0x206 }, { 0x207, false, 0x209 }, { 0x20a, 0x20b, 0x20c } },
    bands = { { "slope", 0, 31 }, { "wall", 32, 63 } } }
  local idx = Buildings.new({ buildings = { entry } })
  eq(#idx.errors, 0, "a test entry")
  local info = gridWith(HOUSE, 1, 1, 3, 4, 0x201, "t__x")
  local all = true
  for cy = 1, 4 do
    for cx = 1, 3 do
      local e, ox, oy = idx:at(info, cx, cy)
      all = all and e == entry and ox == 1 and oy == 1
    end
  end
  check(all, "every cell of the drawing finds it, the open one through its row")
  eq(idx:at(info, 0, 2), nil, "a cell beside it does not")
  eq(idx:at(gridWith(HOUSE, 1, 1, 3, 4, 0x201, "t__y"), 2, 2), nil, "not in another secondary")
  check(idx:at(gridWith(HOUSE, 1, 1, 3, 4, 0x201, "p"), 2, 2) == entry, "a pair whose name says nothing: the grid decides")
  local prim = Buildings.new({ buildings = { { id = "mart", primary = "t",
    grid = { { 1, 2 }, { 3, 4 } }, bands = { { "slope", 0, 15 }, { "wall", 16, 31 } } } } })
  check(prim:at(gridWith(HOUSE, 1, 2, 2, 2, 1, "t__y"), 1, 2) ~= nil, "the primary's own drawing in any secondary")
  eq(prim:at(gridWith(HOUSE, 1, 2, 2, 2, 1, "u__y"), 1, 2), nil, "but not with another primary")

  -- the numbers: the wall up to the upright run's top, at the block's front;
  -- the cap above the grid; a part over some of the grid's columns; the
  -- upper storey's band with its eave line, set in from the block's sides
  local two = Buildings.new({ buildings = { {
    id = "two", primary = "t", cap = 1,
    grid = { { 1, 2, 3, 4, 5 }, { 6, 7, 8, 9, 10 }, { 11, 12, 13, 14, 15 } },
    bands = { { "slope", 0, 18 }, { "eave", 19, 21 }, { "upper", 22, 27 }, { "skirt", 28, 34 },
      { "fascia", 35, 37 }, { "wall", 38, 61 }, { "base", 62, 63 } },
    upper = { 10, 69 },
    parts = { { cols = { 2, 2 }, roof = "flat", bands = { { "flat", 1, 39 }, { "wall", 40, 63 } } } },
  } } })
  local tinfo = gridWith({ ".....", ".....", ".....", ".....", "....." }, 0, 2, 5, 3, 1, "t__x")
  local s = two:block(tinfo, 0, 4, 4, 80)
  check(s ~= nil and s.id == "two", "the whole front")
  eq(s.vt, 16, "the drawing's top is the cap's (one row above the grid)")
  eq(s.hw, 80 - (16 + 35), "walls up to the fascia's top")
  check(s.tier and s.tier.vtop == 16 + 19 and s.tier.vb == 16 + 28 and s.tier.inset == 10,
    "the upper storey with its eave line, 10 in from the sides")
  check(not s.flat and not s.ridge, "a hipped roof with no ridge drawn")
  local p = two:block(tinfo, 2, 2, 4, 80)
  check(p and p.id == "two/1" and p.flat and p.hw == 80 - (16 + 40), "a part over one column: its own rows and roof")
  check(p.tier == nil, "and no upper storey of its own")
  eq(two:block(tinfo, 0, 4, 4, 60).hw, 60 - 51, "the wall measured at the block's own front")
end

do
  -- a house that shows its ridge: as deep as the drawing makes it, the back
  -- slope drawn, nothing mirrored, the collision behind open
  local entry = { id = "house", primary = "t", secondary = "x",
    grid = { { 0x201, 0x202, 0x203 }, { 0x204, 0x205, 0x206 }, { 0x207, 0x208, 0x209 }, { 0x20a, 0x20b, 0x20c } },
    ridge = 9,
    bands = { { "back", 0, 7 }, { "ridge", 8, 11 }, { "slope", 12, 31 }, { "fascia", 32, 33 },
      { "eave", 34, 34 }, { "wall", 35, 61 }, { "base", 62, 63 } } }
  local idx = Buildings.new({ buildings = { entry } })
  local info = gridWith(HOUSE, 1, 1, 3, 4, 0x201, "t__x")
  local q = build(info, 0, 0, 5, 6, { cap = 2, tuft = 5, buildings = idx })
  -- walls 32 (80 - 48); the front slope takes 23 rows to the ridge at v 25,
  -- the back 9: 32 deep, slope 14/32
  local hw, D2, t = 32, 32, 14 / 32
  local roof = pick(q, "roof", "u")
  local top, mirrored, backOk, exact = -math.huge, 0, true, true
  for _, r in ipairs(roof) do
    if r.mirror then mirrored = mirrored + 1 end
    for _, c in ipairs(corners(r)) do
      top = math.max(top, c[2])
      if c[3] < 80 - D2 - 1e-6 then backOk = false end
    end
    if r.face == "back" then
      for _, c in ipairs(corners(r)) do
        local v = c[3] - c[2]
        if v < 16 - 1e-6 or v > 25 + 1e-6 then backOk = false end
      end
    end
    for _, v in ipairs(r.poly) do
      if math.abs(v[1] - v[4] - r.cx * 16) > 1e-6 or math.abs(v[3] - v[2] - v[5] - r.cy * 16) > 1e-6 then
        exact = false
      end
    end
  end
  check(math.abs(top - (hw + t * D2 / 2)) < 1e-6, "the ridge as high as the drawn slope makes it (" .. top .. ")")
  eq(mirrored, 0, "nothing mirrored")
  check(backOk, "the back slope is the drawing's rows over the ridge, inside the drawn depth")
  check(exact, "every texel its own projection, back slope too")
  local area = 0
  for _, x in ipairs(q) do
    if x.layer == "u" and x.poly and x.cx and x.face ~= "foot" and (x.kind == "roof" or x.kind == "facade") then
      area = area + projArea(x)
    end
  end
  check(math.abs(area - 48 * 64) < 48 * 0.3, "covering the drawing once at 45 degrees (" .. area .. ")")
  local facade = pick(q, "facade", "u")
  local fy = 0
  for _, f in ipairs(facade) do fy = math.max(fy, (select(2, extent(f, 2)))) end
  check(math.abs(fy - hw) < 0.2, "the front wall up to the fascia's top (" .. fy .. ")")
  local backs = pick(q, "back", "u")
  check(#backs == 1 and math.abs(corners(backs[1])[1][3] - (80 - D2)) < 1e-6, "a back wall at the drawn depth")
  local cov = coverage(q)
  check(cov["2,2"], "open ground behind it")

  -- the same drawing read off its pixels (here: none) is the 1.6.0 hip,
  -- its back mirrored
  local plain = build(info, 0, 0, 5, 6, { cap = 2, tuft = 5 })
  local m = 0
  for _, r in ipairs(pick(plain, "roof", "u")) do if r.mirror then m = m + 1 end end
  check(m > 0, "without the profile: the mirrored back")
end

do
  -- a roof drawn from straight above, on a block with no door on its front
  -- (the Gym's wings): a building all the same, flat, as deep as drawn
  local rows = { ".....", ".###.", ".###.", ".###.", ".###.", "....." }
  local entry = { id = "wing", primary = "t", secondary = "x", roof = "flat",
    grid = { { 0x201, 0x202, 0x203 }, { 0x204, 0x205, 0x206 }, { 0x207, 0x208, 0x209 }, { 0x20a, 0x20b, 0x20c } },
    bands = { { "flat", 1, 39 }, { "eave", 40, 40 }, { "wall", 41, 63 } } }
  local idx = Buildings.new({ buildings = { entry } })
  local q = build(gridWith(rows, 1, 1, 3, 4, 0x201, "t__x"), 0, 0, 5, 6, { cap = 2, tuft = 5, buildings = idx })
  local hw = 80 - (16 + 40)
  local level = true
  local roof = pick(q, "roof", "u")
  for _, r in ipairs(roof) do
    local y0, y1 = extent(r, 2)
    if math.abs(y0 - hw) > 1e-6 or math.abs(y1 - hw) > 1e-6 then level = false end
  end
  check(#roof > 0 and level, "a flat roof at the walls' height")
  -- the drawing from its first row (one down its top cell) to the front,
  -- covered once at 45 degrees
  local area = 0
  for _, x in ipairs(q) do
    if x.layer == "u" and x.poly and x.cx and x.face ~= "foot" and (x.kind == "roof" or x.kind == "facade") then
      area = area + projArea(x)
    end
  end
  check(math.abs(area - 48 * (80 - 17)) < 48 * 0.3, "the drawing covered once, its top rows too (" .. area .. ")")
  local zlo = 17 + hw
  local backs = pick(q, "back", "u")
  check(#backs == 1, "a back wall, no slope behind")
  local bz = backs[1] and corners(backs[1])[1][3]
  check(bz and math.abs(bz - zlo) < 1e-6, "at the drawn depth (" .. tostring(bz) .. ")")
  local plain = build(grid(rows), 0, 0, 5, 6)
  local slope = false
  for _, bq in ipairs(pick(plain, "back", "u")) do
    for _, c in ipairs(corners(bq)) do if c[2] > 0 and math.abs((c[3] - c[2]) - 16) < 1e-6 then slope = true end end
  end
  check(slope, "without the profile: a block with a back plane at 45 degrees")

  -- its foot drawn half a row into the walkable row under it: the front wall
  -- stands there, the lowest rows of it that row's own art
  local rows2 = { ".....", ".###.", ".###.", ".###.", ".....", "....." }
  local wing = { id = "wing", primary = "t", secondary = "x", roof = "flat",
    grid = { { 0x201, 0x202, 0x203 }, { 0x204, 0x205, 0x206 }, { 0x207, 0x208, 0x209 }, { 0x20a, 0x20b, 0x20c } },
    bands = { { "flat", 1, 30 }, { "eave", 31, 31 }, { "wall", 32, 51 }, { "base", 52, 55 } } }
  local widx = Buildings.new({ buildings = { wing } })
  local wq = build(gridWith(rows2, 1, 1, 3, 4, 0x201, "t__x"), 0, 0, 5, 6, { cap = 2, tuft = 5, buildings = widx })
  local at72, below, wallTop = true, false, 0
  for _, f in ipairs(pick(wq, "facade", "u")) do
    local z0, z1 = extent(f, 3)
    if math.abs(z0 - 72) > 1e-6 or math.abs(z1 - 72) > 1e-6 then at72 = false end
    if f.cy == 4 then below = true end
    wallTop = math.max(wallTop, (select(2, extent(f, 2))))
  end
  check(at72, "the front wall at the drawing's foot, z 72")
  check(below, "its lowest rows from the row under the collision")
  check(math.abs(wallTop - 25) < 0.2, "as high as the drawing makes it there (" .. wallTop .. ")")
  local flatTop = true
  for _, r in ipairs(pick(wq, "roof", "u")) do
    local y0, y1 = extent(r, 2)
    if math.abs(y0 - 25) > 1e-6 or math.abs(y1 - 25) > 1e-6 then flatTop = false end
  end
  check(flatTop, "and the roof level with its eaves")
end

-- ------- the mod, through the real loader, on a Gen 3 game
-- (whether the Gen 3 world pass serves a record like this one is the
-- engine's business, pinned by tests/engine/game3_world_pipeline_test.lua)

do
  local r = T.sdk.loadMod(ROOT, { generation = 3, data = T.sdk.gen3Data() })
  eq(#r.errors, 0, "loads clean on Gen 3 (" .. tostring(r.errors[1] and (r.errors[1].message or r.errors[1])) .. ")")
  local rec = r.data.render_pipelines and r.data.render_pipelines.hoenn_diorama
  check(rec ~= nil, "registers the hoenn_diorama render pipeline")
  if rec then
    eq(rec.generations and rec.generations[1], 3, "asks for the Gen 3 world ctx")
    eq(#rec.generations, 1, "and only that one")
    eq(#rec.levels, 4, "OFF and three pitches")
    eq(rec.hotkey, "6", "the 6 key")
    check(type(rec.available) == "function" and type(rec.update) == "function"
      and type(rec.invalidate) == "function", "available, update and invalidate are wired")
    -- headless there is no GPU: the pipeline must decline, never throw
    eq(rec.available(), false, "no shaders, no diorama")
    local ok, out = pcall(rec.drawWorld, { level = 1, width = 8, height = 8 })
    check(ok, "drawWorld does not throw headless: " .. tostring(out))
    eq(out, nil, "and declines, leaving the flat field")
  end
  -- the building profile reaches the scene through mod:read, and checks out
  local ex = r.loader.exports and r.loader.exports.hoenn_diorama
  local sc = ex and ex.scene
  local prof = sc and sc.world and sc.world.params and sc.world.params.buildings
  check(prof ~= nil, "the building profile is loaded and on by default")
  check(prof and #prof.entries > 0 and #prof.errors == 0, "with every entry indexed")
  r.release()
end

T.finish("hoenn_diorama")
