-- Which cells are trees, which tree each belongs to and what ground it was
-- drawn over.  Pure data in and out (the Reader's input, Terrain's result).
--
-- A tree is a column of cells standing on its base row: a crown's upper row
-- stands on the row south of it, a lower row (a trunk's) on itself.  Every
-- cell of a tree lays the ground it was drawn over and stands its own part
-- of the tree's crown card (Models.lua).
local lib = ...
local D = lib("data/trees")

local Trees = {}

local function secondaryOf(pair)
  return pair and pair:match("__(.+)$") or nil
end

function Trees.read(input, result)
  local w, h = input.w, input.h
  local cells = input.cells
  local sec = secondaryOf(input.pair)
  local general = input.general
  local function at(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return nil end
    return y * w + x + 1
  end
  local function part(i)
    local c = cells[i]
    if not c or c.blank then return nil end
    local m = c.m
    if general and m < 0x200 and D.PART[m] then return D.PART[m] end
    if sec and D.OWN_TRUNKS[sec] and D.OWN_TRUNKS[sec][m] then return "S" end
    if general and m < 0x200 and D.GROUND[m] then return "C" end   -- a small crown over a ground
    if sec and D.GROUND_OWN[sec] and D.GROUND_OWN[sec][m] then return "C" end
    if c.tree then return "?" end
    return nil
  end
  local parts = {}
  for i = 1, w * h do parts[i] = part(i) end
  -- a small crown is a tree only over a trunk
  for i = 1, w * h do
    if parts[i] == "C" then
      local x, y = (i - 1) % w, math.floor((i - 1) / w)
      local s = at(x, y + 1)
      if not (s and (parts[s] == "S" or parts[s] == "?")) then parts[i] = nil end
    end
  end

  -- the ground: the commonest walkable, treeless cell round it
  local mostCommon
  do
    local n, best = {}, 0
    for i = 1, w * h do
      local c = cells[i]
      if not c.blank and c.walk and not parts[i] and not c.water then
        n[c.m] = (n[c.m] or 0) + 1
        if n[c.m] > best then best, mostCommon = n[c.m], c.m end
      end
    end
  end
  local function groundNear(x, y)
    local count, best, pick = {}, 0, nil
    for r = 1, 2 do
      for dy = -r, r do
        for dx = -r, r do
          local n = at(x + dx, y + dy)
          local c = n and cells[n]
          if c and not c.blank and not parts[n] and (c.walk or c.water) and not c.ledge then
            count[c.m] = (count[c.m] or 0) + (r == 1 and 2 or 1)
            if count[c.m] > best then best, pick = count[c.m], c.m end
          end
        end
      end
      if pick then return pick end
    end
    return mostCommon
  end

  -- the metatiles drawn as water on this map: a prop drawn over water lies
  -- on it (a rock in the sea and its ripples), it does not stand up
  input.waterMid = input.waterMid or {}
  for i = 1, w * h do
    local c = cells[i]
    if c.water and not c.blank then input.waterMid[c.m] = true end
  end

  local info = {}
  for x = 0, w - 1 do
    local y = h - 1
    while y >= 0 do
      local i = at(x, y)
      local p = parts[i]
      if p then
        -- the base row: a lower row stands on itself; a crown's upper row on
        -- the lower row south of it
        local base = y
        local n = at(x, y - 1)
        local np = n and parts[n]
        local pairUp = np and (p == "L" or p == "S" or p == "?") and
          (np == "U" or np == "C" or np == "?")
        local m = cells[i].m
        local g = (general and m < 0x200 and D.GROUND[m]) or
          (sec and D.GROUND_OWN[sec] and D.GROUND_OWN[sec][m]) or groundNear(x, y)
        info[i] = { tree = true, base = base, ground = g, level = result.top[i] }
        if pairUp then
          local nm = cells[n].m
          local ng = (general and nm < 0x200 and D.GROUND[nm]) or
            (sec and D.GROUND_OWN[sec] and D.GROUND_OWN[sec][nm]) or groundNear(x, y - 1)
          info[n] = { tree = true, base = base, ground = ng, level = result.top[i] }
          y = y - 2
        else
          y = y - 1
        end
      else
        y = y - 1
      end
    end
  end
  return info, groundNear
end

return Trees
