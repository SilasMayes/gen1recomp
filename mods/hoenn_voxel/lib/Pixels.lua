-- The pixels of the player's ROM, as the engine baked them into its atlases,
-- read once per metatile and kept.  A tile is 256 pixels, each four numbers
-- in GBA terms: 5-bit red, green, blue and an opaque flag.  Everything the
-- mod derives from art (what a tile is drawn as, where a canopy ends, the
-- colour of an edge) reads it through here.
local lib = ...
local Source = lib("Source")

local Pixels = {}

local tiles = {}        -- pair -> layer -> mid -> tile (false: none)
local readback = {}     -- pair -> layer -> ImageData read back off the GPU

local function dataOf(view, layer)
  if layer == "under" then return view.imageData end
  if view.overImageData then return view.overImageData end
  -- an engine that keeps no CPU copy of the over layer: read it back once
  local img = view.overImage
  if not img then return nil end
  local per = readback[view.pair]
  if not per then per = {}; readback[view.pair] = per end
  local d = per[img]
  if d then return d end
  if not (love and love.graphics and love.graphics.newCanvas) then return nil end
  local w, h = img:getDimensions()
  local canvas = love.graphics.newCanvas(w, h, { dpiscale = 1 })
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setBlendMode("replace")
  love.graphics.origin()
  love.graphics.setShader()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(img, 0, 0)
  love.graphics.pop()
  d = canvas:newImageData()
  canvas:release()
  per[img] = d
  return d
end

--- The 256 pixels of a metatile's layer ("under" or "over"), or nil while
-- the pair streams in.  t.r[i], t.g[i], t.b[i] are 0..31, t.a[i] 0 or 1,
-- i = y * 16 + x + 1.  t.opaque counts the opaque pixels.
function Pixels.tile(pair, mid, layer)
  layer = layer or "under"
  local byPair = tiles[pair]
  if not byPair then byPair = { under = {}, over = {} }; tiles[pair] = byPair end
  local t = byPair[layer][mid]
  if t ~= nil then return t or nil end
  local view = Source.atlas(pair)
  if not view then return nil end
  if not view.slot(mid) then byPair[layer][mid] = false return nil end
  local data = dataOf(view, layer)
  if not data then return nil end
  local ox, oy = view.origin(mid)
  local r, g, b, a = {}, {}, {}, {}
  local opaque = 0
  for y = 0, 15 do
    for x = 0, 15 do
      local pr, pg, pb, pa = data:getPixel(ox + x, oy + y)
      local i = y * 16 + x + 1
      r[i] = math.floor(pr * 31 + 0.5)
      g[i] = math.floor(pg * 31 + 0.5)
      b[i] = math.floor(pb * 31 + 0.5)
      a[i] = pa >= 0.5 and 1 or 0
      opaque = opaque + a[i]
    end
  end
  t = { r = r, g = g, b = b, a = a, opaque = opaque }
  byPair[layer][mid] = t
  return t
end

--- One colour key (5-bit r, g, b packed) for set lookups.
function Pixels.key(r, g, b)
  return r * 1024 + g * 32 + b
end

function Pixels.forget(pair)
  if pair then tiles[pair] = nil; readback[pair] = nil
  else tiles = {}; readback = {} end
end

return Pixels
