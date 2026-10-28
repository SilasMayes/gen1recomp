-- A map's terrain counted off the main thread: Terrain.solve over the plain
-- data the Reader gathered.  The job sandbox has no mod:read, so the two
-- files it needs come along as source.
local arg = ...
local T = assert(load(arg.data, "@data/terrain.lua"))()
local Terrain = assert(load(arg.terrain, "@lib/Terrain.lua"))()
return Terrain.solve(arg.input, T)
