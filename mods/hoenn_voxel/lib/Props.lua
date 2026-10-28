-- The small things the drawing stands on its ground: signs, posts, lamps,
-- fences, pots.  A blocked cell nothing else claims (no tree, building,
-- rock, water or ledge), and the roof-covered cell over one (a lamp's head),
-- is a prop: it lays the ground it was drawn over and stands its drawing
-- upright from its base row, the cut-out card the trees use, at 90 degrees.
-- A fence running north-south cannot stand upright (an upright plane facing
-- east is one drawn column): it is laid on a ridge across its drawn width,
-- 45 degrees either side, the way a band is.  A blob of blocked cells more
-- than two rows tall and more than a column wide is a mass (a cave's rock,
-- a cliff drawn in a town's own tiles): its rows over the ground stand as
-- faces, MASS_FACE rows at most, and the rest is its top.
local lib = ...

local Props = {}

Props.MASS_FACE = 2

function Props.read(input, result, info, groundNear)
  local w, h = input.w, input.h
  local cells = input.cells
  local read = result.read
  local function at(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return nil end
    return y * w + x + 1
  end
  local candidate = {}
  for i = 1, w * h do
    local c = cells[i]
    candidate[i] = not info[i] and not c.blank and not c.walk and not c.water and not c.ledge
      and not c.tree and not c.bridge and read[i] ~= "R" and read[i] ~= "T"
  end
  local function cand(i) return i ~= nil and candidate[i] end
  local ridges = {}
  local mass = {}
  -- the masses: components more than two rows tall and a column wide, on
  -- the maps drawn with the General tileset (outdoors, caves); a building's
  -- rooms draw their walls and furniture upright, never as rock
  if input.general then
    local seen = {}
    for i = 1, w * h do
      if candidate[i] and not seen[i] then
        local comp, stack = {}, { i }
        seen[i] = true
        local y0, y1, x0, x1 = math.huge, -math.huge, math.huge, -math.huge
        while #stack > 0 do
          local j = table.remove(stack)
          comp[#comp + 1] = j
          local x, y = (j - 1) % w, math.floor((j - 1) / w)
          y0, y1 = math.min(y0, y), math.max(y1, y)
          x0, x1 = math.min(x0, x), math.max(x1, x)
          for _, n in ipairs({ at(x - 1, y), at(x + 1, y), at(x, y - 1), at(x, y + 1) }) do
            if cand(n) and not seen[n] then seen[n] = true; stack[#stack + 1] = n end
          end
        end
        local inComp = {}
        for _, j in ipairs(comp) do inComp[j] = true end
        -- a mass is solid: some cell of it has the mass on all four sides
        -- (a ring of fence posts, a line of rocks round a pool, is not one)
        local solid = false
        for _, j in ipairs(comp) do
          local x, y = (j - 1) % w, math.floor((j - 1) / w)
          if inComp[at(x - 1, y)] and inComp[at(x + 1, y)] and inComp[at(x, y - 1)]
              and inComp[at(x, y + 1)] then
            solid = true
            break
          end
        end
        if y1 - y0 + 1 > 2 and x1 > x0 and solid then
          for _, j in ipairs(comp) do
            local x, y = (j - 1) % w, math.floor((j - 1) / w)
            local d = 1
            while inComp[at(x, y + d)] do d = d + 1 end
            -- d: this cell's row counted up from the ground under its column
            local below = at(x, y + d)
            local level = below and result.top[below] or result.top[j] or 0
            mass[j] = { d = d, level = level }
          end
        end
      end
    end
  end
  for i = 1, w * h do
    if candidate[i] and not mass[i] then
      local x, y = (i - 1) % w, math.floor((i - 1) / w)
      local top, bottom = y, y
      while cand(at(x, top - 1)) do top = top - 1 end
      while cand(at(x, bottom + 1)) do bottom = bottom + 1 end
      local run = bottom - top + 1
      local side = cand(at(x - 1, y)) or cand(at(x + 1, y))
      local g = groundNear(x, y)
      -- in a building's rooms a tall run is furniture against the wall:
      -- it stands in pieces of two rows, each on its own lowest row
      local piece = bottom
      if run >= 3 and not input.general then
        piece = bottom - 2 * math.floor((bottom - y) / 2)
        run = 2
      end
      if run >= 3 and not side then
        ridges[i] = true
      elseif run <= 2 and g and not (input.waterMid and input.waterMid[g]) then
        info[i] = { prop = true, base = piece, ground = g, level = result.top[i] }
        -- a roof-covered walkable head over the column's top
        local n = at(x, top - 1)
        if y == top and n and cells[n].walk and not info[n] and not cells[n].water then
          local s = input.tiles[cells[n].m]
          if s and s.cover > 0.2 then
            info[n] = { prop = true, base = bottom, ground = groundNear(x, top - 1) or g,
              level = result.top[i] }
          end
        end
      end
    end
  end
  return ridges, mass
end

--- A mass cell's relief: a face for its first rows over the ground, the
-- top past them.
function Props.massRelief(m, Relief)
  local L = 16
  if m.d <= Props.MASS_FACE then return Relief.piece("S", m.level + m.d * L) end
  return Relief.flat(m.level + Props.MASS_FACE * L)
end

--- A north-south fence's ridge: its drawn width (the pixels that are not
-- the ground's) peaked in the middle at 45 degrees.
function Props.ridge(s, gs, level, Relief)
  if not (s and s.cls) then return nil end
  local c0, c1
  for x = 0, 15 do
    -- a column the fence is drawn in: its pixels differ from the ground's
    local n = 0
    for y = 0, 15 do
      local i = y * 16 + x + 1
      if gs and gs.cls and s.cls:byte(i) ~= gs.cls:byte(i) then n = n + 1 end
    end
    if n >= 4 then c0 = c0 or x; c1 = x + 1 end
  end
  if not c0 then c0, c1 = 4, 12 end
  local mid = (c0 + c1) / 2
  local hgt = math.max(2, (c1 - c0) / 2)
  local pts = { { 0, level } }
  if c0 > 0 then pts[#pts + 1] = { c0, level } end
  pts[#pts + 1] = { mid, level + hgt }
  if c1 < 16 then pts[#pts + 1] = { c1, level } end
  pts[#pts + 1] = { 16, level }
  return Relief.profile("u", pts, "ridge")
end

return Props
