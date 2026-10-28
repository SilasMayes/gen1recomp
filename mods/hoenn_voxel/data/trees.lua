-- The General tileset's trees, as Emerald 3DS reads them
-- (src/voxel/voxel_tree.c, scripts/voxel_terraces.py, MIT): which part of a
-- tree each metatile draws, and the ground a crown was drawn over.  Trees
-- the table does not know are found by their leaves (Reader.lua).
local T = {}

-- "U" a crown's upper row, "L" its lower row (the trunk's), "S" a small
-- tree's trunk (its crown is the cell north of it)
T.PART = {
  [0x01E] = "U", [0x01F] = "U", [0x026] = "L", [0x027] = "L", [0x036] = "L", [0x037] = "L",
  [0x1D4] = "U", [0x1D6] = "U", [0x1D5] = "U", [0x1D7] = "U",
  [0x1DC] = "L", [0x1DE] = "L", [0x1E4] = "L", [0x1E6] = "L",
  [0x1DD] = "L", [0x1DF] = "L", [0x1E5] = "L", [0x1E7] = "L",
  [0x1EC] = "L", [0x1ED] = "L", [0x1F3] = "L", [0x1F2] = "L",
  [0x1FC] = "U", [0x1FD] = "U",
  [0x016] = "S", [0x017] = "S", [0x0C6] = "S", [0x0C7] = "S", [0x1F4] = "S", [0x1F5] = "S",
}

-- secondary tilesets' own small trunks, by secondary name
T.OWN_TRUNKS = {
  dewford = { [0x23A] = true, [0x243] = true },
  fortree = { [0x253] = true, [0x22A] = true },
  mauville = { [0x226] = true },
  lavaridge = { [0x218] = true, [0x21A] = true, [0x3B8] = true, [0x203] = true },
}

-- a crown drawn over a ground: the ground (General ids)
T.GROUND = {
  [0x1C6] = 0x00D, [0x1C7] = 0x00D,       -- tall grass
  [0x1CE] = 0x001, [0x1CF] = 0x001,       -- grass
  [0x00E] = 0x001, [0x00F] = 0x001, [0x040] = 0x001,
  [0x01D] = 0x002,                        -- a ledge's edge
  [0x025] = 0x00D,
  [0x02D] = 0x0A1,                        -- reflective water
  [0x035] = 0x170, [0x193] = 0x170,       -- calm water
  [0x0CE] = 0x091,                        -- rock, sand at its foot
}
T.GROUND_OWN = {
  dewford = { [0x239] = 0x124 },
  mauville = { [0x2C1] = 0x205 },
  fortree = { [0x316] = 0x001, [0x317] = 0x001 },
}

-- the crown card's angle from the ground, degrees (Emerald 3DS's: about
-- square to the camera across its ladder)
T.ANGLE = 50

return T
