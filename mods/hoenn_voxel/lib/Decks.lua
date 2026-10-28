-- What the cartridge says stands over the ground: the walkable regions the
-- player is on a level above the rest (Dramatic Shapes reads the elevation
-- byte for these), and bridges by their behaviour.
--
--   * a walkable region at an elevation over the ground's (4 up; 15 is
--     "any", 0 and 1 the ground's own transitions and water) of at least
--     MIN cells stands that many levels up: the cycling road over Route
--     110, Fortree's walkways
--   * a bridge stands as high as its behaviour says (low, medium, high)
--   * the blocked cells beside a deck, west and east, are its railings: they
--     stand on it
--   * where a deck crosses a way beneath it (elevation 15: walkable at both
--     levels) it stands high enough to pass under, UNDERPASS pixels at least,
--     and the ground goes on under it at its own level
local lib = ...

local Decks = {}

Decks.MIN = 8
Decks.UNDERPASS = 32
Decks.DATUM = 3
Decks.LEVEL = 16
-- pixels a bridge's deck stands over what it crosses (Dramatic Shapes's
-- bridge lifts, in its units of 4 pixels)
Decks.BRIDGE = {
  BRIDGE_OVER_OCEAN = 8, BRIDGE_OVER_POND_LOW = 4, BRIDGE_OVER_POND_MED = 8,
  BRIDGE_OVER_POND_HIGH = 12, BRIDGE_OVER_POND_MED_EDGE_1 = 8, BRIDGE_OVER_POND_MED_EDGE_2 = 8,
  BRIDGE_OVER_POND_HIGH_EDGE_1 = 12, BRIDGE_OVER_POND_HIGH_EDGE_2 = 12, FORTREE_BRIDGE = 8,
  BIKE_BRIDGE_OVER_BARRIER = 8,
}

--- Raise result.top where the cart says so.  Returns the set of raised cells.
function Decks.apply(input, result)
  local w, h = input.w, input.h
  local cells = input.cells
  local function at(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return nil end
    return y * w + x + 1
  end
  local lift = {}
  local under = {}        -- cell -> the level of the way beneath the deck
  -- elevation decks
  local function deckCell(i)
    local c = cells[i]
    return c and not c.blank and c.walk and not c.water and c.elev and c.elev > Decks.DATUM
  end
  local seen = {}
  for i = 1, w * h do
    local c = cells[i]
    if deckCell(i) and c.elev ~= 15 and not seen[i] then
      local comp, stack, counts = {}, { i }, {}
      seen[i] = true
      while #stack > 0 do
        local j = table.remove(stack)
        comp[#comp + 1] = j
        local e = cells[j].elev
        if e ~= 15 then counts[e] = (counts[e] or 0) + 1 end
        local x, y = (j - 1) % w, math.floor((j - 1) / w)
        for _, n in ipairs({ at(x - 1, y), at(x + 1, y), at(x, y - 1), at(x, y + 1) }) do
          if n and not seen[n] and deckCell(n) then seen[n] = true; stack[#stack + 1] = n end
        end
      end
      local best, elev = 0, nil
      for e, n in pairs(counts) do if n > best then best, elev = n, e end end
      if elev and best >= Decks.MIN then
        local px = (elev - Decks.DATUM) * Decks.LEVEL
        local crosses = false
        for _, j in ipairs(comp) do if cells[j].elev == 15 then crosses = true end end
        if crosses then px = math.max(px, Decks.UNDERPASS) end
        for _, j in ipairs(comp) do
          lift[j] = px
          if cells[j].elev == 15 then under[j] = result.top[j] or 0 end
        end
      end
    end
  end
  -- bridges by behaviour
  for i = 1, w * h do
    local c = cells[i]
    local px = c.beh and Decks.BRIDGE[c.beh]
    if px and not lift[i] then lift[i] = px end
  end
  -- railings: blocked cells beside a deck in its row
  local rail = {}
  for i, px in pairs(lift) do
    local x, y = (i - 1) % w, math.floor((i - 1) / w)
    for _, n in ipairs({ at(x - 1, y), at(x + 1, y) }) do
      if n and not lift[n] and not cells[n].walk and not cells[n].blank and not cells[n].tree then
        rail[n] = math.max(rail[n] or 0, px)
      end
    end
  end
  for i, px in pairs(rail) do lift[i] = px end
  -- every deck has the ground going on under it, at its own level
  for i in pairs(lift) do
    if under[i] == nil then under[i] = result.top[i] or 0 end
  end
  for i, px in pairs(lift) do result.top[i] = (result.top[i] or 0) + px end
  return lift, under
end

return Decks
