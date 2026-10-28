-- The building profile (data/buildings.lua): finding a listed drawing on the
-- map, and turning its rows into the numbers Hip.lua builds with.
--
-- A drawing is found by its metatile grid.  A grid of the primary tileset's
-- own ids stands in any town of that primary; one that uses secondary ids
-- only in a pair of that secondary.  Pairs are named "primary__secondary" by
-- the ROM import; a pair named otherwise is not checked, and the grid alone
-- decides.
--
-- Pure Lua.  Coordinates are cells (16 px) and world pixels (v counted down
-- the map, as in Hip.lua).
local Buildings = {}
Buildings.__index = Buildings

local C = 16

local KINDS = {
  back = true, ridge = true, slope = true, dome = true, flat = true,
  skirt = true, upper = true, fascia = true, eave = true, soffit = true,
  wall = true, base = true,
}
local UPRIGHT = { fascia = true, eave = true, soffit = true, wall = true, base = true }
Buildings.KINDS, Buildings.UPRIGHT = KINDS, UPRIGHT

--- The tilesets a pair is made of: primary, secondary (nil when the name
-- does not say).
function Buildings.tilesets(pair)
  if type(pair) ~= "string" then return nil end
  local a, b = pair:match("^(.-)__(.+)$")
  return a, b
end

-- ------- checking an entry

local function checkBands(bands, height, where, errs)
  if type(bands) ~= "table" or #bands == 0 then
    errs[#errs + 1] = where .. ": no bands"
    return
  end
  local last = -1
  for i, b in ipairs(bands) do
    local kind, a, z = b[1], b[2], b[3]
    if not KINDS[kind] then errs[#errs + 1] = ("%s: band %d: unknown kind %s"):format(where, i, tostring(kind)) end
    if type(a) ~= "number" or type(z) ~= "number" or a > z then
      errs[#errs + 1] = ("%s: band %d: bad rows"):format(where, i)
    elseif a <= last then
      errs[#errs + 1] = ("%s: band %d overlaps the one before"):format(where, i)
    elseif z >= height then
      errs[#errs + 1] = ("%s: band %d runs past the drawing (%d rows)"):format(where, i, height)
    else
      last = z
    end
  end
  if not UPRIGHT[bands[#bands][1]] then
    errs[#errs + 1] = where .. ": the last band is not part of the front wall"
  end
end

--- Problems with the profile, as a list of strings (empty: none).
function Buildings.check(data)
  local errs, ids = {}, {}
  if type(data) ~= "table" or type(data.buildings) ~= "table" then
    return { "no buildings list" }
  end
  for n, e in ipairs(data.buildings) do
    local where = tostring(e.id or ("#" .. n))
    if type(e.id) ~= "string" then errs[#errs + 1] = where .. ": no id" end
    if ids[e.id] then errs[#errs + 1] = where .. ": id used twice" end
    ids[e.id] = true
    if type(e.primary) ~= "string" then errs[#errs + 1] = where .. ": no primary tileset" end
    local g = e.grid
    if type(g) ~= "table" or #g == 0 or type(g[1]) ~= "table" or #g[1] == 0 then
      errs[#errs + 1] = where .. ": no grid"
    else
      local w, any, high = #g[1], false, false
      for j, row in ipairs(g) do
        if #row ~= w then errs[#errs + 1] = ("%s: grid row %d is %d wide, not %d"):format(where, j, #row, w) end
        for i = 1, w do
          local m = row[i]
          if m ~= false then
            if type(m) ~= "number" or m < 0 or m > 0x3ff then
              errs[#errs + 1] = ("%s: grid %d,%d: not a metatile id"):format(where, i - 1, j - 1)
            else
              any = true
              if m >= 0x200 then high = true end
            end
          end
        end
      end
      if not any then errs[#errs + 1] = where .. ": the grid matches nothing" end
      if high and type(e.secondary) ~= "string" then
        errs[#errs + 1] = where .. ": secondary ids with no secondary tileset"
      end
      local height = (#g + (e.cap or 0)) * C
      checkBands(e.bands, height, where, errs)
      if e.roof ~= nil and e.roof ~= "hip" and e.roof ~= "flat" then
        errs[#errs + 1] = where .. ": roof is hip or flat"
      end
      local function checkRidge(ridge, bands, wh)
        if ridge == nil then return end
        local hasBack = false
        for _, b in ipairs(bands or {}) do if b[1] == "back" then hasBack = true end end
        if type(ridge) ~= "number" or ridge <= 0 or ridge >= height then
          errs[#errs + 1] = wh .. ": ridge row out of the drawing"
        elseif not hasBack then
          errs[#errs + 1] = wh .. ": a ridge with no back slope drawn"
        end
      end
      checkRidge(e.ridge, e.bands, where)
      for k, p in ipairs(e.parts or {}) do
        local pw = where .. " part " .. k
        local c = p.cols
        if type(c) ~= "table" or type(c[1]) ~= "number" or type(c[2]) ~= "number"
            or c[1] < 0 or c[2] >= w or c[1] > c[2] then
          errs[#errs + 1] = pw .. ": bad columns"
        end
        if p.bands then checkBands(p.bands, height, pw, errs) end
        checkRidge(p.ridge, p.bands or e.bands, pw)
      end
      if e.upper then
        local u = e.upper
        local found = false
        for _, b in ipairs(e.bands or {}) do if b[1] == "upper" then found = true end end
        if not found then errs[#errs + 1] = where .. ": upper columns with no upper band" end
        if type(u[1]) ~= "number" or type(u[2]) ~= "number" or u[1] < 0 or u[2] >= w * C or u[1] >= u[2] then
          errs[#errs + 1] = where .. ": bad upper columns"
        end
      end
    end
  end
  return errs
end

-- ------- the index

--- An index over the profile's entries (those that check out; the rest are
-- listed in `idx.errors`).
function Buildings.new(data)
  local idx = setmetatable({ entries = {}, byMid = {}, errors = {}, reach = 0 }, Buildings)
  if type(data) ~= "table" or type(data.buildings) ~= "table" then
    idx.errors = { "no buildings list" }
    return idx
  end
  for _, e in ipairs(data.buildings) do
    local errs = Buildings.check({ buildings = { e } })
    if #errs == 0 then
      idx.entries[#idx.entries + 1] = e
      -- every listed cell of the grid points back at its place in it; an
      -- open cell is found through the nearest listed one in its row, so
      -- the index remembers how far that can be
      for j, row in ipairs(e.grid) do
        for i, m in ipairs(row) do
          if m ~= false then
            local list = idx.byMid[m]
            if not list then list = {} idx.byMid[m] = list end
            list[#list + 1] = { e, i - 1, j - 1 }
          else
            local d = math.huge
            for k, n in ipairs(row) do
              if n ~= false then d = math.min(d, math.abs(k - i)) end
            end
            if d < math.huge then idx.reach = math.max(idx.reach, d) end
          end
        end
      end
    else
      for _, s in ipairs(errs) do idx.errors[#idx.errors + 1] = s end
    end
  end
  return idx
end

-- does entry e stand with its grid's top-left cell at (ox, oy)?
local function standsAt(e, info, ox, oy)
  local p, s
  for j, row in ipairs(e.grid) do
    for i, m in ipairs(row) do
      if m ~= false then
        local c = info(ox + i - 1, oy + j - 1)
        if not c or c.mid ~= m then return false end
        if not p and c.pair then p, s = Buildings.tilesets(c.pair) end
      end
    end
  end
  if p then
    if p ~= e.primary then return false end
    if e.secondary and s ~= e.secondary then return false end
  end
  return true
end

--- The listed drawing whose grid covers cell (cx, cy): entry, ox, oy (the
-- grid's top-left cell), or nil.  `memo` (optional) keeps the answers for as
-- long as the caller's cells stay the same (Shape keeps one per build).
function Buildings:at(info, cx, cy, memo)
  memo = memo or {}
  local k = cx .. "," .. cy
  local hit = memo[k]
  if hit ~= nil then
    if hit then return hit[1], hit[2], hit[3] end
    return nil
  end
  local c = info(cx, cy)
  local found = false
  -- the cell's own metatile names the places it can hold in a grid; a cell
  -- the grid leaves open (false) is found through a listed neighbour in its
  -- row, which every grid row has
  local function try(mid, x, y)
    for _, cand in ipairs(self.byMid[mid] or {}) do
      local e, i, j = cand[1], cand[2], cand[3]
      local ox, oy = x - i, y - j
      if cx >= ox and cx < ox + #e.grid[1] and cy >= oy and cy < oy + #e.grid
          and standsAt(e, info, ox, oy) then
        return { e, ox, oy }
      end
    end
    return nil
  end
  if c and c.mid and self.byMid[c.mid] then found = try(c.mid, cx, cy) or false end
  if not found then
    for d = 1, self.reach do
      for _, x in ipairs({ cx - d, cx + d }) do
        local n = info(x, cy)
        if n and n.mid and self.byMid[n.mid] then
          found = try(n.mid, x, cy) or false
          if found then break end
        end
      end
      if found then break end
    end
  end
  memo[k] = found
  if found then return found[1], found[2], found[3] end
  return nil
end

--- The columns (cells) of the listed drawing that stand as one block with
-- column cx of row cy: its part's, or the run of columns no part claims
-- round cx.  nil when no listed drawing covers the cell.
function Buildings:span(info, cx, cy, memo)
  local e, ox = self:at(info, cx, cy, memo)
  if not e then return nil end
  local i = cx - ox
  for _, p in ipairs(e.parts or {}) do
    if i >= p.cols[1] and i <= p.cols[2] then return ox + p.cols[1], ox + p.cols[2] end
  end
  local function claimed(j)
    for _, p in ipairs(e.parts or {}) do
      if j >= p.cols[1] and j <= p.cols[2] then return true end
    end
    return false
  end
  local a, b = i, i
  while a > 0 and not claimed(a - 1) do a = a - 1 end
  while b < #e.grid[1] - 1 and not claimed(b + 1) do b = b + 1 end
  return ox + a, ox + b
end

-- ------- the numbers a block is built with

-- the part of entry e over grid columns i0..i1, or the entry itself
local function partOf(e, i0, i1)
  for _, p in ipairs(e.parts or {}) do
    if i0 >= p.cols[1] and i1 <= p.cols[2] then return p end
  end
  return nil
end

--- For the block over cells bx0..bx1 whose front row is `bottom` and whose
-- front wall stands at zf (world px): what the profile says, or nil when no
-- listed drawing covers the block's whole front.
--   id      the entry's id (with its part, "id/2")
--   vt      the drawing's top row, as v (its first band's first row)
--   hw      the front wall's height at zf: the upright rows at the bottom
--   ridge   the ridge line, as v, when the drawing shows its back slope
--   flat    true for a roof drawn from straight above
--   tier    { vtop, vb, inset } for an upper storey (Hip.lua's `b.tier`)
--   zf      where the front wall stands, when the drawing's foot is further
--           out than the collision's edge: into the walkable row under it
--           (the Gym's wings), never further than that row
function Buildings:block(info, bx0, bx1, bottom, zf, memo)
  local e, ox, oy = self:at(info, bx0, bottom, memo)
  if not e then return nil end
  local w, h = #e.grid[1], #e.grid
  if bx1 >= ox + w or bottom >= oy + h then return nil end
  local i0, i1 = bx0 - ox, bx1 - ox
  local part = partOf(e, i0, i1)
  local bands = (part and part.bands) or e.bands
  local roof = (part and part.roof) or e.roof or "hip"
  local ridge = part and part.ridge
  if ridge == nil and not (part and part.bands) then ridge = e.ridge end
  local v0 = (oy - (e.cap or 0)) * C
  -- the drawing's foot, when it stands in the row under the collision
  local foot = v0 + bands[#bands][3] + 1
  local moved
  if foot > zf + 0.5 and foot <= zf + C then zf, moved = foot, foot end
  -- the front wall: the upright run at the bottom
  local k = #bands
  while k > 1 and UPRIGHT[bands[k - 1][1]] do k = k - 1 end
  local hw = zf - (v0 + bands[k][2])
  if hw < 4 then return nil end
  local spec = {
    id = e.id, entry = e, part = part,
    vt = v0 + bands[1][2],
    hw = hw,
    zf = moved,
    flat = roof == "flat",
    ox = ox, oy = oy,
  }
  if part then
    for n, p in ipairs(e.parts) do if p == part then spec.id = e.id .. "/" .. n end end
  end
  if ridge and roof == "hip" then spec.ridge = v0 + ridge end
  -- the upper storey: its wall, with the eave line or fascia over it
  for n, b in ipairs(bands) do
    if b[1] == "upper" and e.upper then
      local top = n
      while top > 1 and UPRIGHT[bands[top - 1][1]] do top = top - 1 end
      local ux0, ux1 = ox * C + e.upper[1], ox * C + e.upper[2] + 1
      local inset = math.min(ux0 - bx0 * C, (bx1 + 1) * C - ux1)
      if inset > 0 then
        spec.tier = { vtop = v0 + bands[top][2], vb = v0 + b[3] + 1, inset = inset }
      end
      break
    end
  end
  return spec
end

return Buildings
