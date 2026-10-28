-- How the Hoenn General tileset draws a mountain: the sets of metatiles its
-- pieces are drawn with and the colours of its rock.  These are Emerald 3DS's
-- readings of the tileset (ZallaxDev/emerald-3ds, scripts/voxel_terraces.py
-- and gen_voxel_relief.py, MIT), restated here as data.  Ids are pret's
-- metatile ids of the General primary (0x000-0x1ff).
local function set(...)
  local s = {}
  for _, v in ipairs({ ... }) do s[v] = true end
  return s
end

local function range(s, a, b)
  for i = a, b do s[i] = true end
  return s
end

local T = {}

T.LEVEL = 16

-- the rock's colours, 5-bit GBA
T.TOP = { { 27, 22, 20 }, { 23, 18, 17 } }
T.RIM = { { 29, 26, 25 } }
T.FACE = { { 16, 11, 11 }, { 12, 8, 10 }, { 8, 6, 8 } }
T.FLECK = { { 19, 14, 14 } }          -- in both: a top's speckle, a face's shading

-- the sides, by the way they fall ("W": high side east)
T.BAND_WEST = set(0x070, 0x073, 0x088, 0x06b, 0x080, 0x083, 0x068, 0x172, 0x175, 0x177, 0x17a)
T.BAND_EAST = set(0x072, 0x075, 0x0a2, 0x08a, 0x06d, 0x082, 0x084, 0x06a, 0x174, 0x176, 0x17c, 0x0a4)
-- a band's head over the ground behind it: over a top it is that top's
-- corner where its back turns
T.HEADS = { [0x068] = "W", [0x083] = "W", [0x080] = "W", [0x06a] = "E", [0x084] = "E", [0x082] = "E" }
T.BOULDER = set(0x093, 0x094, 0x09b, 0x09c)
T.BOULDER_FOOT = set(0x09b, 0x09c)
T.BOULDER_HEAD = set(0x093, 0x094)
T.LOOSE = set(0x0df, 0x0e0, 0x0e1, 0x0e2)
T.CARVED_STEPS = set(0x0e8, 0x0e9, 0x0ea, 0x0eb)
-- a diagonal edge drawn as a staircase of face ends: one wall, one level
T.UPPER_END = set(0x074, 0x089)
T.LOWER_END = set(0x07d, 0x07b, 0x078, 0x092, 0x090)
T.BAND_HEAD = { E = set(0x074), W = set(0x089) }
T.BAND_FOOT = { E = set(0x07a, 0x07d, 0x092), W = set(0x07b, 0x078, 0x090) }
T.FACE_SOUTH = set(0x07c, 0x0a9, 0x09f, 0x0a7, 0x091, 0x079, 0x1b0, 0x0af, 0x0cf, 0x1f0, 0x1f1)
-- bare soil drawn in the faces' colours: flat ground
T.DIRT = set(0x113, 0x114, 0x115, 0x14b, 0x14c, 0x14d)

-- the mountain's own tiles: nothing else is ever rock, whatever its colours
T.MOUNTAIN = range(range({}, 0x064, 0x0bf), 0x172, 0x192)
for _, m in ipairs({ 0x1a0, 0x1a8, 0x1b0, 0x1f0, 0x1f1 }) do T.MOUNTAIN[m] = true end
for m in pairs(T.FACE_SOUTH) do T.MOUNTAIN[m] = true end
for m in pairs(T.BOULDER) do T.MOUNTAIN[m] = true end
for m in pairs(T.DIRT) do T.MOUNTAIN[m] = nil end

-- the settle's prices (voxel_terraces.blocks)
T.COST = {
  FIN = 3.0,          -- a band climbing past the terrace it flanks
  STEEP = 0.4,        -- a band falling two levels in its tile
  CORNER = 0.3,       -- a corner piece instead of the drawing's kind
  OTHER_KIND = 0.6,   -- the other kind than the drawing's
  OFF_LEVEL = 0.25,   -- a level off the counted one
  KEPT = 10.0,        -- standing over a ledge or berry soil beside it
  BACK = 0.3,         -- the ground behind a top lower than it
  PITS = { { 0.3, 10 }, { 1.0, 10 }, { 3.0, 10 }, { 10.0, 30 } },
}

-- cell reading thresholds
T.FACE_SHARE = 0.4    -- of its pixels drawn as face: a face, else a top

return T
