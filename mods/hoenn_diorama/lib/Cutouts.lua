-- Art derived from the ROM's own metatiles, for the cells that stand up.
--
-- A metatile's under layer is opaque: a tree is painted on its patch of
-- grass, a house's corner on the grass beside it.  Laid flat that is right;
-- stood up, the grass comes along as a square card around the tree.  So
-- the colours of the ground the structure stands on (its "key") are taken
-- back out:
--
--   "cut"   key colours become transparent, for a card with nothing behind
--           it: signs, posts, furniture get their own outline
--   "tree"  "cut", plus the darker shade of the key around a tree (see
--           growKin); only for outdoor cards, where that shade is the
--           tree's shadow on the grass and not part of the thing itself;
--           and only what reaches the cell's edge (what the art encloses
--           is its own)
--   "fill"  key colours are replaced by the nearest art colour, for the
--           facade and roof of a box, which must stay solid: a building's
--           edge stops showing a strip of lawn
--   "roof"  the overhead layer laid over the under layer, then "fill": a
--           hipped roof's faces, one opaque surface.  Hoenn draws many
--           roofs on the overhead layer over plain ground; where that art
--           leaves the ground showing (round a ridge, at a rounded corner)
--           a solid roof would show grass or a hole into the house
--   "roofo" "roof" for a walkable cell: its under layer is ground, all of
--           it key, so only the overhead art and what fills from it show
--   "trimN" only the key pixels joined to an open edge of the cell become
--           transparent (N: 1 north, 2 east, 4 south, 8 west).  For things
--           in a room, whose art often uses the floor's colours inside the
--           object too (a crate's grey sides, a TV's casing): the floor
--           around it goes, what its outline encloses stays
--
-- Results live in a few 512x512 pages built on the CPU (ctx.atlas gives the
-- under layer's ImageData) and uploaded once per frame when they changed.
-- They are copies: a structure tile the ROM animates keeps its first frame.
local Cutouts = {}
Cutouts.__index = Cutouts

local PAGE = 512
local PER_ROW = PAGE / 16
local PER_PAGE = PER_ROW * PER_ROW

function Cutouts.new()
  return setmetatable({ pages = {}, slots = {}, keys = {}, fractions = {}, used = 0 }, Cutouts)
end

function Cutouts:release()
  for _, p in ipairs(self.pages) do
    if p.image and p.image.release then pcall(p.image.release, p.image) end
    if p.data and p.data.release then pcall(p.data.release, p.data) end
  end
  self.pages, self.slots, self.keys, self.fractions, self.used = {}, {}, {}, {}, 0
  self.bands, self.pix, self.comp = {}, {}, {}
end

local function pack(r, g, b)
  return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5)
end

-- hue in degrees and saturation, from 0..1 channels
local function hueSat(r, g, b)
  local hi, lo = math.max(r, g, b), math.min(r, g, b)
  local d = hi - lo
  if hi <= 0 or d <= 0 then return nil, 0 end
  local h
  if hi == r then h = ((g - b) / d) % 6
  elseif hi == g then h = (b - r) / d + 2
  else h = (r - g) / d + 4 end
  return h * 60, d / hi
end

-- A card's ground often carries a shade of itself the flat ground lacks:
-- the darker ring a tree casts on its grass.  Those "kin" colours share
-- the key's hue, so a cut also takes away pixels of the key's hue band
-- that touch what is already cut (or the cell's edge).
local KIN_HUE, KIN_SAT = 8, 0.12

local function hueBand(set)
  local lo, hi
  for v in pairs(set) do
    local r, g, b = math.floor(v / 65536) / 255, math.floor(v / 256) % 256 / 255, v % 256 / 255
    local h, sat = hueSat(r, g, b)
    if h and sat >= KIN_SAT then
      lo = lo and math.min(lo, h) or h
      hi = hi and math.max(hi, h) or h
    end
  end
  if not lo then return nil end
  return lo - KIN_HUE, hi + KIN_HUE
end

local function isKin(band, r, g, b)
  if not band then return false end
  local h, sat = hueSat(r, g, b)
  return h ~= nil and sat >= KIN_SAT and h >= band[1] and h <= band[2]
end

-- grow the cut mask through kin pixels, from what is cut and the edges
local function growKin(px, key, band)
  local kin = {}
  for i = 0, 255 do
    local c = px[i]
    kin[i] = not key[i] and isKin(band, c[1], c[2], c[3])
  end
  local queue, n = {}, 0
  for i = 0, 255 do
    if kin[i] then
      local x, y = i % 16, math.floor(i / 16)
      local seed = x == 0 or x == 15 or y == 0 or y == 15
        or (x > 0 and key[i - 1]) or (x < 15 and key[i + 1])
        or (y > 0 and key[i - 16]) or (y < 15 and key[i + 16])
      if seed then
        key[i], kin[i] = true, false
        n = n + 1
        queue[n] = i
      end
    end
  end
  local head = 1
  while head <= n do
    local i = queue[head]
    head = head + 1
    local x = i % 16
    local around = { x > 0 and i - 1 or nil, x < 15 and i + 1 or nil,
      i >= 16 and i - 16 or nil, i < 240 and i + 16 or nil }
    for k = 1, 4 do
      local j = around[k]
      if j and kin[j] then
        key[j], kin[j] = true, false
        n = n + 1
        queue[n] = j
      end
    end
  end
end

-- the set of colours in a metatile's under art
function Cutouts:keySet(view, keyMid)
  if keyMid == nil or not view.imageData then return nil end
  local k = view.pair .. "|" .. keyMid
  local set = self.keys[k]
  if set then return set end
  local ox, oy = view.origin(keyMid)
  if not ox then return nil end
  set = {}
  local data = view.imageData
  for y = 0, 15 do
    for x = 0, 15 do
      local r, g, b = data:getPixel(ox + x, oy + y)
      set[pack(r, g, b)] = true
    end
  end
  self.keys[k] = set
  return set
end

function Cutouts:bandOf(view, keyMid)
  local k = view.pair .. "|" .. tostring(keyMid)
  self.bands = self.bands or {}
  local b = self.bands[k]
  if b == nil then
    local set = self:keySet(view, keyMid)
    local lo, hi = nil, nil
    if set then lo, hi = hueBand(set) end
    b = lo and { lo, hi } or false
    self.bands[k] = b
  end
  return b or nil
end

--- `mid`'s under art as 256 packed colours (row by row), or nil without
-- CPU pixels.  Read-only: shared between callers.
function Cutouts:pixels(view, mid)
  if mid == nil or not view.imageData then return nil end
  self.pix = self.pix or {}
  local k = view.pair .. "|" .. mid
  local p = self.pix[k]
  if p then return p end
  local ox, oy = view.origin(mid)
  if not ox then return nil end
  p = {}
  local data = view.imageData
  for y = 0, 15 do
    for x = 0, 15 do
      local r, g, b = data:getPixel(ox + x, oy + y)
      p[y * 16 + x] = pack(r, g, b)
    end
  end
  self.pix[k] = p
  return p
end

--- `mid`'s art as the field shows it, its overhead layer over its under
-- layer: 256 packed colours, row by row, or nil without CPU pixels.
function Cutouts:composite(view, mid)
  if mid == nil or not view.imageData then return nil end
  self.comp = self.comp or {}
  local k = view.pair .. "|" .. mid
  local p = self.comp[k]
  if p then return p end
  local under = self:pixels(view, mid)
  if not under then return nil end
  p = {}
  for i = 0, 255 do p[i] = under[i] end
  local over = view.layered and Cutouts.overData(view)
  if over then
    local ox, oy = view.origin(mid)
    for y = 0, 15 do
      for x = 0, 15 do
        local r, g, b, a = over:getPixel(ox + x, oy + y)
        if a > 0.5 then p[y * 16 + x] = pack(r, g, b) end
      end
    end
  end
  self.comp[k] = p
  return p
end

--- How many colours `mid`'s under art uses; nil without CPU pixels.
function Cutouts:colourCount(view, mid)
  local set = self:keySet(view, mid)
  if not set then return nil end
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

--- How much of `mid`'s under art is the key's colours, 0..1; nil when the
-- pixels are not available.
function Cutouts:fraction(view, mid, keyMid)
  if mid == nil or not view.imageData then return nil end
  local k = view.pair .. "|" .. mid .. "|" .. tostring(keyMid)
  local f = self.fractions[k]
  if f then return f end
  local set = self:keySet(view, keyMid)
  local ox, oy = view.origin(mid)
  if not (set and ox) then return nil end
  local data, n = view.imageData, 0
  for y = 0, 15 do
    for x = 0, 15 do
      local r, g, b = data:getPixel(ox + x, oy + y)
      if set[pack(r, g, b)] then n = n + 1 end
    end
  end
  f = n / 256
  self.fractions[k] = f
  return f
end

--- The same, of `mid` as the field shows it (its overhead layer over its
-- under layer): for a tile drawn on the overhead layer over plain ground.
function Cutouts:compositeFraction(view, mid, keyMid)
  if mid == nil or not view.imageData then return nil end
  local k = view.pair .. "|c" .. mid .. "|" .. tostring(keyMid)
  local f = self.fractions[k]
  if f then return f end
  local set = self:keySet(view, keyMid)
  local p = self:composite(view, mid)
  if not (set and p) then return nil end
  local n = 0
  for i = 0, 255 do
    if set[p[i]] then n = n + 1 end
  end
  f = n / 256
  self.fractions[k] = f
  return f
end

local function newPage()
  local data = love.image.newImageData(PAGE, PAGE)
  local image = love.graphics.newImage(data)
  image:setFilter("nearest", "nearest")
  return { data = data, image = image, dirty = false }
end

-- Replace every key pixel by its nearest art pixel, growing the art
-- outwards one ring at a time.  A cell that is all key stays as it is.
local function fill(px, key)
  local any = false
  for i = 0, 255 do
    if not key[i] then any = true break end
  end
  if not any then return end
  local pending = true
  while pending do
    pending = false
    local grow = {}
    for i = 0, 255 do
      if key[i] then
        local x, y = i % 16, math.floor(i / 16)
        local from
        if x > 0 and not key[i - 1] then from = i - 1
        elseif x < 15 and not key[i + 1] then from = i + 1
        elseif y > 0 and not key[i - 16] then from = i - 16
        elseif y < 15 and not key[i + 16] then from = i + 16 end
        if from then grow[#grow + 1] = { i, from } else pending = true end
      end
    end
    if #grow == 0 then break end
    for _, g in ipairs(grow) do
      px[g[1]] = px[g[2]]
      key[g[1]] = false
    end
  end
end

-- keep only the key pixels joined (4-connected, within the cell) to an open
-- edge; `open` is a mask: 1 north, 2 east, 4 south, 8 west
local function trim(key, open)
  local cut, queue, n = {}, {}, 0
  local function seed(i)
    if key[i] and not cut[i] then
      cut[i] = true
      n = n + 1
      queue[n] = i
    end
  end
  for t = 0, 15 do
    if open % 2 == 1 then seed(t) end
    if math.floor(open / 2) % 2 == 1 then seed(t * 16 + 15) end
    if math.floor(open / 4) % 2 == 1 then seed(240 + t) end
    if math.floor(open / 8) % 2 == 1 then seed(t * 16) end
  end
  local head = 1
  while head <= n do
    local i = queue[head]
    head = head + 1
    local x = i % 16
    if x > 0 then seed(i - 1) end
    if x < 15 then seed(i + 1) end
    if i >= 16 then seed(i - 16) end
    if i < 240 then seed(i + 16) end
  end
  for i = 0, 255 do key[i] = cut[i] == true end
end

-- The overhead layer's pixels on the CPU: the atlas view's own when the
-- engine gives them (view.overImageData), else read back once from its
-- image.  Keyed by the image: tileset animation swaps images, not pixels.
local overs = setmetatable({}, { __mode = "k" })
function Cutouts.overData(view)
  if view.overImageData then return view.overImageData end
  local img = view.overImage
  if not img then return nil end
  local d = overs[img]
  if d ~= nil then return d or nil end
  overs[img] = false
  local G = love and love.graphics
  if not (G and G.newCanvas and img.getDimensions) then return nil end
  local ok, data = pcall(function()
    local w, h = img:getDimensions()
    local cv = G.newCanvas(w, h, { dpiscale = 1 })
    G.push("all")
    G.setCanvas(cv)
    G.origin()
    G.setScissor()
    G.setShader()
    G.clear(0, 0, 0, 0)
    G.setBlendMode("replace", "premultiplied")
    G.setColor(1, 1, 1, 1)
    G.draw(img, 0, 0)
    G.pop()
    local out = cv:newImageData()
    cv:release()
    return out
  end)
  if ok and data then
    overs[img] = data
    return data
  end
  return nil
end

--- The processed copy of `mid` keyed by `keyMid` in `mode` ("cut", "tree",
-- "fill" or "trim" plus its open-edge mask, e.g. "trim5"): page number and
-- the pixel origin of its 16x16 cell, or nil when the pixels are not
-- available (the caller then draws the plain atlas art).
function Cutouts:resolve(view, mid, keyMid, mode)
  if mid == nil or not view.imageData then return nil end
  local k = view.pair .. "|" .. mode .. "|" .. mid .. "|" .. tostring(keyMid)
  local slot = self.slots[k]
  if slot then return slot.page, slot.x, slot.y end
  local ox, oy = view.origin(mid)
  if not ox then return nil end
  local set = self:keySet(view, keyMid) or {}

  local n = self.used
  local pageNo = math.floor(n / PER_PAGE) + 1
  local within = n % PER_PAGE
  local page = self.pages[pageNo]
  if not page then
    page = newPage()
    self.pages[pageNo] = page
  end
  local sx, sy = (within % PER_ROW) * 16, math.floor(within / PER_ROW) * 16
  self.used = n + 1

  local data = view.imageData
  local px, key = {}, {}
  for y = 0, 15 do
    for x = 0, 15 do
      local r, g, b, a = data:getPixel(ox + x, oy + y)
      local i = y * 16 + x
      px[i] = { r, g, b, a }
      key[i] = set[pack(r, g, b)] == true
    end
  end
  if mode == "roof" or mode == "roofo" then
    local over = Cutouts.overData(view)
    -- (a walkable cell's under layer is all ground, whatever its colours:
    -- the grass beside a path along a roof's top row is no roof either)
    if over and mode == "roofo" then
      for i = 0, 255 do key[i] = true end
    end
    if over then
      for y = 0, 15 do
        for x = 0, 15 do
          local r, g, b, a = over:getPixel(ox + x, oy + y)
          if a > 0.5 then
            local i = y * 16 + x
            px[i] = { r, g, b, 1 }
            key[i] = false
          end
        end
      end
    end
    fill(px, key)
    key = {}
  elseif mode == "fill" then
    fill(px, key)
    key = {}
  elseif mode == "tree" then
    growKin(px, key, self:bandOf(view, keyMid))
    -- (only the ground that reaches the cell's edge: what the art encloses
    -- in the key's colours is the thing's own, a highlight on a rock drawn
    -- in the ground's colours, as Sootopolis's are)
    trim(key, 15)
  elseif mode:sub(1, 4) == "trim" then
    trim(key, tonumber(mode:sub(5)) or 15)
  end
  local out = page.data
  for i = 0, 255 do
    local c = px[i]
    if key[i] then
      out:setPixel(sx + i % 16, sy + math.floor(i / 16), 0, 0, 0, 0)
    else
      out:setPixel(sx + i % 16, sy + math.floor(i / 16), c[1], c[2], c[3], c[4])
    end
  end
  page.dirty = true
  slot = { page = pageNo, x = sx, y = sy }
  self.slots[k] = slot
  return pageNo, sx, sy
end

--- Upload the pages that changed since the last frame.
function Cutouts:flush()
  for _, p in ipairs(self.pages) do
    if p.dirty then
      p.image:replacePixels(p.data)
      p.dirty = false
    end
  end
end

function Cutouts:image(pageNo)
  local p = self.pages[pageNo]
  return p and p.image or nil
end

Cutouts.PAGE = PAGE

return Cutouts
