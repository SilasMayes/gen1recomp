-- Pages of art the mod derives from the ROM's: a tree's leaves without the
-- ground they were drawn over, a layer merged with the one under it.  Each
-- slot is a 16 x 16 tile with a pixel of margin, painted once from the
-- metatiles' pixels (Pixels.lua) and kept until the map's tilesets change.
local lib = ...
local Pixels = lib("Pixels")

local Derived = {}

local SIZE = 1024
local STEP = 18                 -- 16 + a pixel of margin either side
local PER = math.floor(SIZE / STEP)

local pages = {}                -- { data, image, dirty, used }
local slots = {}                -- key -> { page, x, y }

local function newPage()
  local p = { data = love.image.newImageData(SIZE, SIZE), used = 0, dirty = true }
  pages[#pages + 1] = p
  return #pages, p
end

--- The slot for `key`, painting it with paint(set) the first time:
-- set(x, y, r, g, b, a) with x, y in 0..15 and colours 0..1.  Returns the
-- page number and the slot's texel origin, or nil if paint gives up.
function Derived.slot(key, paint)
  local s = slots[key]
  if s then return s.page, s.x, s.y end
  local n, p = #pages, pages[#pages]
  if not p or p.used >= PER * PER then n, p = newPage() end
  local i = p.used
  local x, y = (i % PER) * STEP + 1, math.floor(i / PER) * STEP + 1
  local data = p.data
  local px = {}
  local ok = paint(function(tx, ty, r, g, b, a)
    px[ty * 16 + tx + 1] = { r, g, b, a }
  end)
  if ok == false then return nil end
  for ty = 0, 15 do
    for tx = 0, 15 do
      local c = px[ty * 16 + tx + 1]
      if c then data:setPixel(x + tx, y + ty, c[1], c[2], c[3], c[4]) end
    end
  end
  -- the margin repeats the edge, so filtering never reaches the next slot
  for t = -1, 16 do
    local ct = math.max(0, math.min(15, t))
    for _, e in ipairs({ { -1, 0 }, { 16, 15 } }) do
      local r, g, b, a = data:getPixel(x + e[2], y + ct)
      data:setPixel(x + e[1], y + t, r, g, b, a)
      r, g, b, a = data:getPixel(x + ct, y + e[2])
      data:setPixel(x + t, y + e[1], r, g, b, a)
    end
  end
  p.used = i + 1
  p.dirty = true
  slots[key] = { page = n, x = x, y = y }
  return n, x, y
end

function Derived.size() return SIZE end

--- The page's image, uploaded if anything was painted since.
function Derived.image(n)
  local p = pages[n]
  if not p then return nil end
  if p.dirty then
    if p.image then p.image:replacePixels(p.data)
    else
      p.image = love.graphics.newImage(p.data)
      p.image:setFilter("nearest", "nearest")
    end
    p.dirty = false
  end
  return p.image
end

function Derived.flush()
  for _, p in ipairs(pages) do
    if p.image then p.image:release() end
  end
  pages, slots = {}, {}
end

-- ------- what is derived

local function rgb(t, i)
  return t.r[i] / 31, t.g[i] / 31, t.b[i] / 31
end

--- A metatile's two layers merged, the pixels that match `ground` (another
-- metatile of the pair: what the drawing was laid over) cleared.  nil while
-- the pair streams in.
function Derived.cutout(pair, mid, ground)
  local key = "cut|" .. pair .. "|" .. mid .. "|" .. tostring(ground)
  return Derived.slot(key, function(set)
    local u = Pixels.tile(pair, mid, "under")
    local o = Pixels.tile(pair, mid, "over")
    local g = ground and Pixels.tile(pair, ground, "under")
    if not u then return false end
    for i = 1, 256 do
      local x, y = (i - 1) % 16, math.floor((i - 1) / 16)
      if o and o.a[i] == 1 then
        set(x, y, o.r[i] / 31, o.g[i] / 31, o.b[i] / 31, 1)
      elseif u.a[i] == 1 and not (g and g.r[i] == u.r[i] and g.g[i] == u.g[i] and g.b[i] == u.b[i]) then
        local r, gg, b = rgb(u, i)
        set(x, y, r, gg, b, 1)
      else
        set(x, y, 0, 0, 0, 0)
      end
    end
    return true
  end)
end

--- The ground a tree was drawn over, in the crown's shade where the crown
-- covers it: those pixels are hidden behind the crown at 45 degrees, so
-- shading them changes nothing the drawing shows, and the gaps a lower
-- camera finds between crowns read as a wood's floor.
function Derived.shadedGround(pair, mid, ground, shade)
  local key = "shade|" .. pair .. "|" .. mid .. "|" .. tostring(ground) .. "|" .. shade
  return Derived.slot(key, function(set)
    local u = Pixels.tile(pair, mid, "under")
    local o = Pixels.tile(pair, mid, "over")
    local g = Pixels.tile(pair, ground, "under")
    if not (u and g) then return false end
    for i = 1, 256 do
      local x, y = (i - 1) % 16, math.floor((i - 1) / 16)
      local covered = (o and o.a[i] == 1) or
        (u.a[i] == 1 and not (g.r[i] == u.r[i] and g.g[i] == u.g[i] and g.b[i] == u.b[i]))
      local k = covered and shade or 1
      set(x, y, g.r[i] / 31 * k, g.g[i] / 31 * k, g.b[i] / 31 * k, 1)
    end
    return true
  end)
end

return Derived
