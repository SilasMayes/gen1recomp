-- How a flat Gen 3 map stands up.
--
-- Hoenn's art is drawn in three-quarter view: a building's facade, a tree's
-- trunk, a sign are painted as if seen from the front, and their roofs and
-- canopies take up the screen rows "behind" them.  So the diorama does not
-- invent shapes; it re-folds the art it is given:
--
--   * A column of blocked cells is a structure.  Its bottom CAP cells stand
--     up as an upright facade on the structure's front edge, and the rest lie
--     on top, slid forward by CAP rows so they meet the facade's top edge.
--     Seen at 45 degrees that puts every pixel back where the 2D field drew
--     it, which is the whole trick.  Outdoors the columns that share a run
--     are one block, built as a solid by Hip.lua: a building (it has a door)
--     with walls round its footprint and a hipped roof, anything else with a
--     flat top; every face the 45 degree camera sees takes the drawing
--     projected onto it.
--   * A walkable cell whose overhead (BG1) layer covers actors, sitting on
--     top of a structure, is that structure's upper part: a tree's canopy, a
--     roof's top edge.  Its overhead art goes up with the structure and its
--     ground stays where you walk.
--   * A blocked cell that is not on the structure layer (elevation other than
--     0: signs, mailboxes, posts) stands alone as a 16px card, unless it hangs
--     under a structure, when it is that structure's bottom row.
--   * Water drops a few pixels below the bank, tall grass grows a short tuft
--     on its front edge, and a ledge is a low step with its face showing.
--
-- Pure Lua.  `info(cx, cy)` supplies classified cells (World.lua); `emit(q)`
-- receives quads, each { pair, layer = "u" | "o", mid, kind, p (12 numbers:
-- TL, TR, BR, BL corners), u0, v0, u1, v1 (texels inside the 16x16 metatile),
-- shade }.  World space is world pixels: x east, y up, z south.

local lib = ...
local Hip = lib("Hip")

local Shape = {}

local C = 16
Shape.CELL = C

Shape.defaults = {
  cap = 2,        -- facade height in cells
  maxRun = 48,    -- how far north a structure is followed
  waterDrop = 4,  -- how far water sits below its bank
  tuft = 5,       -- tall-grass tuft height
  ledge = 5,      -- ledge step height
  pitch = 0.45,   -- an outdoor roof's slope: rise per pixel (about 24 degrees)
}

-- ------- behaviors, by the names ctx.cell reports (src/core/game3/mb.lua)

local function isWater(name)
  if not name then return false end
  if name == "SHALLOW_WATER" or name:find("PUDDLE", 1, true) then return false end
  return name:find("WATER", 1, true) ~= nil or name:find("CURRENT", 1, true) ~= nil
    or name:find("OCEAN", 1, true) ~= nil
end

local function isGrass(name)
  return name == "TALL_GRASS" or name == "LONG_GRASS"
end

local function isLedge(name)
  return name ~= nil and name:sub(1, 5) == "JUMP_"
end

local function isDoor(name)
  return name ~= nil and name:find("DOOR", 1, true) ~= nil
end

-- Furniture in a room that stands at full height: what the game itself
-- tags as a shelf, a set, a machine (the behaviour the player reads by
-- facing it).  Anything else free-standing in a room is a low block.
local TALL = {
  BOOKSHELF = true, PICTURE_BOOK_SHELF = true, POKEMON_CENTER_BOOKSHELF = true,
  SHOP_SHELF = true, TRASH_CAN = true, VASE = true, SLOT_MACHINE = true,
  TELEVISION = true, PC = true, PLAYER_ROOM_PC_ON = true, SECRET_BASE_PC = true,
  SECRET_BASE_REGISTER_PC = true, CABLE_BOX_RESULTS_1 = true, CABLE_BOX_RESULTS_2 = true,
  QUESTIONNAIRE = true, TRAINER_HILL_TIMER = true, POKEBLOCK_FEEDER = true,
  BLUEPRINT = true, REGION_MAP = true,
  -- FRLG names, for completeness
  CABINET = true, KITCHEN = true, DRESSER = true, SNACKS = true, FOOD = true,
}
Shape.TALL = TALL

Shape.isWater, Shape.isGrass, Shape.isLedge, Shape.isDoor = isWater, isGrass, isLedge, isDoor

-- Overhead coverage below this is a stray pixel, not a canopy.
local OVER_MIN = 0.04

--- Classify one sampled cell.  `walk` is ctx.walkable(coll); `over` the
-- metatile's overhead coverage (0..1).  Returns the kind:
--   "blank"    nothing to draw (BLACK void fill, or a pair not loaded)
--   "water"    unwalkable water
--   "ledge"    a jump ledge
--   "solid"    a structure cell (blocked on elevation 0, or a door)
--   "object"   a blocked cell on the walking layer
--   "overhang" walkable ground with overhead art over it
--   "floor"    everything else
function Shape.classify(c)
  if c.mid == nil then return "blank" end
  local beh = c.beh
  if isLedge(beh) then return "ledge" end
  if isDoor(beh) then return "solid" end
  if not c.walk then
    if isWater(beh) then return "water" end
    if (c.elev or 0) == 0 then return "solid" end
    return "object"
  end
  if (c.over or 0) > OVER_MIN then return "overhang" end
  return "floor"
end

-- ------- runs

local function isBlock(kind) return kind == "solid" or kind == "object" end

-- A blocked cell poking one row out under a wider structure -- the sign in
-- front of a lab, a mailbox under an eave -- is its own object, not a column
-- of the building jutting forward.
local function detached(info, cx, cy)
  if isBlock(info(cx - 1, cy).kind) or isBlock(info(cx + 1, cy).kind) then return false end
  return info(cx, cy - 1).kind == "solid" and info(cx - 1, cy - 1).kind == "solid"
    and info(cx + 1, cy - 1).kind == "solid"
end
Shape.detached = detached

-- Column membership and the run around (cx, cy).  A run is a vertical
-- stretch of member cells; run() returns its top and bottom rows, or nil
-- when (cx, cy) is not a member.  Members: solid cells (bar the detached);
-- objects hanging under a member; overhangs sitting on top of one.  Both
-- answers are memoised for the build.
--
-- `params.split(cx, top, bottom)`, when set, may cut a stretch in two (a
-- row of trees behind a hedge or a house is its own run): it returns the
-- last row of the upper part.
local function makeRuns(info, params)
  local memo, spans = {}, {}
  local maxRun = params.maxRun

  -- the listed drawing (data/buildings.lua) a cell belongs to, cap rows
  -- included, as a key; nil outside every listed drawing or with the
  -- profile off.  A run never crosses a drawing's edge: what stands behind a
  -- listed building (a wood, a cliff) is a structure of its own.
  local B = params.buildings
  local bmemo, drawn = params.profileMemo or {}, {}
  local function drawingAt(cx, cy)
    if not B then return nil end
    local k = cx .. "," .. cy
    local v = drawn[k]
    if v ~= nil then return v or nil end
    local e, ox, oy = B:at(info, cx, cy, bmemo)
    if not e then
      for d = 1, 2 do
        local e2, ox2, oy2 = B:at(info, cx, cy + d, bmemo)
        if e2 and cy >= oy2 - (e2.cap or 0) and cy < oy2 then e, ox, oy = e2, ox2, oy2 break end
      end
    end
    v = e and (e.id .. "@" .. ox .. "," .. oy) or false
    drawn[k] = v
    return v or nil
  end

  local member
  local function memberRaw(cx, cy, depth)
    local cell = info(cx, cy)
    -- the void past a map's edge (and a room's filler) is never part of a
    -- structure: a building or a forest ends at the edge, and the border
    -- tiles stand alone
    if cell.void or (params.outside and params.outside(cell)) then return false end
    -- a mountain piece with its own surface (Relief.lua) is not a structure
    if cell.relief then return false end
    local k = cell.kind
    if k == "solid" then return not detached(info, cx, cy) end
    if depth > maxRun then return false end
    if k == "object" then
      -- (outdoors, a sign standing one row out under a wider structure, as
      -- one between two houses, is its own thing too)
      if params.detachObjects and detached(info, cx, cy) then return false end
      -- hangs under a member above it
      local nk = info(cx, cy - 1).kind
      if nk == "solid" or nk == "object" then return member(cx, cy - 1, depth + 1) end
      return false
    end
    if k == "overhang" then
      -- sits on a member below it
      local sk = info(cx, cy + 1).kind
      if sk == "solid" or sk == "object" or sk == "overhang" then
        return member(cx, cy + 1, depth + 1)
      end
      return false
    end
    return false
  end
  member = function(cx, cy, depth)
    local row = memo[cy]
    if not row then
      row = {}
      memo[cy] = row
    end
    local v = row[cx]
    if v == nil then
      v = memberRaw(cx, cy, depth or 0)
      row[cx] = v
    end
    return v
  end

  -- A run longer than maxRun in either direction (a forest that goes on
  -- past the loaded maps) is open-ended that way: its top is -inf or its
  -- bottom +inf, so every cell deep inside answers the same thing no matter
  -- which cell asked first.  Only fully bounded runs are shared by all of
  -- their rows.
  local INF = math.huge
  local function run(cx, cy)
    local col = spans[cx]
    if not col then
      col = {}
      spans[cx] = col
    end
    local span = col[cy]
    if span ~= nil then
      if span == false then return nil end
      return span[1], span[2], span[3]
    end
    if not member(cx, cy) then
      col[cy] = false
      return nil
    end
    -- (an overhang under a blocked row is the top of the next structure
    -- down, the tops of the trees in front of a house: the run ends above
    -- it)
    local function apart(y)
      if info(cx, y + 1).kind == "overhang" and info(cx, y).kind ~= "overhang" then return true end
      return B ~= nil and drawingAt(cx, y) ~= drawingAt(cx, y + 1)
    end
    local top, bottom = cy, cy
    local openTop, openBottom = true, true
    for _ = 1, maxRun do
      if not member(cx, top - 1) or apart(top - 1) then openTop = false break end
      top = top - 1
    end
    for _ = 1, maxRun do
      if not member(cx, bottom + 1) or apart(bottom) then openBottom = false break end
      bottom = bottom + 1
    end
    -- the whole stretch is found from both ends, so every row of it agrees
    -- on where it splits
    if params.split and not openBottom then
      local y = params.split(cx, openTop and -INF or top, bottom)
      if y then
        if cy <= y then
          bottom, openBottom = y, false
        else
          top, openTop = y + 1, false
        end
      end
    end
    -- overhangs only ever sit on top, so they are the run's first rows
    local lover = 0
    if not openTop then
      while top + lover <= bottom and info(cx, top + lover).kind == "overhang" do
        lover = lover + 1
      end
    end
    span = { openTop and -INF or top, openBottom and INF or bottom, lover }
    if openTop or openBottom then
      col[cy] = span
    else
      for y = top, bottom do col[y] = span end
    end
    return span[1], span[2], span[3]
  end

  return member, run, drawingAt
end

-- ------- quad builders

-- how far wall strips overlap where they meet (world pixels)
local SEAM = 0.1

-- `shade` is the light on the quad's top edge, `low` on its bottom edge
-- (TL, TR take shade; BR, BL take low): upright faces darken toward the
-- ground and floors darken where a wall stands on their north edge, which is
-- all the ambient occlusion a diorama of cards needs.
--
-- `art`, on an under-layer quad, asks for the metatile with its ground
-- colours (those of metatile `key`) taken out: "cut" leaves them
-- transparent, "fill" paints them over with the art beside them, "trimN"
-- leaves only those joined to the open edges in mask N transparent
-- (Cutouts.lua).  Without it the quad shows the atlas as baked.
local function quad(emit, c, layer, kind, p, u0, v0, u1, v1, shade, low, art, key)
  emit({ pair = c.pair, layer = layer, mid = c.mid, kind = kind, p = p,
    u0 = u0, v0 = v0, u1 = u1, v1 = v1, shade = shade, low = low or shade,
    art = art, key = key })
end

-- flat, art top to the north
local function floorQuad(emit, c, layer, kind, cx, row, y, shade, north, art, key)
  local x0, x1 = cx * C, cx * C + C
  local z0, z1 = row * C, row * C + C
  -- north edge = TL, TR: the darkened edge when something stands there
  quad(emit, c, layer, kind, { x0, y, z0, x1, y, z0, x1, y, z1, x0, y, z1 },
    0, 0, C, C, north or shade, shade, art, key)
end

-- upright on the plane z, art rows v0..v1 spread over y0..y1
local function standQuad(emit, c, layer, kind, cx, z, y0, y1, v0, v1, shade, low, art, key)
  local x0, x1 = cx * C, cx * C + C
  quad(emit, c, layer, kind, { x0, y1, z, x1, y1, z, x1, y0, z, x0, y0, z },
    0, v0, C, v1, shade, low, art, key)
end

-- a side wall on the plane x, running z0 (north) .. z1 (south), coloured by
-- one texel column of the art (u0 == u1) or by the art laid along it
local function sideQuad(emit, c, kind, x, z0, z1, y0, y1, u0, v0, v1, shade, u1, low, art, key)
  -- a hair longer than asked, and down into the ground: side walls meet
  -- the walls of neighbouring strips in T-junctions, which leave pinholes
  -- when edges only touch.  The top edge stays exact: a roof meets it.
  local e = SEAM
  quad(emit, c, "u", kind, { x, y1, z0 - e, x, y1, z1 + e, x, y0 - e, z1 + e, x, y0 - e, z0 - e },
    u0, v0, u1 or u0, v1, shade, low, art, key)
end

local SHADE_TOP, SHADE_FRONT, SHADE_SIDE, SHADE_BANK = 1.0, 0.92, 0.72, 0.62
-- how much darker a face is where it meets the ground, and a floor where a
-- wall stands on its north edge, and the floor of a forest
local FOOT, SHADOW, UNDERGROWTH = 0.78, 0.72, 1.0

-- A forest is told from a building by its art: tree metatiles are partly the
-- grass they were painted on (a few percent to well under half), and the
-- 2x2 tree tiling repeats every two rows.  Facades are almost none of it,
-- or all of it where a roof lives entirely on the overhead layer.
local FOREST_MIN, FOREST_MAX = 0.04, 0.45
-- a ground metatile drawn in this many colours or fewer is plain
local PLAIN_COLOURS = 6

--- Emit every quad for the cells in [x0, x1) x [y0, y1).  `tick`, when
-- given, is called after every row, so a caller can slice a build across
-- frames (World runs it in a coroutine and yields there).
-- Move a quad up by h and south by h: seen at 45 degrees it does not move
-- (Relief.lua), so everything standing on raised ground keeps its pixels.
local function lifted(q, h)
  if q.poly then
    for _, v in ipairs(q.poly) do
      v[2], v[3] = v[2] + h, v[3] + h
    end
  elseif q.p then
    local p = q.p
    for i = 0, 3 do
      p[i * 3 + 2], p[i * 3 + 3] = p[i * 3 + 2] + h, p[i * 3 + 3] + h
    end
  end
  return q
end
Shape.lifted = lifted

function Shape.build(info, x0, y0, x1, y1, params, emit, tick)
  params = params or Shape.defaults
  local reliefSurface, reliefSteps
  -- every quad a cell emits stands on that cell's ground (Relief.lua)
  local rawEmit, lift = emit, 0
  emit = function(q)
    if lift ~= 0 then lifted(q, lift) end
    rawEmit(q)
  end
  local cap = params.cap or Shape.defaults.cap
  local maxRun = params.maxRun or Shape.defaults.maxRun
  local profileMemo = {}
  local runParams = { maxRun = maxRun, detachObjects = params.indoor ~= true,
    buildings = params.buildings, profileMemo = profileMemo }
  local member, run, drawingAt = makeRuns(info, runParams)
  local drop = params.waterDrop or Shape.defaults.waterDrop
  local tuft = params.tuft or Shape.defaults.tuft
  local ledge = params.ledge or Shape.defaults.ledge
  -- (cell, keyMid) -> share of the cell's art in the key's colours, or nil
  local keyFraction = params.keyFraction
  -- pair -> the cell a pair's ground usually is (its commonest floor)
  local groundOf = params.groundOf
  -- cell -> how many colours its under art uses (a plain ground uses few)
  local keyColours = params.keyColours
  -- a room: the void outside it stays dark, and furniture is low
  local indoor = params.indoor == true
  -- a room's back wall, in rows (indoors)
  local wallHeight = params.wallHeight
  -- an outdoor roof's slope (rise per pixel); rooms stay flat
  local pitch = indoor and 0 or (params.pitch or Shape.defaults.pitch)
  -- cell -> its under art's 256 colours (packed), or nil without pixels
  local pixels = params.pixels

  -- Indoors, a blocked metatile drawn in one flat colour is filler (the
  -- black between a gym's rooms): it is outside the room like the void.
  local function outside(c)
    if c.void then return true end
    if not indoor or not keyColours then return false end
    if c.kind ~= "solid" and c.kind ~= "object" then return false end
    return keyColours(c) == 1
  end
  runParams.outside = outside

  -- does the edge of a room's piece toward (nx, ny) face the floor (not
  -- the dark outside the room, nor the next piece pushed up against it)?
  -- Only those edges are trimmed (Cutouts "trimN").
  local function facesFloor(nx, ny)
    return not member(nx, ny) and not outside(info(nx, ny))
  end
  local function trimMask(cx, cy, north, east, south, west)
    return "trim" .. ((north and facesFloor(cx, cy - 1)) and 1 or 0)
      + ((east and facesFloor(cx + 1, cy)) and 2 or 0)
      + ((south and facesFloor(cx, cy + 1)) and 4 or 0)
      + ((west and facesFloor(cx - 1, cy)) and 8 or 0)
  end

  -- where a structure's vacated ground borrows its art from: plain ground
  -- north of the run, else south of it, else beside it, else its own art
  -- (a hole would show the sky)
  -- Returns the cell and the height to lay it at: water borrows water, at
  -- the water line, so a rock or a pier in the sea leaves sea behind it.
  -- is cell c drawn standing in the water w (a rock's foot in the sea:
  -- some of the water's colours and none of a tree's share of the usual
  -- ground's, unlike a tree at a pond's edge)?
  local function inWater(c, w)
    local f = keyFraction(c, w.mid)
    if not (f and f > 0.02) then return false end
    local k = groundOf and groundOf(c.pair)
    local g = k and k.pair == c.pair and keyFraction(c, k.mid)
    return not (g and g >= FOREST_MIN)
  end
  local function groundFor(cx, top, bottom, own)
    local probes = { { cx, top - 1 }, { cx, top - 2 }, { cx, bottom + 1 },
      { cx - 1, top }, { cx + 1, top }, { cx - 1, bottom }, { cx + 1, bottom } }
    local wet, dry
    for _, xy in ipairs(probes) do
      if xy[2] > -math.huge and xy[2] < math.huge then
        local c = info(xy[1], xy[2])
        if (c.kind == "floor" or c.kind == "overhang") and not dry then dry = c end
        if c.kind == "water" and not wet then wet = c end
      end
    end
    -- (a thing whose foot is drawn in the water round it stands in it: a
    -- rock in the sea under a fence, whatever lies past the fence)
    if wet and dry and bottom < math.huge and keyFraction then
      local b = info(cx, bottom)
      if wet.pair == b.pair and inWater(b, wet) then return wet, -drop end
    end
    if dry then return dry, 0 end
    if wet then return wet, -drop end
    return own, 0
  end

  -- the metatile whose colours are a structure's background: water for
  -- one standing in water, else its pair's usual ground, else the ground it
  -- borrows; only within one tileset pair.  The usual ground before the
  -- borrowed one: the nearest open cell is often a path or an edge piece
  -- whose colours include the art's own outlines.
  --
  -- In a room, a plain ground right around it (few colours: a rug) wins
  -- instead when more of the art is in its colours: a table stands on the
  -- rug, not on the floorboards.  `cx, top, bottom` place the run, whose
  -- floor neighbours are the candidates.
  local function keyFor(c, g, cx, top, bottom)
    local k = g and g.kind == "water" and g or (groundOf and groundOf(c.pair))
    if not k and g then k = g end
    if indoor and k and keyFraction and keyColours and k.kind ~= "water" and cx then
      local best, bestF = nil, (keyFraction(c, k.mid) or 1) + 0.05
      local function consider(n)
        if n.kind == "floor" and n.pair == c.pair and n.mid ~= c.mid and n.mid ~= k.mid then
          local colours = keyColours(n)
          local f = keyFraction(c, n.mid)
          if colours and colours <= PLAIN_COLOURS and f and f > bestF then best, bestF = n, f end
        end
      end
      if g then consider(g) end
      if top > -math.huge then consider(info(cx, top - 1)) end
      if bottom < math.huge then consider(info(cx, bottom + 1)) end
      for _, d in ipairs({ -1, 1 }) do
        if top > -math.huge then consider(info(cx + d, top)) end
        if bottom < math.huge then consider(info(cx + d, bottom)) end
      end
      if best then k = best end
    end
    if k and k.pair == c.pair and k.mid ~= c.mid then return k end
    return nil
  end

  -- A column is forest when its two lowest rows are both partly ground,
  -- and either the pattern repeats two rows up (a tree tiling) or the
  -- column beside it is partly ground in the same rows (trees are two
  -- cells wide; a building's edge column has facade beside it).
  -- (a canopy drawn on the overhead layer over plain ground, as Dewford's
  -- are, is judged as the field shows it when `shown`: only ever the upper
  -- row; a trunk row is drawn on the ground layer, and a roof's top row
  -- drawn overhead over grass under a wood's last trunks is no tree.  Only
  -- over plain ground -- the usual one, or a plain one of few colours, as
  -- Fortree's woods stand on the General grass -- a hedge drawn on both
  -- layers is no canopy)
  local shownFraction = params.shownFraction
  local function partGround(c, keyMid, shown)
    local f = keyFraction(c, keyMid)
    if shown and f and shownFraction and (c.over or 0) >= 0.5 and not c.walk
        and (f >= 0.98 or (f >= 0.5 and keyColours and (keyColours(c) or math.huge) <= PLAIN_COLOURS)) then
      -- (a canopy drawn whole on the overhead layer may leave only a few
      -- pixels of the grass under it showing: General's narrow trees)
      f = shownFraction(c, keyMid)
      return f ~= nil and f > 0 and f <= FOREST_MAX
    end
    return f ~= nil and f >= FOREST_MIN and f <= FOREST_MAX
  end
  local forestMemo = {}
  -- do rows probe - 1 and probe of column cx look like the bottom of a
  -- forest (see FOREST_MIN)?
  local function forestBottom(cx, probe, keyMid)
    local memoKey = cx .. ":" .. probe .. ":" .. keyMid
    local v = forestMemo[memoKey]
    if v ~= nil then return v end
    local a, b = info(cx, probe), info(cx, probe - 1)
    v = false
    if a.pair == b.pair and a.mid ~= b.mid and partGround(a, keyMid) and partGround(b, keyMid, true) then
      -- (a tiling of two rows: one tile down every row is a cliff's edge
      -- drawn in the ground's colours, as Sootopolis's, not trees)
      v = (info(cx, probe - 2).mid == a.mid or info(cx, probe - 3).mid == b.mid)
        and info(cx, probe - 2).mid ~= b.mid
      if not v then
        for _, d in ipairs({ -1, 1 }) do
          local na, nb = info(cx + d, probe), info(cx + d, probe - 1)
          if member(cx + d, probe) and member(cx + d, probe - 1) and na.pair == a.pair
              and partGround(na, keyMid) and partGround(nb, keyMid, true) then
            v = true
            break
          end
        end
      end
    end
    forestMemo[memoKey] = v
    return v
  end
  -- (always against the pair's usual ground: a path or rug beside the trees
  -- must not change what counts as a tree)
  -- a door somewhere along the front row a column's run stands on (the
  -- run of members with the same bottom row)
  local doorMemo = {}
  local function doorAlong(cx, bottom)
    local k = cx .. ":" .. bottom
    local v = doorMemo[k]
    if v ~= nil then return v end
    v = false
    for _, d in ipairs({ -1, 1 }) do
      local x = cx
      for _ = 1, 32 do
        if isDoor(info(x, bottom).beh) then v = true break end
        local _, nb = run(x + d, bottom)
        if not (member(x + d, bottom) and nb == bottom) then break end
        x = x + d
      end
      if v then break end
    end
    doorMemo[k] = v
    return v
  end
  -- Rocks in the sea, one after another down a column, stand as a wood
  -- does, against the water (Route 110's): the water in front of them, when
  -- the column is no wood against its usual ground.
  local function seaRocks(cx, bottom)
    if bottom == math.huge then return nil end
    local base = info(cx, bottom)
    local key = base.pair and groundOf(base.pair)
    if key and key.pair == base.pair and forestBottom(cx, bottom, key.mid) then return nil end
    local wet = info(cx, bottom + 1)
    if wet.kind == "water" and wet.pair == base.pair and forestBottom(cx, bottom, wet.mid) then
      return wet
    end
    return nil
  end
  local function isForest(cx, cy, top, bottom)
    if indoor or not (keyFraction and groundOf) then return false end
    local probe = bottom < math.huge and bottom or cy
    local base = info(cx, probe)
    local key = base.pair and groundOf(base.pair)
    if not (key and key.pair == base.pair) then return false end
    if not forestBottom(cx, probe, key.mid) and not seaRocks(cx, bottom) then return false end
    -- a building's edge with a little grass in it beside a wood is no tree
    -- (Petalburg's Mart): unless its own art repeats as trees do
    if bottom < math.huge and info(cx, probe - 2).mid ~= base.mid
        and info(cx, probe - 3).mid ~= info(cx, probe - 1).mid and doorAlong(cx, bottom) then
      return false
    end
    return true
  end

  -- trees standing behind a hedge or a building share its column of
  -- blocked cells; they are cut off as a forest of their own
  if indoor then
    -- A room's back wall is as many rows as the room's walls usually are;
    -- a counter or a shelf built against it below that is furniture of
    -- its own (the nurse's counter in front of the Pokémon Center wall).
    runParams.split = function(cx, top, bottom)
      if not wallHeight or top == -math.huge then return nil end
      if bottom - top + 1 <= wallHeight then return nil end
      if not outside(info(cx, top - 1)) then return nil end
      return top + wallHeight - 1
    end
  elseif keyFraction and groundOf then
    runParams.split = function(cx, top, bottom)
      local base = info(cx, bottom)
      -- a rock standing in the water (its foot drawn in it) under a
      -- structure that runs on past it on both sides (Route 110's under its
      -- fence) is a run of its own
      local s = info(cx, bottom + 1)
      if top > -math.huge and s.kind == "water" and s.pair == base.pair and inWater(base, s) then
        for y = top, bottom - 1 do
          local l, r = cx, cx
          while l > cx - 8 and member(l - 1, y + 1) do l = l - 1 end
          while r < cx + 8 and member(r + 1, y + 1) do r = r + 1 end
          if member(l - 1, y) and member(r + 1, y) then return y end
        end
      end
      local key = base.pair and groundOf(base.pair)
      if not (key and key.pair == base.pair) then return nil end
      local stop = math.max(top + 1, bottom - maxRun)
      -- (the row under the trees is more trees when it is partly ground, or
      -- a canopy drawn overhead over a trunk row)
      local function treeRow(y)
        local c = info(cx, y)
        if partGround(c, key.mid) then return true end
        return y < bottom and partGround(c, key.mid, true) and partGround(info(cx, y + 1), key.mid)
      end
      for y = bottom - 1, stop, -1 do
        local below = info(cx, y + 1)
        if below.kind ~= "overhang" and not treeRow(y + 1)
            and info(cx, y).kind ~= "overhang" and forestBottom(cx, y, key.mid) then
          return y
        end
      end
      return nil
    end
  end

  -- a blocked cell whose art is partly the ground: a tree's half
  local function treeLike(c)
    if not (keyFraction and groundOf and c.pair) then return false end
    if c.kind ~= "solid" and c.kind ~= "object" then return false end
    local k = groundOf(c.pair)
    return k ~= nil and k.pair == c.pair and k.mid ~= c.mid and partGround(c, k.mid)
  end

  -- In a forest every tree is two rows: its canopy over its trunk row,
  -- with the top of the canopy poking into the row behind on the overhead
  -- layer (the overhead of the trunk row behind it, or of an overhang row
  -- along the forest's north edge).  Counted from the run's bottom, trunk
  -- rows are even; a run with no bottom in reach goes by the overhead
  -- layer instead (a trunk row carries the next tree's top).
  local function trunkRow(c, cy, bottom)
    if bottom < math.huge then return (bottom - cy) % 2 == 0 end
    return (c.over or 0) > OVER_MIN
  end

  -- A vacated cell that borrows water lies at the water line; where the
  -- ground beside it does not, a short bank closes the step (north, east and
  -- west: the south edge faces away from the camera).
  local function sunken(nx, ny)
    local n = info(nx, ny)
    if n.relief then return false end
    if n.kind == "water" or n.kind == "blank" then return true end
    local nt, nb = run(nx, ny)
    if nt then
      -- forests and open-ended runs lie dry (rocks in the sea do not)
      if nb == math.huge then return false end
      if keyFraction and groundOf and nb - nt + 1 > cap and seaRocks(nx, nb) then return true end
      local ng, ngy = groundFor(nx, nt, nb, nil)
      if (ngy or 0) >= 0 then return false end
      -- (a wood in the sea is rocks, standing in it)
      return true
    end
    if n.kind == "object" or n.kind == "solid" then
      local _, ngy = groundFor(nx, ny, ny, nil)
      return (ngy or 0) < 0
    end
    return false
  end
  local function bankArt(nx, ny)
    local n = info(nx, ny)
    if n.kind == "floor" or n.kind == "ledge" or n.kind == "overhang" then return n end
    return (groundOf and groundOf(n.pair)) or n
  end
  local function laid(f, cx, cy, y, shade, north)
    floorQuad(emit, f, "u", "ground", cx, cy, y, shade, north)
    if y >= 0 then return end
    if not sunken(cx, cy - 1) then
      standQuad(emit, bankArt(cx, cy - 1), "u", "bank", cx, cy * C, y, 0, C + y, C, SHADE_BANK)
    end
    if not sunken(cx + 1, cy) then
      sideQuad(emit, bankArt(cx + 1, cy), "bank", cx * C + C, cy * C, cy * C + C, y, 0, 0.5, C + y, C, SHADE_BANK)
    end
    if not sunken(cx - 1, cy) then
      sideQuad(emit, bankArt(cx - 1, cy), "bank", cx * C, cy * C, cy * C + C, y, 0, C - 0.5, C + y, C, SHADE_BANK)
    end
  end

  -- What a run free-standing in a room is, by the behaviours on it and on
  -- the front cells beside it (a two-cell shelf may be tagged on one side):
  -- "tall", "counter" or "flat".
  local function furnitureOf(cx, top, bottom)
    local counter = false
    local function look(beh)
      if beh == nil then return nil end
      if TALL[beh] then return "tall" end
      if beh == "COUNTER" then counter = true end
      return nil
    end
    for y = top, bottom do
      if look(info(cx, y).beh) then return "tall" end
    end
    for _, d in ipairs({ -1, 1 }) do
      if member(cx + d, bottom) then
        local _, nb = run(cx + d, bottom)
        if nb == bottom and look(info(cx + d, bottom).beh) then return "tall" end
      end
    end
    return counter and "counter" or "flat"
  end

  -- A blocked cell no structure rule can place: a border tile in the void,
  -- or a cell of a run whose bottom is out of reach.  A tree's half stands
  -- as its own card (the overhead layer tells a trunk row from a canopy
  -- row); anything else lies flat, where the 2D field drew it.
  local function loose(c, cx, cy)
    local k = groundOf and groundOf(c.pair)
    if treeLike(c) then
      local f = (k and k.pair == c.pair) and k or c
      floorQuad(emit, f, "u", "ground", cx, cy, 0, UNDERGROWTH)
      local trunk = (c.over or 0) > OVER_MIN
      local zt, yb = (cy + 1) * C, 0
      if not trunk then zt, yb = (cy + 2) * C, C end
      standQuad(emit, c, "u", "forest", cx, zt, yb, yb + C, 0, C, SHADE_FRONT,
        yb == 0 and SHADE_FRONT * FOOT or SHADE_FRONT, "tree", k and k.mid)
      if (c.over or 0) > 0 then
        local oz, oy = zt, yb
        if trunk and treeLike(info(cx, cy + 1)) and treeLike(info(cx, cy + 2)) then
          oz, oy = (cy + 3) * C, 2 * C
        end
        standQuad(emit, c, "o", "forest", cx, oz + 0.04, oy, oy + C, 0, C, SHADE_FRONT,
          oy == 0 and SHADE_FRONT * FOOT or SHADE_FRONT)
      end
    else
      floorQuad(emit, c, "u", "flat", cx, cy, 0, SHADE_TOP)
      if (c.over or 0) > 0 then
        floorQuad(emit, c, "o", "flat", cx, cy, 0.04, SHADE_TOP)
      end
    end
  end

  -- something upright stands on the north edge of (cx, cy): a facade's
  -- bottom row, a lone card.  Not a room's furniture: it stands on legs
  -- or is trimmed to its own outline, and casts its own shadow.
  local function shadowed(cx, cy)
    local n = info(cx, cy - 1)
    if n.kind == "object" then return not indoor end
    local t, b = run(cx, cy - 1)
    if not (b == cy - 1 and b < math.huge) then return false end
    if indoor and t > -math.huge and not outside(info(cx, t - 1)) then
      return furnitureOf(cx, t, b) == "tall"
    end
    return true
  end
  local function floorShade(cx, cy)
    return shadowed(cx, cy) and SHADE_TOP * SHADOW or nil
  end

  -- ------- outdoor buildings: one solid per block (Hip.lua)
  --
  -- A block is the stretch of columns beside each other that carry the same
  -- run: the same art top, the same overhang rows, the same front.  Every
  -- cell of it works the block out the same way, so a block split across
  -- chunks comes out whole.
  local function sameRun(nx, cy, top, bottom, lover, drawing)
    if not member(nx, cy) then return false end
    if drawingAt(nx, cy) ~= drawing then return false end
    local nt, nb, nl = run(nx, cy)
    return nt == top and nb == bottom and nl == lover and not isForest(nx, cy, nt, nb)
  end
  -- Where a building's walls end and its roof begins, read off the front:
  -- the colours of the bottom rows are the walls' (plaster, posts, the door);
  -- going up, the first rows mostly in other colours (the fascia, the
  -- roof's tiles, or the ground under a roof drawn on the overhead layer)
  -- are the eaves.  nil without pixels.
  local EAVE_MIN, EAVE_MAX, WALL_ROWS = 12, 48, 10
  local function eaveOf(bx0, bx1, bottom, A)
    if not pixels then return nil end
    local W = bx1 - bx0 + 1
    local cells = {}
    for k = 0, 2 do
      for i = 0, W - 1 do
        local f = info(bx0 + i, bottom - k)
        local px = f.mid and pixels(f)
        if not px then return nil end
        cells[k * W + i] = px
      end
    end
    local function rowColours(r, fn)
      local k, py = math.floor(r / C), C - 1 - r % C
      for i = 0, W - 1 do
        local px = cells[k * W + i]
        for x = 0, C - 1 do fn(px[py * C + x]) end
      end
    end
    local counts, total = {}, 0
    for r = 0, WALL_ROWS - 1 do
      rowColours(r, function(col) counts[col] = (counts[col] or 0) + 1 total = total + 1 end)
    end
    local list = {}
    for col, n in pairs(counts) do list[#list + 1] = { col, n } end
    table.sort(list, function(a, c) return a[2] > c[2] or (a[2] == c[2] and a[1] < c[1]) end)
    local wall, acc = {}, 0
    for _, e in ipairs(list) do
      wall[e[1]] = true
      acc = acc + e[2]
      if acc >= total * 0.9 then break end
    end
    local function share(r)
      local n = 0
      rowColours(r, function(col) if wall[col] then n = n + 1 end end)
      return n / (W * C)
    end
    -- (four rows running, so a frame or a sign's edge across the front is
    -- not taken for the eaves; and the four over them mostly no wall
    -- again, so a shop's sign under its awning or the glass along the top
    -- of a row of windows is not either)
    local last = math.min(EAVE_MAX, A - 8, 3 * C - 4)
    for r = EAVE_MIN, last do
      local roof = true
      for d = 0, 3 do
        if share(r + d) >= 0.5 then roof = false break end
      end
      if roof then
        local sum, n = 0, 0
        for d = 4, 7 do
          if r + d <= 3 * C - 1 and r + d < A then
            sum, n = sum + share(r + d), n + 1
          end
        end
        if n < 2 or sum / n < 0.45 then return r end
      end
    end
    return nil
  end

  -- A two-storey house (Littleroot's) draws its upper storey's front as a
  -- band across its roof: rows of even colour, some of them the walls' own,
  -- with roof drawn under the band (down to the eaves) and over it.  The
  -- band as { vtop, vb (its rows, v), inset (how far in from the sides it
  -- starts) }, or nil.
  local composite = params.composite
  local function tierOf(bx0, bx1, bottom, vt, hw)
    if not composite then return nil end
    local W = bx1 - bx0 + 1
    if W * C < 48 then return nil end
    local cy0 = math.floor(vt / C)
    local cells = {}
    for k = 0, bottom - cy0 do
      for i = 0, W - 1 do
        local f = info(bx0 + i, cy0 + k)
        local px = f.mid and composite(f)
        if not px then return nil end
        cells[k * W + i] = px
      end
    end
    local function at(x, v)
      local k, i = math.floor(v / C) - cy0, math.floor(x / C)
      return cells[k * W + i][(v % C) * C + x % C]
    end
    local zf = (bottom + 1) * C
    -- the walls' colours, and the darkest of them (their outline)
    local counts, total = {}, 0
    for v = zf - WALL_ROWS, zf - 1 do
      for x = 0, W * C - 1 do
        local col = at(x, v)
        counts[col] = (counts[col] or 0) + 1
        total = total + 1
      end
    end
    local list = {}
    for col, n in pairs(counts) do list[#list + 1] = { col, n } end
    table.sort(list, function(a, c) return a[2] > c[2] or (a[2] == c[2] and a[1] < c[1]) end)
    local wall, acc, dark, darkL, nWall = {}, 0, nil, math.huge, 0
    local function lum(col)
      return math.floor(col / 65536) * 0.3 + math.floor(col / 256) % 256 * 0.59 + col % 256 * 0.11
    end
    for _, e in ipairs(list) do
      wall[e[1]] = true
      nWall = nWall + 1
      if lum(e[1]) < darkL then dark, darkL = e[1], lum(e[1]) end
      acc = acc + e[2]
      if acc >= total * 0.9 then break end
    end
    if nWall < 2 then dark = nil end
    -- each row's commonest colour across the middle, when it is nearly all
    local xa, xb = math.floor(W * C * 0.2), math.ceil(W * C * 0.8) - 1
    local function even(v)
      local cnt, best, bn = {}, nil, 0
      for x = xa, xb do
        local col = at(x, v)
        local n = (cnt[col] or 0) + 1
        cnt[col] = n
        if n > bn then best, bn = col, n end
      end
      return bn >= 0.9 * (xb - xa + 1) and best or nil
    end
    local eave = zf - hw
    local v = eave - 1
    local skirt = 0
    while v >= vt and not even(v) do
      skirt = skirt + 1
      v = v - 1
    end
    if skirt < 3 or v < vt then return nil end
    local vb, plaster = v + 1, 0
    local lightRow
    while v >= vt and even(v) do
      local col = even(v)
      if wall[col] and col ~= dark then
        plaster = plaster + 1
        lightRow = lightRow or v
      end
      v = v - 1
    end
    local vtop = v + 1
    local rows = vb - vtop
    if rows > 16 or plaster < 2 then return nil end
    -- roof over it: at least 6 rows, mostly not even
    if vtop - vt < 6 then return nil end
    local plain = 0
    for r = vt, vtop - 1 do if even(r) then plain = plain + 1 end end
    if plain * 2 > vtop - vt then return nil end
    -- how far in from the sides the band's colour reaches
    local col = even(lightRow)
    local mid = math.floor(W * C / 2)
    local l, r = mid, mid
    while l > 0 and at(l - 1, lightRow) == col do l = l - 1 end
    while r < W * C - 1 and at(r + 1, lightRow) == col do r = r + 1 end
    -- (a storey is a wall's height and set well in: a stripe across a
    -- Poké Mart's roof is neither)
    local inset = math.min(l, W * C - 1 - r)
    if rows < 7 or inset < 10 then return nil end
    return { vtop = vtop, vb = vb, inset = inset }
  end

  -- the building profile (data/buildings.lua, lib/Buildings.lua): a drawing
  -- a person has read, used instead of eaveOf and tierOf; nil when off
  local buildings = params.buildings

  local blockMemo = {}
  local function blockOf(cx, cy, top, bottom, lover, S)
    local bx0, bx1 = cx, cx
    for _ = 1, 32 do
      if not sameRun(bx0 - 1, cy, top, bottom, lover, drawingAt(cx, cy)) then break end
      bx0 = bx0 - 1
    end
    for _ = 1, 32 do
      if not sameRun(bx1 + 1, cy, top, bottom, lover, drawingAt(cx, cy)) then break end
      bx1 = bx1 + 1
    end
    -- a building has a door somewhere along its front (the whole front
    -- line, so the wings of an L-shaped house are buildings too); a cliff,
    -- a rock or a fence has none
    local building = false
    if pitch > 0 then
      local xa, xb = bx0, bx1
      for _ = 1, 32 do
        local _, nb = run(xa - 1, bottom)
        if not (member(xa - 1, bottom) and nb == bottom) then break end
        xa = xa - 1
      end
      for _ = 1, 32 do
        local _, nb = run(xb + 1, bottom)
        if not (member(xb + 1, bottom) and nb == bottom) then break end
        xb = xb + 1
      end
      for x = xa, xb do
        if isDoor(info(x, bottom).beh) then building = true break end
      end
      -- a drawing the profile lists is a building wherever its door is (the
      -- Gym's wings: the door is on the porch, a row further out)
      if not building and buildings and buildings:at(info, cx, bottom, profileMemo) then
        building = true
      end
      if building then
        -- A tree of the wood behind drawn over the roof's top row (Petalburg's
        -- Mart) takes that row's cells, and the columns under it start a row
        -- lower; their roof still starts where their neighbours' does.
        -- (a column of its own art: not a tree, and not mostly ground with
        -- its drawing on the overhead layer, as a narrow tree's canopy is)
        local function own(x, t)
          if isForest(x, bottom, t, bottom) then return false end
          if not (keyFraction and groundOf) then return true end
          local k = groundOf(info(x, bottom).pair)
          if not k then return true end
          local bare = 0
          for y = t, bottom do
            local f = keyFraction(info(x, y), k.mid)
            if f and f >= 0.9 then bare = bare + 1 end
          end
          return bare * 2 <= bottom - t + 1
        end
        local et = {}
        for x = xa, xb do et[x] = (run(x, bottom)) end
        local grew = true
        while grew do
          grew = false
          for x = xa, xb do
            local above = et[x] - 1
            if member(x, above) and (et[x - 1] == above or et[x + 1] == above)
                and own(x, et[x]) then
              local _, nb = run(x, above)
              if nb == above then
                et[x] = above
                grew = true
              end
            end
          end
        end
        top = et[cx] or top
        -- one block: the columns of one top along the front, whatever their
        -- overhang rows (a roof's top walkable over half its width and blocked
        -- over the rest is one roof); its overhang rows are the fewest any
        -- column has, so its footprint reaches back as far as any does
        bx0, bx1 = cx, cx
        while bx0 - 1 >= xa and et[bx0 - 1] == top do bx0 = bx0 - 1 end
        while bx1 + 1 <= xb and et[bx1 + 1] == top do bx1 = bx1 + 1 end
        lover = math.huge
        for x = bx0, bx1 do
          local t, _, l = run(x, bottom)
          lover = math.min(lover, t == top and l or 0)
        end
        -- one drawing, one solid: a drawing the profile lists stands as one
        -- block along its front (or its part's), whatever its columns' runs
        -- say (the flower shop's door column, its walkable corner)
        local s0, s1
        if buildings then s0, s1 = buildings:span(info, cx, bottom, profileMemo) end
        if s0 and (s0 < bx0 or s1 > bx1) then
          local whole = true
          for x = s0, s1 do
            local _, nb = run(x, bottom)
            if not (member(x, bottom) and nb == bottom) then whole = false break end
          end
          if whole then
            bx0, bx1, top = s0, s1, math.huge
            for x = bx0, bx1 do top = math.min(top, (run(x, bottom))) end
            lover = math.huge
            for x = bx0, bx1 do
              local t, _, l = run(x, bottom)
              lover = math.min(lover, t == top and l or 0)
            end
          end
        end
      end
    end
    local k = bx0 .. ":" .. bx1 .. ":" .. top .. ":" .. bottom
    local b = blockMemo[k]
    if b then return b end
    -- An overhang row is the building's own ridge when it stops where the
    -- building does; one running on past it is something else passing
    -- behind (a hedge's top), drawn as it was, not as roof.
    local foreign = false
    for y = top, top + lover - 1 do
      if info(bx0 - 1, y).kind == "overhang" or info(bx1 + 1, y).kind == "overhang" then
        foreign = true
      end
    end
    local vt = (building and foreign) and (top + lover) * C or top * C
    local hw = S * C
    local tier, spec
    if building then
      spec = buildings and buildings:block(info, bx0, bx1, bottom, (bottom + 1) * C, profileMemo)
      if spec then
        -- the drawing's own first row, and its cap rows are its own: no
        -- overhang row of it is something passing behind
        hw, tier, vt, foreign = spec.hw, spec.tier, spec.vt, false
      else
        hw = eaveOf(bx0, bx1, bottom, (bottom + 1) * C - vt) or hw
        tier = tierOf(bx0, bx1, bottom, vt, hw)
      end
    end
    b = Hip.block({ x0 = bx0 * C, x1 = (bx1 + 1) * C, zf = (spec and spec.zf) or (bottom + 1) * C,
      zb = (top + lover) * C, vt = vt, hw = hw, building = building, tier = tier,
      ridge = spec and spec.ridge, flatRoof = spec and spec.flat })
    b.profile = spec and spec.id
    b.foreign = building and foreign
    b.bx0, b.bx1, b.top = bx0, bx1, top
    blockMemo[k] = b
    return b
  end

  -- The plain stretch of a block's front its side walls are dressed with:
  -- the facade's commonest colours (its plaster) make up most of the front;
  -- the 8 px window, away from the corners, with the most of them.  Returns
  -- the column of cells, the first texel and the width.
  local function plainSpan(b, bottom, S)
    if b.plain then return b.plain[1], b.plain[2], b.plain[3] end
    local W = b.bx1 - b.bx0 + 1
    local w = 8
    local best = { b.bx0, 4, w }
    local rows, counts, ok = {}, {}, pixels ~= nil
    if ok then
      for k = 0, S - 1 do
        for i = 0, W - 1 do
          local f = info(b.bx0 + i, bottom - k)
          local px = f.mid and pixels(f)
          if not px then ok = false break end
          rows[k * W + i] = px
          for j = 0, 255 do counts[px[j]] = (counts[px[j]] or 0) + 1 end
        end
        if not ok then break end
      end
    end
    if ok then
      local list = {}
      for col, n in pairs(counts) do list[#list + 1] = { col, n } end
      table.sort(list, function(a, c) return a[2] > c[2] or (a[2] == c[2] and a[1] < c[1]) end)
      local total, plaster, acc = W * S * 256, {}, 0
      for _, e in ipairs(list) do
        plaster[e[1]] = true
        acc = acc + e[2]
        if acc >= total * 0.55 then break end
      end
      local score = {}
      for i = 0, W - 1 do
        for x = 0, 15 do
          local n = 0
          for k = 0, S - 1 do
            local px = rows[k * W + i]
            for y = 0, 15 do
              if plaster[px[y * 16 + x]] then n = n + 1 end
            end
          end
          score[i * 16 + x] = n
        end
      end
      local bestScore = -1
      for i = 0, W - 1 do
        for s0 = 0, 16 - w do
          local u = i * 16 + s0
          if u >= 3 and u + w <= W * 16 - 3 then
            local sum = 0
            for x = 0, w - 1 do sum = sum + score[u + x] end
            if sum > bestScore then
              bestScore = sum
              best = { b.bx0 + i, s0, w }
            end
          end
        end
      end
    end
    b.plain = best
    return best[1], best[2], best[3]
  end

  -- The cell whose art a hipped roof's face takes at drawing cell (cx, cy):
  -- its own ("roof" lays its overhead art over its ground and paints the
  -- ground over), unless it has no roof in it at all (nothing overhead,
  -- all ground: a corner of the drawing the roof does not reach), when it
  -- takes the nearest cell below in its column that does, above the walls.
  local function roofSource(c, cx, cy, b, bottom, keyMid)
    local function bare(d)
      if (d.over or 0) > OVER_MIN then return false end
      local f = keyFraction and keyMid and keyFraction(d, keyMid)
      return f ~= nil and f >= 0.98
    end
    if not bare(c) then return c end
    local last = bottom - math.ceil(b.hw / C - 1e-6)
    for y = cy + 1, last do
      local d = info(cx, y)
      if d.mid and not bare(d) then return d end
    end
    return c
  end

  -- light on an upright face, darker toward the ground
  local function wallShade(shade, y)
    local f = y / C
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return shade * (FOOT + (1 - FOOT) * f)
  end
  local ROOF_SHADE = { front = SHADE_TOP, back = SHADE_TOP * 0.9, west = SHADE_TOP * 0.97,
    east = SHADE_TOP * 0.82 }

  -- the block's faces nobody sees at 45 degrees, from its south-west cell:
  -- side walls dressed from the plain stretch, the back plane, the back wall
  local function blockBack(b, top, bottom, lover, S, keyMid)
    local colX, s0, w = plainSpan(b, bottom, S)
    local bands = math.max(1, math.ceil(b.hw / C - 1e-6))
    for _, x in ipairs({ b.x0, b.x1 }) do
      for k = 0, bands - 1 do
        local f = info(colX, bottom - math.min(k, S - 1))
        local ylo, yhi = k == 0 and -drop or k * C, math.min((k + 1) * C, b.hw)
        local zb = b.zf
        while zb > b.zlo + 1e-6 do
          local za = math.max(b.zlo, zb - w)
          -- (the front strip reaches a hair past the facade, and every strip
          -- a hair below the ground, so no pinhole opens at the corner)
          local zf = zb == b.zf and zb + SEAM or zb
          local rect = { { za, ylo - SEAM }, { zf, ylo - SEAM }, { zf, yhi }, { za, yhi } }
          if b.kind == "flat" then
            -- under the back plane
            rect = Hip.clip(rect, function(p) return p[2] - (p[1] - b.vt) end)
          end
          if #rect >= 3 then
            local poly = {}
            for i, p in ipairs(rect) do
              local z, y = p[1], p[2]
              local t = C - (y - k * C)
              if t > C - 0.5 then t = C - 0.5 end
              poly[i] = { x, y, z, s0 + (zb - z), t, wallShade(SHADE_SIDE, y) }
            end
            emit({ pair = f.pair, layer = "u", mid = f.mid, kind = "side", poly = poly,
              art = "fill", key = keyMid })
          end
          zb = za
        end
      end
    end
    -- the upper storey's sides: the band's own rows at each height, from the
    -- middle of the front, along the wall
    local u = b.upper
    if u then
      local midX = math.floor((b.bx0 + b.bx1) / 2)
      local vtop, vbot = u.zf - u.y1, u.zf - u.y0
      for _, x in ipairs({ u.x0, u.x1 }) do
        for k = math.floor(vtop / C), math.ceil(vbot / C) - 1 do
          local va, vb = math.max(vtop, k * C), math.min(vbot, (k + 1) * C)
          if vb > va + 1e-6 then
            local f = info(midX, k)
            local zb = u.zf
            while zb > u.zb + 1e-6 do
              local za = math.max(u.zb, zb - 8)
              local yhi, ylo = u.zf - va, u.zf - vb
              local tlo, thi = vb - k * C, va - k * C
              if tlo > C - 0.5 then tlo = C - 0.5 end
              emit({ pair = f.pair, layer = "u", mid = f.mid, kind = "side", poly = {
                { x, yhi, za, 4, thi, SHADE_SIDE }, { x, yhi, zb, 4 + (zb - za), thi, SHADE_SIDE },
                { x, ylo, zb, 4 + (zb - za), tlo, SHADE_SIDE }, { x, ylo, za, 4, tlo, SHADE_SIDE } },
                art = "roof", key = keyMid })
              zb = za
            end
          end
        end
      end
    end
    -- behind the ridge, and the back wall under it: never seen from the
    -- game's cameras, there for the sun's shadow and to close the solid
    local r = info(b.bx0, top + lover)
    local back = Hip.back(b)
    if back then
      local poly = {}
      for i, p in ipairs(back) do poly[i] = { p[1], p[2], p[3], 8, 8, SHADE_SIDE } end
      emit({ pair = r.pair, layer = "u", mid = r.mid, kind = "back", poly = poly, art = "fill", key = keyMid })
    end
    local h = Hip.backWall(b)
    if h then
      local f = info(colX, bottom)
      emit({ pair = f.pair, layer = "u", mid = f.mid, kind = "back", poly = {
        { b.x0, h, b.zlo, s0, C - h, SHADE_SIDE }, { b.x1, h, b.zlo, s0 + w, C - h, SHADE_SIDE },
        { b.x1, 0, b.zlo, s0 + w, C - 0.5, SHADE_SIDE * FOOT }, { b.x0, 0, b.zlo, s0, C - 0.5, SHADE_SIDE * FOOT } },
        art = "fill", key = keyMid })
    end
  end

  -- ------- the relief (Relief.lua)
  --
  -- A cell's corners lift it; a corner at height h stands h south of its
  -- place on the map, so the 45 degree view never moves.
  local function corner(x, z, h) return x, h, z + h end
  local function heightsOf(c)
    return c.rNW or 0, c.rNE or 0, c.rSE or 0, c.rSW or 0
  end
  -- light on a mountain surface, by which way it faces
  local function slopeShade(nw, ne, se, sw)
    local dx = ((ne + se) - (nw + sw)) / 2   -- rise eastward over the cell
    local dz = ((sw + se) - (nw + ne)) / 2   -- rise southward
    if dz < -0.5 * C then return SHADE_FRONT end      -- a face
    if dx > 0.5 * C then return SHADE_TOP * 0.96 end  -- falls west: in the sun
    if dx < -0.5 * C then return SHADE_TOP * 0.8 end  -- falls east
    if dz > 0.5 * C then return SHADE_SIDE end        -- a back
    return SHADE_TOP
  end
  function reliefSurface(c, cx, cy)
    local nw, ne, se, sw = heightsOf(c)
    local x0, x1, z0, z1 = cx * C, cx * C + C, cy * C, cy * C + C
    local P = {
      { x0, nw, z0 + nw, 0, 0 }, { x1, ne, z0 + ne, C, 0 },
      { x1, se, z1 + se, C, C }, { x0, sw, z1 + sw, 0, C },
    }
    local shade = slopeShade(nw, ne, se, sw)
    for _, v in ipairs(P) do v[6] = shade end
    -- a plane, or two meeting on the diagonal whose ends agree best
    local planar = math.abs((nw + se) - (ne + sw)) < 1e-6
    local tris
    if planar then
      tris = { { P[1], P[2], P[3], P[4] } }
    elseif math.abs(nw - se) <= math.abs(ne - sw) then
      tris = { { P[1], P[2], P[3] }, { P[1], P[3], P[4] } }
    else
      tris = { { P[1], P[2], P[4] }, { P[2], P[3], P[4] } }
    end
    for _, t in ipairs(tris) do
      local poly = {}
      for i, v in ipairs(t) do poly[i] = { v[1], v[2], v[3], v[4], v[5], v[6] } end
      emit({ pair = c.pair, layer = "u", mid = c.mid, kind = "relief", poly = poly })
      if (c.over or 0) > 0 then
        local op = {}
        for i, v in ipairs(t) do op[i] = { v[1], v[2] + 0.05, v[3] + 0.05, v[4], v[5], v[6] } end
        emit({ pair = c.pair, layer = "o", mid = c.mid, kind = "relief", poly = op })
      end
    end
  end

  -- A step between two cells along their shared edge: from this cell's
  -- edge (a, b: heights at its two ends) to the neighbour's (a2, b2), each
  -- end placed by `at(t, h)` (t 0..1 along the edge).  A side whose surface
  -- lies under its corners (water, by `d1` or `d2`) is met there: the drop
  -- is straight down, not slid south.  Dressed with the higher cell's art.
  local function step(hi, at, a, b, a2, b2, d1, d2)
    d1, d2 = d1 or 0, d2 or 0
    -- a tree or a house is dressed with the ground it stands on
    local dress = hi
    if not hi.relief and hi.kind ~= "floor" and hi.kind ~= "ledge" and hi.kind ~= "water"
        and hi.kind ~= "overhang" then
      dress = (groundOf and hi.pair and groundOf(hi.pair)) or hi
    end
    local function piece(pts)
      local poly, top = {}, -math.huge
      for _, p in ipairs(pts) do top = math.max(top, p[2] - p[3]) end
      for i, p in ipairs(pts) do
        local x, y, z = at(p[1], p[2])
        y = y - p[3]
        local t = math.min(top - y, C - 0.5)
        poly[i] = { x, y, z, C * p[1], t, SHADE_SIDE }
      end
      emit({ pair = dress.pair, layer = "u", mid = dress.mid, kind = "step", poly = poly, art = "fill",
        key = nil })
    end
    local da, db = (a - d1) - (a2 - d2), (b - d1) - (b2 - d2)
    if math.abs(da) < 1e-6 and math.abs(db) < 1e-6 then return end
    if da * db < 0 then
      -- the two cross along the edge: two triangles
      local t = da / (da - db)
      local hm = a + (b - a) * t
      piece({ { 0, a, d1 }, { t, hm, d1 }, { 0, a2, d2 } })
      piece({ { t, hm, d1 }, { 1, b, d1 }, { 1, b2, d2 } })
    else
      piece({ { 0, a, d1 }, { 1, b, d1 }, { 1, b2, d2 }, { 0, a2, d2 } })
    end
  end
  -- Water lies `drop` under its corners.  Where flat land meets water on
  -- one level the bank below closes the edge (as without relief); anywhere
  -- else the step runs down to the water line itself.
  local function wet(n) return n.kind == "water" and not n.relief end
  local function edgeStep(c, n, at, a, b, a2, b2)
    local plain = math.abs(a - a2) < 1e-6 and math.abs(b - b2) < 1e-6
    local d1, d2 = 0, 0
    local cw, nw_ = wet(c), wet(n)
    if cw and nw_ then
      d1, d2 = drop, drop
    elseif cw ~= nw_ then
      local land = cw and n or c
      if not (plain and not land.relief) then
        if cw then d1 = drop else d2 = drop end
      end
    end
    local hi = math.max(a - d1, b - d1) >= math.max(a2 - d2, b2 - d2) and c or n
    step(hi, at, a, b, a2, b2, d1, d2)
  end
  function reliefSteps(c, cx, cy)
    if c.kind == "blank" then return end
    local nw, ne, se, sw = heightsOf(c)
    local e = info(cx + 1, cy)
    if e.kind ~= "blank" then
      local enw, ene, ese, esw = heightsOf(e)
      local X = cx * C + C
      edgeStep(c, e, function(t, h) return corner(X, cy * C + C * t, h) end, ne, se, enw, esw)
    end
    local s = info(cx, cy + 1)
    if s.kind ~= "blank" then
      local snw, sne, sse, ssw = heightsOf(s)
      local Z = cy * C + C
      edgeStep(c, s, function(t, h) return corner(cx * C + C * t, Z, h) end, sw, se, snw, sne)
    end
  end
  -- do this cell and its neighbour meet on one level along their edge?
  local function flush(c, n, side)
    local nw, ne, se, sw = heightsOf(c)
    local mw, me, ms, mx = heightsOf(n)
    local a, b, a2, b2
    if side == "s" then a, b, a2, b2 = sw, se, mw, me
    elseif side == "e" then a, b, a2, b2 = ne, se, mw, mx
    else a, b, a2, b2 = nw, sw, me, ms end
    return math.abs(a - a2) < 1e-6 and math.abs(b - b2) < 1e-6
  end

  for cy = y0, y1 - 1 do
    for cx = x0, x1 - 1 do
      local c = info(cx, cy)
      local kind = c.kind
      local top, bottom, lover = run(cx, cy)
      -- does this cell show dry ground at 0 that may meet water?
      local bankable = not top
      lift = c.relief and 0 or (c.rNW or 0)

      if c.relief then
        -- a mountain piece: its own art on the surface its corners make
        reliefSurface(c, cx, cy)
        bankable = false

      elseif indoor and outside(c) then
        -- outside a room: nothing, the dark shows (as on the GBA)
        bankable = false

      elseif c.void and (kind == "solid" or kind == "object") then
        -- a border tile past the map's edge
        loose(c, cx, cy)
        bankable = true

      elseif top then
        local len = bottom - top + 1
        local S = math.min(len, cap)
        -- In a room, what stands free of the back wall is furniture.  What
        -- the game tags as a shelf, a set or a machine keeps its full height
        -- (see TALL); anything else is low: its front row stands and the
        -- rest is its top (a bed, a table, a counter).
        local furniture = indoor and top > -math.huge and not outside(info(cx, top - 1))
          and furnitureOf(cx, top, bottom) or nil
        if furniture and furniture ~= "tall" and len >= 2 then S = 1 end
        local k = bottom - cy
        local zf = (bottom + 1) * C
        -- only the overhangs on top keep their ground and lose their
        -- under art; one caught between two structures (the canopy of the
        -- tree in front, under the trunk of the one behind) is just more
        -- structure
        local isOver = kind == "overhang" and cy < top + lover
        local g, gy = groundFor(cx, top, bottom, nil)
        local key = keyFor(c, g, cx, top, bottom)
        local keyMid = key and key.mid
        -- a card (short enough to stand whole), a forest (a card per tree),
        -- a box (facade, roof and sides), or, for a run whose bottom is out
        -- of reach (the void past a map's edge), a card per cell: a box
        -- needs its bottom row, and each cell of such a run decides alone
        local mode = len <= S and "card"
          or (isForest(cx, cy, top, bottom) and "forest")
          or (bottom == math.huge and "loose") or "box"
        if mode == "forest" and not indoor and keyFraction and groundOf then
          local sea = seaRocks(cx, bottom)
          if sea then g, gy, key, keyMid = sea, -drop, sea, sea.mid end
        end
        -- the foot of a tree of the wood behind, drawn over a building's top
        -- row: the building's roof takes that cell (blockOf)
        if (mode == "forest" or mode == "card") and not indoor and cy == bottom and member(cx, cy + 1) then
          local t, bt, l = run(cx, cy + 1)
          if t == cy + 1 and bt < math.huge and not isForest(cx, cy + 1, t, bt) then
            local hb = blockOf(cx, cy + 1, t, bt, l, math.min(bt - t + 1, cap))
            if hb.kind == "hip" and hb.top and hb.top <= cy then mode = "under" end
          end
        end


        if mode == "under" then
          -- (drawn by the roof)
          bankable = false

        elseif mode == "forest" then
          -- each tree is one card on the front edge of its trunk row:
          -- trunk 0..16, canopy 16..32, the canopy's top 32..48, each cut
          -- out against the grass it was painted on
          -- (trees stand on dry ground: a forest beside a pond does not
          -- borrow the pond)
          if isOver then
            floorQuad(emit, c, "u", "ground", cx, cy, 0, SHADE_TOP)
          elseif g and g.kind == "water" and gy < 0 and keyMid == g.mid then
            -- rocks in the sea: the sea under them
            laid(g, cx, cy, gy, SHADE_TOP)
          else
            -- (the wood's own ground: the trees are cut out against it, and
            -- the cell beside the wood may be a shore)
            local usual = groundOf and groundOf(c.pair)
            local f = (usual and usual.pair == c.pair and usual) or (g and gy >= 0 and g)
              or (key and key.kind ~= "water" and key) or c
            floorQuad(emit, f, "u", "ground", cx, cy, 0, UNDERGROWTH)
          end
          local inSea = not isOver and g and g.kind == "water" and gy < 0 and keyMid == g.mid
          bankable = not inSea
          local trunk = not isOver and trunkRow(c, cy, bottom)
          if not isOver then
            local zt, yb = (cy + 1) * C, 0
            if not trunk then zt, yb = (cy + 2) * C, C end
            local low = yb == 0 and SHADE_FRONT * FOOT or SHADE_FRONT
            -- (a rock's foot reaches down to the water line)
            local foot = (inSea and yb == 0) and -drop or yb
            standQuad(emit, c, "u", "forest", cx, zt, foot, yb + C, 0, C, SHADE_FRONT, low, "tree", keyMid)
          end
          if (c.over or 0) > 0 then
            -- the top of the tree whose canopy is the next row south, when
            -- there is one; otherwise the art stays where it was painted
            local zt, yb = (cy + 1) * C, 0
            if (isOver or trunk) and (member(cx, cy + 1) or treeLike(info(cx, cy + 1)))
                and (member(cx, cy + 2) or treeLike(info(cx, cy + 2))) then
              zt, yb = (cy + 3) * C, 2 * C
            elseif not trunk and not isOver then
              zt, yb = (cy + 2) * C, C
            end
            standQuad(emit, c, "o", "forest", cx, zt + 0.04, yb, yb + C, 0, C, SHADE_FRONT,
              yb == 0 and SHADE_FRONT * FOOT or SHADE_FRONT)
          end
        elseif mode == "flat" then
          floorQuad(emit, c, "u", "flat", cx, cy, 0, SHADE_TOP)
          if (c.over or 0) > 0 then
            floorQuad(emit, c, "o", "flat", cx, cy, 0.04, SHADE_TOP)
          end
          bankable = true

        elseif mode == "loose" then
          bankable = true
          if isOver then
            floorQuad(emit, c, "u", "ground", cx, cy, 0, SHADE_TOP)
            standQuad(emit, c, "o", "hang", cx, (cy + 1) * C, C, 2 * C, 0, C, SHADE_FRONT)
          else
            loose(c, cx, cy)
          end

        elseif mode == "box" and not indoor and top > -math.huge then
          -- an outdoor building: walls round its footprint and a hipped
          -- roof, every face the 45 degree camera sees taking the drawing
          -- projected onto it (Hip.lua)
          local b = blockOf(cx, cy, top, bottom, lover, S)
          if b.kind == "hip" and b.foreign and cy < top + lover then
            -- what passes behind the building: its ground, and its overhead
            -- art standing on the cell's front edge, against the back wall
            laid(c, cx, cy, 0, SHADE_TOP)
            if (c.over or 0) > 0 then
              standQuad(emit, c, "o", "hang", cx, (cy + 1) * C, 0, C, 0, C, SHADE_FRONT,
                SHADE_FRONT * FOOT)
            end
          elseif cy < top + lover then
            -- an overhang row: its ground stays where you walk
            local f = isOver and c or (g or key or c)
            local y = (not isOver and f == g) and gy or 0
            laid(f, cx, cy, y, SHADE_TOP)
            bankable = y >= 0
          elseif b.open and cy * C < b.zb - 0.5 then
            -- the collision behind a solid standing short of it: open ground
            local f = g or key or c
            local y = (f == g) and gy or 0
            laid(f, cx, cy, y, SHADE_TOP)
            bankable = y >= 0
          end
          local function pieces(c, cx, cy, borrowed)
            -- (every cell the drawing reaches into: a profile's drawing may
            -- start a few rows down its top cell, the Gym's under a row of grass)
            for _, pc in ipairs((cy + 1) * C > b.vt + 1e-6 and Hip.pieces(b, cx, cy, C, cy == bottom and drop or nil) or {}) do
              local wall = pc.face == "wall" or pc.face == "foot"
              local upper = pc.face == "upper"
              local poly = {}
              for i, v in ipairs(pc.poly) do
                poly[i] = { v[1], v[2], v[3], v[4], v[5],
                  wall and wallShade(SHADE_FRONT, v[2]) or upper and SHADE_FRONT or ROOF_SHADE[pc.face] }
              end
              local qkind = (wall or upper) and "facade" or "roof"
              -- the overhead art on the same face, a hair toward the camera
              -- (along the 45 degree ray, so it stays on its pixels); copied
              -- before the face goes out (emitting lifts it in place)
              local op
              if (c.over or 0) > 0 and pc.face ~= "foot" and not (b.kind == "hip" and not wall) then
                op = {}
                for i, v in ipairs(poly) do op[i] = { v[1], v[2] + 0.05, v[3] + 0.05, v[4], v[5], v[6] } end
              end
              if b.kind == "hip" and not wall then
                -- a hipped roof's face: both layers in one opaque copy
                -- (a row borrowed from the tree drawn over it takes the art of
                -- the nearest column along the roof's row that is its own: the
                -- tree's leaves stand with the tree, not on the roof)
                local r = borrowed and borrowed(cy) or roofSource(c, cx, cy, b, bottom, keyMid)
                local how = r.kind == "overhang" and "roofo" or "roof"
                emit({ pair = r.pair, layer = "u", mid = r.mid, kind = qkind, face = pc.face,
                  mirror = pc.mirror, poly = poly, art = how, key = keyMid, cx = cx, cy = cy })
              else
                -- (an overhang row's ground goes up with its overhead art: the
                -- top is closed, and at 45 degrees it is the drawing)
                emit({ pair = c.pair, layer = "u", mid = c.mid, kind = qkind, face = pc.face,
                  mirror = pc.mirror, poly = poly, art = "fill", key = keyMid, cx = cx, cy = cy })
              end
              if op then
                emit({ pair = c.pair, layer = "o", mid = c.mid, kind = qkind, face = pc.face,
                  mirror = pc.mirror, poly = op, cx = cx, cy = cy })
              end
            end
          end
          pieces(c, cx, cy)
          -- a front wall standing out in the walkable row under the
          -- collision (the profile's foot: the Gym's wings): its lowest rows
          -- are that row's art
          if cy == bottom and b.zf > (bottom + 1) * C + 1e-6 then
            pieces(info(cx, bottom + 1), cx, bottom + 1)
          end
          -- the roof's top row over a column whose own top a tree of the wood
          -- behind took (b.top above its run's): drawn from here
          if cy == top and b.top and b.top < top then
            local function own(y)
              for d = 1, b.bx1 - b.bx0 do
                for _, nx in ipairs({ cx - d, cx + d }) do
                  if nx >= b.bx0 and nx <= b.bx1 and (run(nx, bottom)) <= y then return info(nx, y) end
                end
              end
              return info(cx, y)
            end
            for y = b.top, top - 1 do pieces(info(cx, y), cx, y, own) end
          end
          if cx == b.bx0 and cy == bottom then blockBack(b, top, bottom, lover, S, keyMid) end
        else
          local H = S * C
          local x0, x1 = cx * C, cx * C + C
          -- Every pixel of art v (counted down the map) lifted by h and
          -- moved h south is seen by the 45 degree camera exactly where
          -- the 2D field drew it, whatever h is.  So the roof can rise
          -- towards the ridge (by `pitch` per pixel of roof art) without
          -- changing that view, and outdoors the box can reach back over
          -- its whole collision footprint: behind the ridge a back slope
          -- falls at exactly 45 degrees to the ground at the footprint's
          -- back edge, edge-on to the 45 degree camera and facing away from
          -- the lower ones.  The art is never repeated or stretched; the
          -- depth shows in the sides, in the shadow and in what the
          -- building hides.  In a room the roof stays flat and shallow.
          local deep = mode == "box" and not indoor
          local p = deep and pitch or 0
          local vE = (bottom - S + 1) * C
          local function roofH(v) return H + p * (vE - v) end
          local function roofZ(v) return v + roofH(v) end
          local vTop = (top + lover) * C
          local zBack = vTop
          local zRidge, hRidge = roofZ(vTop), roofH(vTop)

          -- the ground this cell leaves behind when its art stands up
          if isOver then
            floorQuad(emit, c, "u", "ground", cx, cy, 0, SHADE_TOP)
            bankable = true
          elseif cy < top + lover + S or furniture then
            -- every row north of the box proper: the box is the solid
            -- roof's footprint, and an overhang's lid lies just behind it
            -- (a deep box covers these rows with its back slope; the
            -- ground under it still fills the seam where the ridge and the
            -- ground behind meet on the 45 degree camera's screen).
            -- Furniture is open-sided, so the floor runs under all of it:
            -- the ground it was cut out against, which shows between a
            -- table's legs
            local f = g or key or c
            if furniture and key and key.kind == "floor" then f = key end
            local y = f == g and gy or 0
            laid(f, cx, cy, y, SHADE_TOP)
            bankable = y >= 0
          end

          -- does the neighbouring column carry the very same box here?
          -- (the same span, and not standing as a forest's trees)
          local function sameBox(nx)
            if not member(nx, cy) then return false end
            local nt, nb, nl = run(nx, cy)
            if not (nt + nl == top + lover and nb == bottom) then return false end
            return not isForest(nx, cy, nt, nb)
          end

          -- a card is cut out (nothing behind it); a box's faces are kept
          -- solid, their stray ground painted over with the art beside it.
          -- Outdoors a card is mostly a tree, whose shadow goes too; in a
          -- room a short wall (nothing walkable behind it) stays solid.
          -- A room's free-standing pieces are trimmed: the floor around
          -- them goes (a glass table on a rug shows the rug), but floor
          -- colours their outline encloses stay (a crate's grey sides).
          local lowPiece = furniture ~= nil and furniture ~= "tall"
          local westOpen, eastOpen = not sameBox(cx - 1), not sameBox(cx + 1)
          local function trimmed(y, north, south)
            return trimMask(cx, y, north, eastOpen, south, westOpen)
          end
          local art = "fill"
          local roofArt = "fill"
          if mode == "card" then
            if not indoor then
              art = "tree"
            elseif top > -math.huge and not outside(info(cx, top - 1)) then
              art = trimmed(cy, cy == top, cy == bottom)
            end
          elseif lowPiece then
            art = trimmed(bottom, false, true)
            roofArt = trimmed(cy, cy == top, false)
          end

          if k < S then
            local yb, yt = k * C, k * C + C
            -- the bottom row reaches down to the water line: hidden under
            -- the ground on land, and no gap where it stands in water
            if k == 0 then yb = -drop end
            local low = k == 0 and SHADE_FRONT * FOOT or SHADE_FRONT
            if not isOver then
              standQuad(emit, c, "u", "facade", cx, zf, yb, yt, 0, C, SHADE_FRONT, low, art, keyMid)
            end
            if (c.over or 0) > 0 then
              standQuad(emit, c, "o", "facade", cx, zf + 0.04, yb, yt, 0, C, SHADE_FRONT, low)
            end
          else
            -- the roof, slid forward to meet the facade's top edge and
            -- rising towards the ridge
            local vT, vB = cy * C, cy * C + C
            local hT, hB = roofH(vT), roofH(vB)
            local zT, zB = roofZ(vT), roofZ(vB)
            if not isOver then
              quad(emit, c, "u", "roof", { x0, hT, zT, x1, hT, zT, x1, hB, zB, x0, hB, zB },
                0, 0, C, C, SHADE_TOP, SHADE_TOP, roofArt, keyMid)
            end
            if (c.over or 0) > 0 then
              quad(emit, c, "o", "roof", { x0, hT + 0.04, zT, x1, hT + 0.04, zT, x1, hB + 0.04, zB,
                x0, hB + 0.04, zB }, 0, 0, C, C, SHADE_TOP, SHADE_TOP)
            end
            if not isOver then
              -- the box's side under this strip of roof: the facade's own
              -- edge colours at each height, run back along the wall, and
              -- above the eaves a gable up to the roof line (a low piece's
              -- side is trimmed as its front is: a table's shows its legs)
              local west, east = westOpen, eastOpen
              local sideArt = lowPiece and art or "fill"
              local gw = bottom < math.huge and info(cx, bottom - S + 1) or c
              if gw.kind == "overhang" then gw = c end
              for j = 0, S - 1 do
                local f = bottom < math.huge and info(cx, bottom - j) or c
                if f.kind == "overhang" then f = c end
                local yb, yt = j == 0 and -drop or j * C, (j + 1) * C
                local low = j == 0 and SHADE_SIDE * FOOT or SHADE_SIDE
                if west then
                  sideQuad(emit, f, "side", x0, zT, zB, yb, yt, 0.5, 0, C, SHADE_SIDE, 0.5, low, sideArt, keyMid)
                end
                if east then
                  sideQuad(emit, f, "side", x1, zT, zB, yb, yt, C - 0.5, 0, C, SHADE_SIDE, C - 0.5, low, sideArt, keyMid)
                end
              end
              if p > 0 then
                -- (the top edge on the roof line exactly; the rest overlaps)
                if west then
                  quad(emit, gw, "u", "side", { x0, hT, zT, x0, hB, zB, x0, H - SEAM, zB + SEAM,
                    x0, H - SEAM, zT - SEAM }, 0.5, 0.5, 0.5, 1.5, SHADE_SIDE, SHADE_SIDE, "fill", keyMid)
                end
                if east then
                  quad(emit, gw, "u", "side", { x1, hT, zT, x1, hB, zB, x1, H - SEAM, zB + SEAM,
                    x1, H - SEAM, zT - SEAM }, C - 0.5, 0.5, C - 0.5, 1.5, SHADE_SIDE, SHADE_SIDE, "fill", keyMid)
                end
              end
              if deep and cy == top + lover and zRidge > zBack + 0.01 then
                -- behind the ridge: the back slope to the footprint's back
                -- edge, and the sides under it
                quad(emit, c, "u", "back", { x1, hRidge, zRidge, x0, hRidge, zRidge, x0, 0, zBack, x1, 0, zBack },
                  0, 0, C, 1, SHADE_SIDE, SHADE_SIDE * FOOT, "fill", keyMid)
                if west then
                  quad(emit, gw, "u", "side", { x0, hRidge, zRidge, x0, -drop, zRidge + SEAM, x0, -drop, zBack,
                    x0, 0, zBack }, 0.5, 0.5, 0.5, 1.5, SHADE_SIDE, SHADE_SIDE * FOOT, "fill", keyMid)
                end
                if east then
                  quad(emit, gw, "u", "side", { x1, hRidge, zRidge, x1, -drop, zRidge + SEAM, x1, -drop, zBack,
                    x1, 0, zBack }, C - 0.5, 0.5, C - 0.5, 1.5, SHADE_SIDE, SHADE_SIDE * FOOT, "fill", keyMid)
                end
              end
            end
          end
        end

      elseif kind == "object" or kind == "solid" then
        -- (a solid cell that is not a member is a detached one)
        -- a lone card on its own front edge, over borrowed ground, cut out
        -- against it
        local g, gy = groundFor(cx, cy, cy, nil)
        local key = keyFor(c, g, cx, cy, cy)
        local f = g or key or c
        if indoor and key and key.kind == "floor" then f = key end
        laid(f, cx, cy, f == g and gy or 0, SHADE_TOP, floorShade(cx, cy))
        local zf = (cy + 1) * C
        standQuad(emit, c, "u", "object", cx, zf, -drop, C, 0, C, SHADE_FRONT, SHADE_FRONT * FOOT,
          indoor and trimMask(cx, cy, true, true, true, true) or "tree", key and key.mid)
        if (c.over or 0) > 0 then
          standQuad(emit, c, "o", "object", cx, zf + 0.04, -drop, C, 0, C, SHADE_FRONT, SHADE_FRONT * FOOT)
        end

      elseif kind == "overhang" then
        -- overhead art with no structure under it (an arch, an awning): it
        -- hangs one cell up on the cell's front edge, over its own ground
        floorQuad(emit, c, "u", "ground", cx, cy, 0, SHADE_TOP, floorShade(cx, cy))
        standQuad(emit, c, "o", "hang", cx, (cy + 1) * C, C, 2 * C, 0, C, SHADE_FRONT)

      elseif kind == "water" then
        floorQuad(emit, c, "u", "water", cx, cy, -drop, SHADE_TOP)
        if (c.over or 0) > 0 then
          floorQuad(emit, c, "o", "water", cx, cy, -drop + 0.04, SHADE_TOP)
        end

      elseif kind == "ledge" then
        floorQuad(emit, c, "u", "ledge", cx, cy, ledge, SHADE_TOP)
        standQuad(emit, c, "u", "ledge", cx, (cy + 1) * C, 0, ledge, C - ledge, C, SHADE_FRONT)
        if (c.over or 0) > 0 then
          floorQuad(emit, c, "o", "ledge", cx, cy, ledge + 0.04, SHADE_TOP)
        end
        -- side steps where the ledge ends
        for _, d in ipairs({ -1, 1 }) do
          local n = info(cx + d, cy)
          if n.kind ~= "ledge" then
            local x = d < 0 and cx * C or cx * C + C
            sideQuad(emit, c, "side", x, cy * C, cy * C + C, 0, ledge,
              d < 0 and 0.5 or C - 0.5, C - ledge, C, SHADE_SIDE)
          end
        end

      elseif kind == "floor" then
        local north = floorShade(cx, cy)
        floorQuad(emit, c, "u", "floor", cx, cy, 0, SHADE_TOP, north)
        if (c.over or 0) > 0 then
          floorQuad(emit, c, "o", "floor", cx, cy, 0.04, SHADE_TOP, north)
        end
        if tuft > 0 and isGrass(c.beh) then
          standQuad(emit, c, "u", "tuft", cx, (cy + 1) * C - 1, 0, tuft, C - tuft, C,
            SHADE_FRONT, SHADE_FRONT * FOOT)
        end
      end

      -- banks: dry land with water to the south, east or west shows its
      -- edge down to the water line
      if kind ~= "water" and kind ~= "blank" and bankable then
        local sN, eN, wN = info(cx, cy + 1), info(cx + 1, cy), info(cx - 1, cy)
        if sN.kind == "water" and flush(c, sN, "s") then
          standQuad(emit, c, "u", "bank", cx, (cy + 1) * C, -drop, 0, C - drop, C, SHADE_BANK)
        end
        if eN.kind == "water" and flush(c, eN, "e") then
          sideQuad(emit, c, "bank", cx * C + C, cy * C, cy * C + C, -drop, 0, C - 0.5, C - drop, C, SHADE_BANK)
        end
        if wN.kind == "water" and flush(c, wN, "w") then
          sideQuad(emit, c, "bank", cx * C, cy * C, cy * C + C, -drop, 0, 0.5, C - drop, C, SHADE_BANK)
        end
      end

      -- where this cell's ground and its east or south neighbour's do not
      -- meet, a step closes the gap
      lift = 0
      reliefSteps(c, cx, cy)
    end
    if tick then tick() end
  end
end

return Shape
