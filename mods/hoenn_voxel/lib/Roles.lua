-- What the cartridge says a cell is, before any pixel is looked at
-- (Dramatic Shapes' order: the cart first, the art where the cart says
-- nothing).  Behaviour names come both ways: the engine's (FireRed's names
-- where the games share a value) and pret's Emerald names.
local lib = ...

local Roles = {}

local function set(...)
  local s = {}
  for _, v in ipairs({ ... }) do s[v] = true end
  return s
end

Roles.WATER = set("OCEAN_WATER", "POND_WATER", "DEEP_WATER", "SOOTOPOLIS_DEEP_WATER",
  "INTERIOR_DEEP_WATER", "WATERFALL", "NO_SURFACING", "UNDERWATER_BLOCKED_ABOVE", "SEAWEED",
  "SEAWEED_NO_SURFACING", "EASTWARD_CURRENT", "WESTWARD_CURRENT", "NORTHWARD_CURRENT",
  "SOUTHWARD_CURRENT", "SHALLOW_WATER", "SPLASHING_WATER")
Roles.SURF = set("OCEAN_WATER", "POND_WATER", "DEEP_WATER", "SOOTOPOLIS_DEEP_WATER",
  "INTERIOR_DEEP_WATER", "WATERFALL", "NO_SURFACING", "SEAWEED", "EASTWARD_CURRENT",
  "WESTWARD_CURRENT", "NORTHWARD_CURRENT", "SOUTHWARD_CURRENT")
Roles.JUMP = {
  JUMP_EAST = { 1, 0 }, JUMP_WEST = { -1, 0 }, JUMP_NORTH = { 0, -1 }, JUMP_SOUTH = { 0, 1 },
  JUMP_NORTHEAST = { 1, -1 }, JUMP_NORTHWEST = { -1, -1 }, JUMP_SOUTHEAST = { 1, 1 },
  JUMP_SOUTHWEST = { -1, 1 },
}
Roles.BRIDGE = set("BRIDGE_OVER_OCEAN", "BRIDGE_OVER_POND_LOW", "BRIDGE_OVER_POND_MED",
  "BRIDGE_OVER_POND_HIGH", "BRIDGE_OVER_POND_MED_EDGE_1", "BRIDGE_OVER_POND_MED_EDGE_2",
  "BRIDGE_OVER_POND_HIGH_EDGE_1", "BRIDGE_OVER_POND_HIGH_EDGE_2", "FORTREE_BRIDGE",
  "BIKE_BRIDGE_OVER_BARRIER", "UNUSED_BRIDGE", "PACIFIDLOG_VERTICAL_LOG_TOP",
  "PACIFIDLOG_VERTICAL_LOG_BOTTOM", "PACIFIDLOG_HORIZONTAL_LOG_LEFT",
  "PACIFIDLOG_HORIZONTAL_LOG_RIGHT")
Roles.DOOR = set("WARP_DOOR", "ANIMATED_DOOR", "CAVE_DOOR", "NON_ANIMATED_DOOR", "PETALBURG_GYM_DOOR",
  "SOUTH_ARROW_WARP", "NORTH_ARROW_WARP", "EAST_ARROW_WARP", "WEST_ARROW_WARP", "DEEP_SOUTH_WARP",
  "LADDER", "AQUA_HIDEOUT_WARP", "LAVARIDGE_GYM_B1F_WARP", "MOSSDEEP_GYM_WARP", "MT_PYRE_HOLE",
  "SECRET_BASE_SPOT_RED_CAVE", "SECRET_BASE_SPOT_BROWN_CAVE", "SECRET_BASE_SPOT_YELLOW_CAVE",
  "SECRET_BASE_SPOT_BLUE_CAVE")
Roles.ANIMATED_DOOR = set("WARP_DOOR", "ANIMATED_DOOR", "PETALBURG_GYM_DOOR")
Roles.BERRY = set("BERRY_TREE_SOIL")
Roles.MUD = set("MUDDY_SLOPE")
Roles.FALLS = set("WATERFALL")
Roles.PUDDLE = set("PUDDLE")

--- The cart's word on one cell (a Source cell record): a table of flags.
function Roles.of(c, walkable)
  local beh = c.beh or "NORMAL"
  beh = beh:gsub("^MB_", "")
  local walk = walkable(c.coll)
  local r = {
    walk = walk,
    water = Roles.WATER[beh] == true,
    surf = Roles.SURF[beh] == true,
    jump = Roles.JUMP[beh],
    bridge = Roles.BRIDGE[beh] == true,
    door = Roles.DOOR[beh] == true,
    animatedDoor = Roles.ANIMATED_DOOR[beh] == true,
    berry = Roles.BERRY[beh] == true,
    mud = Roles.MUD[beh] == true,
    falls = Roles.FALLS[beh] == true,
    puddle = Roles.PUDDLE[beh] == true,
    beh = beh,
  }
  if r.puddle then r.water = false end
  return r
end

return Roles
