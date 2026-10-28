-- The building profile: what each building drawing shows, read by a person.
--
-- Hip.lua and Shape.lua read every building the same way, from its pixels:
-- where the walls end (`eaveOf`), whether a band across the roof is an upper
-- storey (`tierOf`).  That reading is right most of the time and wrong in a
-- different way in every town that draws its houses differently.  This file
-- is the other half, the way Dramatic Shape pins its tiles and Emerald 3DS
-- writes its specs: for a drawing listed here, a person has read its rows
-- once, and that reading is used wherever the same drawing stands.  A
-- drawing that is not listed keeps the pixel reading.
--
-- Only what needs a person is written down: which rows of the drawing are
-- roof, ridge, fascia, wall; where the drawing shows its ridge; whether the
-- roof is drawn from straight above.  Everything measurable (the wall height
-- in pixels at a given front, the slope, the depth) is worked out from these
-- rows by lib/Buildings.lua and Hip.lua.
--
-- Nothing here comes from the cartridge: metatile ids, row numbers and names.
--
-- An entry:
--
--   id        a name
--   primary   the primary tileset the grid's ids below 0x200 come from
--   secondary the secondary tileset, when the grid uses ids from 0x200 up;
--             without it the drawing is the primary's own and stands in any
--             town that shares the primary (the Pokémon Center, the Mart)
--   grid      the drawing's metatiles, north row first; `false` is a cell any
--             metatile may fill (a town paints its own ground there)
--   cap       rows of the drawing above the grid that no town draws the same
--             (the Pokémon Center's dome over whatever ground is behind it);
--             they belong to the drawing but are not matched.  Default 0
--   bands     what each pixel row shows, top-down, as { kind, first, last },
--             rows counted from the drawing's top (the cap's, if any):
--               back    roof beyond the ridge (the drawing shows it: the
--                       roof is pitched under 45 degrees)
--               ridge   the ridge cap
--               slope   the front of the roof
--               dome    a rounded roof (painted on the slope for now)
--               flat    a roof drawn from straight above
--               skirt   a lower roof round an upper storey
--               upper   the upper storey's wall
--               fascia  the board along the eaves, standing upright
--               eave    the dark line under the eaves, upright
--               soffit  the shadow on the wall under the eaves
--               wall    the facade
--               base    the plinth and the drawing's last outline
--             fascia, eave, soffit, wall and base are upright: the run of
--             them at the bottom is the front wall, so its top row gives the
--             wall height; fascia and eave above `upper` give its front.
--   roof      "hip" (default) or "flat"
--   ridge     the row of the ridge line, for a drawing that shows its ridge
--             and its back slope: the building is then as deep as the
--             drawing makes it with level eaves, and its back slope takes the
--             drawing as drawn instead of a mirror of the front
--   upper     { first column, last column } of the upper storey's wall
--   parts     { { cols = { first, last }, ... } }: bands, roof and ridge for
--             the blocks over those grid columns (a porch with its own front)
--
-- Read and checked, not used yet: `inset` (the walls' columns in from the
-- roof's edges, west and east, px), `chamfer` (front corners cut at 45
-- degrees, px).  Hip builds walls round the whole footprint and square.

-- ------- band tables, shared by the drawings that draw their roofs alike

-- Petalburg's red-tiled houses: the back slope over a ridge cap, the front
-- slope, a two-row fascia over the eave line
local PETALBURG = {
  { "back", 0, 9 }, { "ridge", 10, 15 }, { "slope", 16, 34 },
  { "fascia", 35, 36 }, { "eave", 37, 37 }, { "soffit", 38, 39 },
  { "wall", 40, 61 }, { "base", 62, 63 },
}

-- Oldale's brown-tiled houses: the same build, a thinner ridge
local OLDALE = {
  { "back", 0, 9 }, { "ridge", 10, 13 }, { "slope", 14, 33 },
  { "fascia", 34, 34 }, { "eave", 35, 36 }, { "soffit", 37, 39 },
  { "wall", 40, 61 }, { "base", 62, 63 },
}

-- Littleroot's two-storey houses: the upper roof runs off the drawing's top
-- (no ridge shown), the upper storey's wall under its eave line, the skirt
-- round it, then the ground floor
local LITTLEROOT = {
  { "slope", 0, 18 }, { "eave", 19, 21 }, { "upper", 22, 27 },
  { "skirt", 28, 34 }, { "eave", 35, 37 }, { "soffit", 38, 39 },
  { "wall", 40, 61 }, { "base", 62, 63 },
}

return {
  version = 1,
  buildings = {
    -- Petalburg City (5,2); also Route 114 and Route 116
    { id = "petalburg_house_wide", primary = "general",
      grid = {
        { 0x008, 0x009, 0x009, 0x009, 0x00a },
        { 0x010, 0x011, 0x011, 0x011, 0x012 },
        { 0x018, 0x00b, 0x019, 0x00b, 0x01a },
        { 0x020, 0x013, 0x021, 0x013, 0x022 },
      },
      bands = PETALBURG, ridge = 12, inset = { 2, 2 } },

    -- Petalburg City (9,16) and (19,21); also Lavaridge, Routes 111, 117,
    -- 119, 123 and the Safari Zone
    { id = "petalburg_house", primary = "general",
      grid = {
        { 0x008, 0x009, 0x009, 0x00a },
        { 0x010, 0x011, 0x011, 0x012 },
        { 0x018, 0x019, 0x00b, 0x01a },
        { 0x020, 0x021, 0x013, 0x022 },
      },
      bands = PETALBURG, ridge = 12, inset = { 2, 2 } },

    -- Oldale Town (4,4) and (14,13)
    { id = "oldale_house", primary = "general", secondary = "petalburg",
      grid = {
        { 0x26c, 0x26d, 0x26d, 0x26e },
        { 0x274, 0x275, 0x275, 0x276 },
        { 0x27c, 0x27f, 0x27d, 0x27e },
        { 0x284, 0x287, 0x28f, 0x286 },
      },
      bands = OLDALE, ridge = 11, inset = { 2, 2 } },

    -- Littleroot Town: Brendan's house (door east of the middle) and May's
    -- (west of it), mirror images
    { id = "littleroot_house_w", primary = "general", secondary = "petalburg",
      grid = {
        { 0x210, 0x211, 0x211, 0x211, 0x212 },
        { 0x218, 0x219, 0x219, 0x219, 0x21a },
        { 0x222, 0x232, 0x230, 0x240, 0x221 },
        { 0x22a, 0x23a, 0x238, 0x248, 0x229 },
      },
      bands = LITTLEROOT, upper = { 10, 69 }, inset = { 2, 2 } },
    { id = "littleroot_house_e", primary = "general", secondary = "petalburg",
      grid = {
        { 0x210, 0x211, 0x211, 0x211, 0x212 },
        { 0x218, 0x219, 0x219, 0x219, 0x21a },
        { 0x220, 0x240, 0x231, 0x232, 0x223 },
        { 0x228, 0x248, 0x239, 0x23a, 0x22b },
      },
      bands = LITTLEROOT, upper = { 10, 69 }, inset = { 2, 2 } },

    -- Littleroot Town: Professor Birch's lab.  A flat roof with a railing
    -- along its back and the machine standing on it (painted on the roof for
    -- now: columns 16-47, rows 2-31)
    { id = "birch_lab", primary = "general", secondary = "petalburg",
      grid = {
        { 0x20c, 0x242, 0x243, 0x20d, 0x20d, 0x20d, 0x20e },
        { 0x214, 0x24a, 0x24b, 0x215, 0x215, 0x215, 0x216 },
        { 0x214, 0x215, 0x215, 0x215, 0x215, 0x215, 0x216 },
        { 0x21e, 0x20f, 0x20f, 0x22c, 0x241, 0x22d, 0x21f },
        { 0x226, 0x217, 0x217, 0x234, 0x249, 0x235, 0x227 },
      },
      roof = "flat",
      bands = {
        { "flat", 1, 51 }, { "eave", 52, 52 }, { "soffit", 53, 55 },
        { "wall", 56, 77 }, { "base", 78, 79 },
      } },

    -- The Pokémon Center of Oldale, Petalburg, Slateport, Mauville,
    -- Verdanturf, Lavaridge, Fortree, Lilycove, Mossdeep, Ever Grande and the
    -- Battle Frontier: the dome's top row is the cap, each town paints its own
    -- ground round it
    { id = "pokemon_center", primary = "general", cap = 1,
      grid = {
        { 0x050, 0x051, 0x052, 0x053 },
        { 0x058, 0x059, 0x05a, 0x05b },
        { 0x060, 0x061, 0x062, 0x063 },
      },
      bands = {
        { "dome", 0, 15 }, { "slope", 16, 38 }, { "eave", 39, 39 },
        { "soffit", 40, 41 }, { "wall", 42, 61 }, { "base", 62, 63 },
      },
      chamfer = 6 },

    -- The Poké Mart of Oldale, Petalburg, Slateport, Mauville, Verdanturf,
    -- Lavaridge, Fortree, Mossdeep and the Battle Frontier: the Center's
    -- build with a lower roof.  Its roof's top rows are in the cap (Petalburg
    -- draws a tree's foot over them, Oldale a tree beside them)
    { id = "poke_mart", primary = "general", cap = 1,
      grid = {
        { 0x030, 0x031, 0x032, 0x033 },
        { 0x038, 0x039, 0x03a, 0x03b },
        { 0x060, 0x041, 0x042, 0x043 },
      },
      bands = {
        { "slope", 8, 38 }, { "eave", 39, 39 }, { "soffit", 40, 41 },
        { "wall", 42, 61 }, { "base", 62, 63 },
      },
      chamfer = 6 },

    -- Petalburg's Gym (Mauville's and Mossdeep's are the same drawing): a
    -- flat roof over two wings, and a porch standing a cell further out with
    -- its own front.  The wings' wall runs on 8 rows into the walkable row
    -- under them (their base is row 71); Shape stands their front on the
    -- collision's edge, so those rows stay on the ground.
    { id = "gym", primary = "general",
      grid = {
        { 0x1aa, 0x1ab, 0x1ab, 0x1ab, 0x1ab, 0x1ac },
        { 0x1b2, 0x1b3, 0x1b3, 0x1b3, 0x1b3, 0x1b4 },
        { 0x1b8, 0x1b9, 0x1ba, 0x1b3, 0x1bb, 0x1bc },
        { 0x1c0, 0x1c1, 0x1c2, 0x1c5, 0x1c3, 0x1c4 },
        { false, false, 0x1ca, 0x1cd, 0x1cb, false },
      },
      roof = "flat",
      bands = {
        { "flat", 1, 41 }, { "fascia", 42, 44 }, { "eave", 45, 45 },
        { "soffit", 46, 47 }, { "wall", 48, 69 }, { "base", 70, 71 },
      },
      parts = {
        { cols = { 2, 4 }, chamfer = 6, bands = {
          { "flat", 1, 49 }, { "fascia", 50, 52 }, { "eave", 53, 53 },
          { "soffit", 54, 56 }, { "wall", 57, 76 }, { "base", 77, 79 },
        } },
      } },

    -- Route 104: the Pretty Petal flower shop.  A roof with no ridge shown
    -- over a deep red fascia board
    { id = "flower_shop", primary = "general", secondary = "rustboro",
      grid = {
        { 0x248, 0x249, 0x24a, 0x24b, 0x24c, 0x24d },
        { 0x250, 0x251, 0x252, 0x253, 0x254, 0x255 },
        { 0x258, 0x259, 0x25a, 0x25b, 0x25c, 0x25d },
        { 0x260, 0x261, 0x262, 0x263, 0x264, 0x265 },
      },
      bands = {
        { "slope", 0, 27 }, { "fascia", 28, 36 }, { "eave", 37, 37 },
        { "soffit", 38, 39 }, { "wall", 40, 61 }, { "base", 62, 63 },
      } },

    -- Route 104: Mr. Briney's cottage.  A thatched back slope over a timber
    -- ridge beam, the front thatch, and a band of windows under the eaves
    { id = "briney_cottage", primary = "general", secondary = "rustboro",
      grid = {
        { 0x268, 0x269, 0x26a, 0x26b, 0x26c },
        { 0x270, 0x271, 0x272, 0x273, 0x274 },
        { 0x278, 0x279, 0x27a, 0x27b, 0x27c },
        { 0x280, 0x281, 0x282, 0x283, 0x284 },
      },
      ridge = 12,
      bands = {
        { "back", 0, 8 }, { "ridge", 9, 15 }, { "slope", 16, 35 },
        { "eave", 36, 38 }, { "wall", 39, 61 }, { "base", 62, 63 },
      } },
  },
}
