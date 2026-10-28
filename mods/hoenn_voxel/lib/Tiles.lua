-- What each metatile is drawn as, read once off its pixels: plain numbers a
-- reader (or a background job) can use without touching the GPU.
--
--   cls       256 chars, "T" rock top or rim, "F" rock face, "G" anything else
--   t, f      shares of the tile drawn as top / as face
--   faceLow   face pixels in rows 2..15
--   rim       rim-coloured pixels in rows 0..5;  gTop  "G" pixels in rows 0..3
--   leafU, leafO  shares of the under / over layer drawn in leaf green
--   cover     share of the over layer that is opaque
--   flat      true for a tile of one colour
local lib = ...
local Pixels = lib("Pixels")
local T = lib("data/terrain")

local Tiles = {}

local function colourSet(list)
  local s = {}
  for _, c in ipairs(list) do s[Pixels.key(c[1], c[2], c[3])] = true end
  return s
end
local TOP = colourSet(T.TOP)
local RIM = colourSet(T.RIM)
local FACE = colourSet(T.FACE)
local FLECK = colourSet(T.FLECK)
for k in pairs(RIM) do TOP[k] = true end

local function leafy(r, g, b)
  return g > 1.10 * r and g > 1.35 * b and g >= 6
end

local memo = {}

local function read(pair, mid)
  local u = Pixels.tile(pair, mid, "under")
  if not u then return nil end
  local o = Pixels.tile(pair, mid, "over")
  local cls = {}
  local flecks = {}
  local first, one = nil, true
  for i = 1, 256 do
    local k = Pixels.key(u.r[i], u.g[i], u.b[i])
    if first == nil then first = k elseif k ~= first then one = false end
    if TOP[k] then cls[i] = "T"
    elseif FACE[k] then cls[i] = "F"
    elseif FLECK[k] then cls[i] = "?"; flecks[#flecks + 1] = i
    else cls[i] = "G" end
  end
  -- a fleck goes with the most of its neighbours that are rock
  for _, i in ipairs(flecks) do
    local x, y = (i - 1) % 16, math.floor((i - 1) / 16)
    local nt, nf = 0, 0
    for dy = -1, 1 do
      for dx = -1, 1 do
        local nx, ny = x + dx, y + dy
        if nx >= 0 and ny >= 0 and nx < 16 and ny < 16 then
          local c = cls[ny * 16 + nx + 1]
          if c == "T" then nt = nt + 1 elseif c == "F" then nf = nf + 1 end
        end
      end
    end
    cls[i] = (nf > nt) and "F" or "T"
  end
  local s = { t = 0, f = 0, faceLow = 0, rim = 0, gTop = 0, leafU = 0, leafO = 0, cover = 0 }
  for i = 1, 256 do
    local c = cls[i]
    local y = math.floor((i - 1) / 16)
    if c == "T" then s.t = s.t + 1 elseif c == "F" then s.f = s.f + 1 end
    if c == "F" and y >= 2 then s.faceLow = s.faceLow + 1 end
    if c == "G" and y < 4 then s.gTop = s.gTop + 1 end
    if y < 6 and RIM[Pixels.key(u.r[i], u.g[i], u.b[i])] then s.rim = s.rim + 1 end
    if u.a[i] == 1 and leafy(u.r[i], u.g[i], u.b[i]) then s.leafU = s.leafU + 1 end
    if o and o.a[i] == 1 then
      s.cover = s.cover + 1
      if leafy(o.r[i], o.g[i], o.b[i]) then s.leafO = s.leafO + 1 end
    end
  end
  s.leafO = s.cover > 0 and s.leafO / s.cover or 0
  s.t, s.f = s.t / 256, s.f / 256
  s.leafU = s.leafU / 256
  s.cover = s.cover / 256
  -- a tile of one flat colour is no face (a face is always textured)
  if one and mid >= 0x200 then
    local all = FACE[first] and "T" or "G"
    for i = 1, 256 do cls[i] = all end
    s.t = all == "T" and 1 or 0
    s.f, s.faceLow = 0, 0
  end
  s.flat = one
  s.cls = table.concat(cls)
  return s
end

--- The reading of a metatile of a pair, or nil while the pair streams in.
function Tiles.get(pair, mid)
  local byPair = memo[pair]
  if not byPair then byPair = {}; memo[pair] = byPair end
  local s = byPair[mid]
  if s == nil then
    s = read(pair, mid)
    if s == nil then return nil end
    byPair[mid] = s
  end
  return s
end

function Tiles.forget() memo = {} end

return Tiles
