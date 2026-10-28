-- Buildings, found the way Dramatic Shapes finds them: from their doors.
-- A door's cell is the bottom row of a building; its columns are the runs of
-- blocked (or roof-covered) cells over that row, west and east of the door
-- for as long as each column stands at least two rows tall.  What is a wall
-- and what is roof is read off the drawing: the facade's colours are the
-- door row's, the roof's the layer drawn over the player, and the eave is
-- the lowest pixel row drawn mostly in roof colours.
--
-- A building is modelled once from that reading (Models.lua): its facade
-- stands upright, its roof rises from the eave at its pitch, and its ends
-- are walls dressed by height from the facade and roof beside them.  Specs
-- (data/buildings.lua) override what is read where a building is known.
local lib = ...
local Pixels = lib("Pixels")

local Buildings = {}

Buildings.MAX_ROWS = 10       -- a building is no taller than this
Buildings.MAX_HALF = 10       -- columns either side of a door
Buildings.PITCH = 22          -- degrees, the roof (Emerald 3DS's houses)

local function key(r, g, b) return r * 1024 + g * 32 + b end

--- Find the buildings of a map.  input: the Reader's; result: Terrain's;
-- pair: the map's tileset pair.  Returns a list and marks info[i].building.
function Buildings.read(input, result, pair, info, groundNear)
  local w, h = input.w, input.h
  local cells = input.cells
  local read = result.read
  local function at(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return nil end
    return y * w + x + 1
  end
  local function cover(i)
    local s = input.tiles[cells[i].m]
    return s and s.cover or 0
  end
  -- a cell a building can be made of
  local function part(i)
    if not i then return false end
    local c = cells[i]
    if c.blank or c.water or c.ledge or c.tree or info[i] then return false end
    local k = read[i]
    if k == "R" or k == "T" then return false end
    return (not c.walk) or cover(i) > 0.5
  end
  local list = {}
  local taken = {}
  for i = 1, w * h do
    local c = cells[i]
    if c.warp and not taken[i] and read[i] ~= "R" then
      local dx, dy = (i - 1) % w, math.floor((i - 1) / w)
      -- the column over a cell of the door's row: its top, if it stands two
      -- rows or more
      local function column(x)
        local b = at(x, dy)
        if not b or taken[b] then return nil end
        if x ~= dx and not part(b) then return nil end
        local top = dy
        while top > dy - Buildings.MAX_ROWS + 1 and part(at(x, top - 1)) do top = top - 1 end
        if dy - top + 1 < 2 then return nil end
        -- a column that runs on past the tallest building is a mass the
        -- door is cut into (Sootopolis's houses in the crater's rock)
        if part(at(x, top - 1)) then return nil end
        return top
      end
      local cols = {}
      local t0 = column(dx)
      if t0 then
        cols[dx] = t0
        local x0, x1 = dx, dx
        for x = dx - 1, dx - Buildings.MAX_HALF, -1 do
          local t = column(x)
          if not t then break end
          cols[x] = t
          x0 = x
        end
        for x = dx + 1, dx + Buildings.MAX_HALF do
          local t = column(x)
          if not t then break end
          cols[x] = t
          x1 = x
        end
        if x1 > x0 then
          local b = { x0 = x0, x1 = x1, bottom = dy, cols = cols, door = { dx, dy },
            level = result.top[i] or 0 }
          for x = x0, x1 do
            for y = cols[x], dy do
              local j = at(x, y)
              taken[j] = true
              info[j] = { building = #list + 1, ground = groundNear(x, y) }
            end
          end
          list[#list + 1] = b
        end
      end
    end
  end
  -- the walls and roofs, read off the drawing
  for _, b in ipairs(list) do Buildings.eave(b, input, pair) end
  return list
end

-- the composite pixel (over if opaque, else under) of a cell
local function pixel(pair, mid, i)
  local o = Pixels.tile(pair, mid, "over")
  if o and o.a[i] == 1 then return key(o.r[i], o.g[i], o.b[i]), true end
  local u = Pixels.tile(pair, mid, "under")
  if not u then return nil end
  return key(u.r[i], u.g[i], u.b[i]), false
end

--- The eave: how tall the facade stands (pixels over the bottom row's
-- south edge), from the facade's colours and the roof's.
function Buildings.eave(b, input, pair)
  local w = input.w
  local cells = input.cells
  local facade, roof = {}, {}
  local nf, nr = 0, 0
  for x = b.x0, b.x1 do
    local c = cells[b.bottom * w + x + 1]
    if not (x == b.door[1]) then
      for i = 65, 256 do         -- rows 4..15 of the door row
        local k = pixel(pair, c.m, i)
        if k then facade[k] = (facade[k] or 0) + 1; nf = nf + 1 end
      end
    end
    for y = b.cols[x], b.bottom do
      local cy = cells[y * w + x + 1]
      local o = Pixels.tile(pair, cy.m, "over")
      if o then
        for i = 1, 256 do
          if o.a[i] == 1 then
            local k = key(o.r[i], o.g[i], o.b[i])
            roof[k] = (roof[k] or 0) + 1
            nr = nr + 1
          end
        end
      end
    end
  end
  -- the top row is roof whatever layer it is drawn on
  for x = b.x0, b.x1 do
    local c = cells[b.cols[x] * w + x + 1]
    for i = 1, 128 do
      local k = pixel(pair, c.m, i)
      if k then roof[k] = (roof[k] or 0) + 1; nr = nr + 1 end
    end
  end
  local function share(t, n, k) return n > 0 and (t[k] or 0) / n or 0 end
  local vb = (b.bottom + 1) * 16
  local top = math.huge
  for x = b.x0, b.x1 do top = math.min(top, b.cols[x]) end
  local vt = top * 16
  local eave = nil
  -- scan pixel rows upward from the bottom: the eave is under the lowest
  -- run of RUN rows drawn mostly in roof colours (an outline a pixel or two
  -- thick, drawn in both, is no roof)
  local RUN = 3
  local streak = 0
  for v = vb - 5, vt, -1 do
    local cy = math.floor(v / 16)
    local ry = v - cy * 16
    local f, r = 0, 0
    local n = 0
    for x = b.x0, b.x1 do
      if cy >= b.cols[x] then
        local c = cells[cy * w + x + 1]
        for px = 0, 15 do
          local k = pixel(pair, c.m, ry * 16 + px + 1)
          if k then
            local sf, sr = share(facade, nf, k), share(roof, nr, k)
            if sf > sr * 1.5 then f = f + 1 elseif sr > sf * 1.5 then r = r + 1 end
            n = n + 1
          end
        end
      end
    end
    if Buildings.debug then print(("eave scan v=%d f=%d r=%d n=%d"):format(v - vb, f, r, n)) end
    if n > 0 and r > f and r >= 0.3 * n then
      streak = streak + 1
      if streak >= RUN then eave = v + RUN; break end
    else
      streak = 0
    end
  end
  local tall = vb - vt
  local facadeH = eave and (vb - eave) or math.floor(tall / 3)
  facadeH = math.max(8, math.min(tall - 8, facadeH))
  b.facade = facadeH
  b.pitch = Buildings.PITCH
  b.vt, b.vb = vt, vb
end

return Buildings
