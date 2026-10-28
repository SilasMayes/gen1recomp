-- A structure as a solid, read off its own drawing.
--
-- Hoenn's art is an oblique projection: a point (x, y, z) of the world lands
-- on the drawing at u = x, v = z - y, which is what a camera at 45 degrees
-- sees.  So a face can be textured with the drawing *projected* onto it
-- (each point takes the pixel its projection falls on), and it shows the
-- drawing exactly at 45 degrees whatever its shape.  That frees the shape to
-- be the structure's own.  Two shapes:
--
-- "hip"  a building (it has a door): walls of height `hw` round its whole
--        collision footprint and a roof hipped on all four sides, its ridge
--        over the middle of the footprint.  The slope is the one that puts
--        the drawing's top row on the ridge, so the drawn roof covers the
--        front half exactly.  Every roof slope is under 45 degrees, so at 45
--        degrees every point of the roof is seen and the view is the drawing
--        exactly; past the drawing's top row the camera sees the back of the
--        roof, which takes the front's texels mirrored about the ridge (the
--        drawing has no back to show, and a mirror never stretches a texel).
-- "flat" anything else that stands (a cliff, a rock, a fence, a tower): a
--        flat top at `hw` with the drawing projected on it, and behind it a
--        back plane at exactly 45 degrees, edge-on to the 45 degree camera and
--        facing away from every lower one, down to the footprint's back.
--
-- A two-storey house (Littleroot's) draws its upper storey's front as a band
-- of wall across the roof's middle.  Given that band (`b.tier`), the hip is
-- two: a skirt round the whole footprint rising to an inset upper storey,
-- whose walls stand as high as the band and carry their own hipped roof to
-- the ridge.  Every face still takes the drawing projected.
--
-- A building in the profile (data/buildings.lua, lib/Buildings.lua) may say
-- more: where its drawing shows the ridge (`b.ridge`: the solid is then as
-- deep as the drawing makes it, its back slope drawn, not mirrored), or that
-- its roof is drawn from straight above (`b.flatRoof`: a flat top at the
-- walls' height, as deep as the drawing).
--
-- Faces nobody sees at 45 degrees are dressed from the art too: side walls
-- repeat a plain stretch of the facade (each height takes the facade's row
-- at that height), never one column smeared along the wall (Shape.lua).
--
-- The approach follows Emerald 3DS's building models (ZallaxDev/emerald-3ds,
-- MIT): the drawing as an oblique projection, projected faces wherever the
-- 45 degree view looks, real footprint depth, hipped roofs, sides dressed
-- from a plain stretch.  Its models are written by hand per building; this
-- reads every building the same way.
--
-- Pure Lua.  Coordinates are world pixels: x east, y up, z south.
local Hip = {}

-- the slopes a hipped roof may take (rise per pixel), and the lowest wall
local T_MIN, T_MAX, HW_MIN = 0.2, 1.2, 8
Hip.T_MIN, Hip.T_MAX = T_MIN, T_MAX
-- a roof whose drawing is too short for its footprint's depth (all its
-- rows collision: Verdanturf's contest hall, a shop at a map's top edge)
-- would come out flatter than this; the solid stands only as deep as the
-- drawing makes it at this slope instead, the collision behind it open
local T_LOW, DEPTH_MIN = 0.45, 16
Hip.T_LOW = T_LOW

local function clip(poly, f)
  -- keep the part of a convex polygon where f(p) <= 0 (f affine)
  local out, n = {}, #poly
  if n == 0 then return out end
  for i = 1, n do
    local a, b = poly[i], poly[i % n + 1]
    local fa, fb = f(a), f(b)
    if fa <= 0 then out[#out + 1] = a end
    if (fa < 0 and fb > 0) or (fa > 0 and fb < 0) then
      local s = fa / (fa - fb)
      local p = {}
      for k = 1, #a do p[k] = a[k] + (b[k] - a[k]) * s end
      out[#out + 1] = p
    end
  end
  return out
end
Hip.clip = clip

-- drop vertices that repeat (clipping along an edge leaves doubles)
local function same(p, q)
  for k = 1, #p do
    if math.abs(p[k] - q[k]) > 1e-6 then return false end
  end
  return true
end

local function tidy(poly)
  local out = {}
  for i = 1, #poly do
    local p, q = poly[i], out[#out]
    if not q or not same(p, q) then out[#out + 1] = p end
  end
  while #out > 1 and same(out[1], out[#out]) do out[#out] = nil end
  return out
end

local function area(poly)
  local s = 0
  for i = 1, #poly do
    local a, b = poly[i], poly[i % #poly + 1]
    s = s + a[1] * b[2] - b[1] * a[2]
  end
  return s / 2
end
Hip.area = area

local ORDER = { "front", "back", "west", "east" }

--- The block's geometry.  `b` = { x0, x1 (west and east edges), zf (front
-- edge), zb (back edge of the collision), vt (the drawing's top row, as v),
-- hw (wall height asked for), building (true: a hipped roof), tier (optional:
-- { vtop, vb, inset }, the upper storey's band, as v, and how far in from the
-- sides the drawing sets it), ridge (optional: the drawn ridge line, as v),
-- flatRoof (optional: true for a roof drawn from above) }.  Fills in:
--   b.kind    "hip" or "flat"
--   b.hw, b.t the wall height and roof slope it settled on
--   b.zr      the ridge (hip)
--   b.zlo     the back of the solid
--   b.open    true when the solid stops short of the collision's back (b.zb
--             moved forward): the ground behind it is open
--   b.drawn   true when the slope and depth came from a drawn ridge
--   b.planes  { name = { a, bx, bz } }: height y = a + bx x + bz z
--   b.roof    { name = polygon of {x, z} }, the part of the footprint each
--             roof plane is the top of
--   b.faces   { { name, plane, foot } }: every roof face, in drawing order
--   b.upper   (two storeys) { x0, x1, zf, zb, y0, y1 }: the upper storey
local function hipFaces(x0, x1, zf, zb, hw, t)
  local planes = {
    front = { hw + t * zf, 0, -t },
    back = { hw - t * zb, 0, t },
    west = { hw - t * x0, t, 0 },
    east = { hw + t * x1, -t, 0 },
  }
  local foot = { { x0, zb }, { x1, zb }, { x1, zf }, { x0, zf } }
  local roof = {}
  for _, name in ipairs(ORDER) do
    local pl = planes[name]
    local poly = foot
    for _, other in ipairs(ORDER) do
      local ql = planes[other]
      if other ~= name then
        -- this plane is the lowest (ties go to the one named first)
        local da, dx, dz = pl[1] - ql[1], pl[2] - ql[2], pl[3] - ql[3]
        local first = false
        for _, n in ipairs(ORDER) do
          if n == name then first = true break end
          if n == other then break end
        end
        local eps = first and 0 or 1e-9
        poly = clip(poly, function(p) return da + dx * p[1] + dz * p[2] + eps end)
      end
    end
    poly = tidy(poly)
    if #poly >= 3 and math.abs(area(poly)) > 1e-6 then roof[name] = poly end
  end
  return planes, roof
end

-- the two storeys of b, or nil when the drawing's band cannot be stood up
-- with sensible slopes
local function storeys(b)
  local tr = b.tier
  local D, W = b.zf - b.zb, b.x1 - b.x0
  local L1 = (b.zf - b.hw) - tr.vb     -- the skirt's rows, under the band
  local L2 = tr.vtop - b.vt            -- the upper roof's rows, over it
  local bh = tr.vb - tr.vtop           -- the band: the upper walls' height
  if L1 < 3 or L2 < 6 or bh < 3 then return nil end
  -- the skirt's front: half as steep as deep; its sides as far in as the
  -- drawing sets the band, rising as much
  local tf = 0.5
  local df = L1 / (1 + tf)
  local rise = tf * df
  local ds = math.max(df, math.min(tr.inset or df, W / 4))
  local ts = rise / ds
  local u = { x0 = b.x0 + ds, x1 = b.x1 - ds, zf = b.zf - df, zb = b.zb + df,
    y0 = b.hw + rise, y1 = b.hw + rise + bh }
  local D2 = u.zf - u.zb
  if D2 < 16 or u.x1 - u.x0 < 16 then return nil end
  local t2 = 2 * L2 / D2 - 1
  if t2 < T_MIN or t2 > T_MAX then return nil end
  return u, tf, ts, t2
end

-- A drawing that shows its ridge (b.ridge, as v) and its back slope above it
-- (the building profile, data/buildings.lua): with level eaves both slopes
-- are as steep, so the drawing fixes the depth, Pf + Pb, and the slope,
-- (Pf - Pb) / (Pf + Pb), where Pf and Pb are the rows the front and back
-- slopes take.  The back slope then takes the drawing as drawn, nothing is
-- mirrored, and the collision behind it is open.  nil when that solid does
-- not fit the footprint or would be too flat or too steep.
local function drawnRidge(b)
  local hw = b.hw
  local Pf, Pb = (b.zf - hw) - b.ridge, b.ridge - b.vt
  local D2 = Pf + Pb
  if Pf <= 0 or Pb <= 0 or hw < HW_MIN or D2 < DEPTH_MIN then return nil end
  if D2 > b.zf - b.zb + 0.5 then return nil end
  local t = (Pf - Pb) / D2
  if t < T_MIN or t > T_MAX then return nil end
  return D2, t
end

function Hip.block(b)
  local A, D = b.zf - b.vt, b.zf - b.zb
  b.kind = "flat"
  if b.building and b.flatRoof then
    -- a roof drawn from straight above (the profile): a flat top at the
    -- walls' height as deep as the drawing makes it, a back wall under its
    -- back edge, the collision behind it open
    local zlo = b.vt + b.hw
    if zlo > b.zb + 0.5 and b.zf - zlo >= DEPTH_MIN then b.zb, b.open = zlo, true end
  elseif b.building and b.ridge and D > 0 and drawnRidge(b) then
    local D2, t = drawnRidge(b)
    if D2 < D - 0.5 then b.zb, b.open = b.zf - D2, true end
    b.kind, b.t, b.drawn = "hip", t, true
  elseif b.building and D > 0 then
    -- the slope that lays the drawn roof over the front half exactly
    local hw = b.hw
    local t = 2 * (A - hw) / D - 1
    if t < T_LOW and not b.tier then
      local D2 = 2 * (A - hw) / (1 + T_LOW)
      if D2 >= DEPTH_MIN and hw >= HW_MIN then
        b.zb, D, t = b.zf - D2, D2, T_LOW
        b.open = true
      end
    end
    if t < T_MIN then hw, t = A - D * (1 + T_MIN) / 2, T_MIN end
    if t > T_MAX then hw, t = A - D * (1 + T_MAX) / 2, T_MAX end
    if hw >= HW_MIN and hw <= A - 4 then
      b.kind, b.hw, b.t = "hip", hw, t
    elseif b.tier then
      b.kind, b.t = "hip", T_MIN
    end
  end
  local hw = b.hw
  if b.kind == "hip" then
    b.zr = (b.zf + b.zb) / 2
    b.zlo = b.zb
    local u, tf, ts, t2
    if b.tier then u, tf, ts, t2 = storeys(b) end
    if u then
      -- the skirt, then the upper storey's hipped roof
      b.upper, b.t = u, t2
      b.planes, b.roof = hipFaces(u.x0, u.x1, u.zf, u.zb, u.y1, t2)
      local rise = u.y0 - hw
      b.skirt = {
        front = { hw + tf * b.zf, 0, -tf },
        back = { hw - tf * b.zb, 0, tf },
        west = { hw - ts * b.x0, ts, 0 },
        east = { hw + ts * b.x1, -ts, 0 },
      }
      local skirtFoot = {
        front = { { b.x0, b.zf }, { u.x0, u.zf }, { u.x1, u.zf }, { b.x1, b.zf } },
        back = { { b.x0, b.zb }, { b.x1, b.zb }, { u.x1, u.zb }, { u.x0, u.zb } },
        west = { { b.x0, b.zb }, { u.x0, u.zb }, { u.x0, u.zf }, { b.x0, b.zf } },
        east = { { b.x1, b.zb }, { b.x1, b.zf }, { u.x1, u.zf }, { u.x1, u.zb } },
      }
      b.faces = {}
      for _, name in ipairs(ORDER) do
        b.faces[#b.faces + 1] = { name = name, plane = b.skirt[name], foot = skirtFoot[name], skirt = true }
      end
      for _, name in ipairs(ORDER) do
        if b.roof[name] then
          b.faces[#b.faces + 1] = { name = name, plane = b.planes[name], foot = b.roof[name] }
        end
      end
      b.rise = rise
      return b
    end
    b.planes, b.roof = hipFaces(b.x0, b.x1, b.zf, b.zb, hw, b.t)
  else
    b.t = 0
    b.zlo = math.min(b.zb, b.vt + hw)
    b.planes = { front = { hw, 0, 0 }, back = { -b.vt, 0, 1 } }
    local foot = { { b.x0, b.zlo }, { b.x1, b.zlo }, { b.x1, b.zf }, { b.x0, b.zf } }
    b.roof = {}
    for _, name in ipairs({ "front", "back" }) do
      local pl = b.planes[name]
      local other = b.planes[name == "front" and "back" or "front"]
      local da, dx, dz = pl[1] - other[1], pl[2] - other[2], pl[3] - other[3]
      local eps = name == "front" and 0 or 1e-9
      local poly = tidy(clip(foot, function(p) return da + dx * p[1] + dz * p[2] + eps end))
      if #poly >= 3 and math.abs(area(poly)) > 1e-6 then b.roof[name] = poly end
    end
  end
  b.faces = {}
  for _, name in ipairs(ORDER) do
    if b.roof[name] then
      b.faces[#b.faces + 1] = { name = name, plane = b.planes[name], foot = b.roof[name] }
    end
  end
  return b
end

function Hip.height(b, x, z)
  local planes = b.planes
  local u = b.upper
  if u and not (x > u.x0 and x < u.x1 and z > u.zb and z < u.zf) then planes = b.skirt end
  local h = math.huge
  for _, pl in pairs(planes) do
    h = math.min(h, pl[1] + pl[2] * x + pl[3] * z)
  end
  return h
end

-- a point of a roof plane from its projection (u, v): x = u, v = z - y
local function onPlane(pl, u, v)
  local z = (v + pl[1] + pl[2] * u) / (1 - pl[3])
  return u, z - v, z
end

-- the faces the 45 degree camera sees with the drawing on them
local SEEN = { hip = { "front", "back", "west", "east" }, flat = { "front" } }

--- The pieces whose texels come from drawing cell (cx, cy): a list of
-- { face, mirror, poly = { {x, y, z, s, t}, ... } } with (s, t) the texel
-- inside the cell, 0..16.  The faces are the front wall (z = zf, up to hw)
-- and the roof faces the 45 degree camera sees, each where its projection
-- falls in the cell; a hipped roof also gives the mirror image of those
-- pieces behind the ridge, where they fall past the drawing's top row.
-- `drop` takes the wall down below the ground (to the water line); the
-- bottom row of cells carries it.
function Hip.pieces(b, cx, cy, C, drop)
  local u0, v0 = cx * C, cy * C
  local u1, v1 = u0 + C, v0 + C
  local function square(poly)
    poly = clip(poly, function(p) return u0 - p[1] end)
    poly = clip(poly, function(p) return p[1] - u1 end)
    poly = clip(poly, function(p) return v0 - p[2] end)
    poly = clip(poly, function(p) return p[2] - v1 end)
    return tidy(poly)
  end
  local out = {}
  -- the front wall: v = zf - y
  do
    -- (a hair taller than the eaves, tucked under the roof, so no pinhole
    -- opens where the wall, a side and the roof meet)
    local top = b.zf - b.hw - 0.1
    local wall = { { b.x0, top }, { b.x1, top }, { b.x1, b.zf }, { b.x0, b.zf } }
    local poly = square(wall)
    if #poly >= 3 then
      local verts = {}
      for i, p in ipairs(poly) do
        verts[i] = { p[1], b.zf - p[2], b.zf, p[1] - u0, p[2] - v0 }
      end
      out[#out + 1] = { face = "wall", poly = verts }
    end
    -- below the ground: the bottom row of art, run down to the water line
    if drop and drop > 0 and math.abs(v1 - b.zf) < 1e-6 then
      local xa, xb = math.max(u0, b.x0), math.min(u1, b.x1)
      if xb > xa then
        out[#out + 1] = { face = "foot", poly = {
          { xa, 0, b.zf, xa - u0, C - 0.5 }, { xb, 0, b.zf, xb - u0, C - 0.5 },
          { xb, -drop, b.zf, xb - u0, C - 0.5 }, { xa, -drop, b.zf, xa - u0, C - 0.5 } } }
      end
    end
  end
  -- a face given as its projection and the way back from it; a hipped
  -- solid also takes, behind its ridge, the mirror image of what the
  -- drawing gives its front
  local function face(name, proj, back)
    local poly = square(proj)
    if #poly < 3 or math.abs(area(poly)) <= 1e-6 then return end
    local verts = {}
    for i, p in ipairs(poly) do
      local x, y, z = back(p[1], p[2])
      verts[i] = { x, y, z, p[1] - u0, p[2] - v0 }
    end
    out[#out + 1] = { face = name, poly = verts }
    if b.kind == "hip" then
      -- the same texels mirrored about the ridge, where that falls past
      -- the drawing's top row (z - y < vt)
      local m = {}
      for i, v in ipairs(verts) do m[i] = { v[1], v[2], 2 * b.zr - v[3], v[4], v[5] } end
      m = tidy(clip(m, function(p) return (p[3] - p[2]) - b.vt end))
      if #m >= 3 then
        local mirrored = { front = "back", back = "front", west = "west", east = "east", upper = "upper" }
        out[#out + 1] = { face = mirrored[name], mirror = true, poly = m }
      end
    end
  end
  local seen = SEEN[b.kind]
  for _, f in ipairs(b.faces) do
    local ok = false
    for _, n in ipairs(seen) do if n == f.name then ok = true end end
    if ok then
      local pl = f.plane
      local proj = {}
      for i, p in ipairs(f.foot) do
        local x, z = p[1], p[2]
        local y = pl[1] + pl[2] * x + pl[3] * z
        proj[i] = { x, z - y }
      end
      face(f.name, proj, function(u, v) return onPlane(pl, u, v) end)
    end
  end
  -- the upper storey's front wall, a hair taller than its eaves
  local up = b.upper
  if up then
    local zf, y0, y1 = up.zf, up.y0, up.y1 + 0.1
    face("upper", { { up.x0, zf - y1 }, { up.x1, zf - y1 }, { up.x1, zf - y0 }, { up.x0, zf - y0 } },
      function(u, v) return u, zf - v, zf end)
  end
  return out
end

--- The flat block's back plane, behind the drawing's top: polygon of
-- {x, y, z}, or nil (a hipped roof has none; its back is mirrored).
function Hip.back(b)
  if b.kind ~= "flat" then return nil end
  local foot = b.roof.back
  if not foot then return nil end
  local pl = b.planes.back
  local out = {}
  for i, p in ipairs(foot) do
    out[i] = { p[1], pl[1] + pl[2] * p[1] + pl[3] * p[2], p[2] }
  end
  return out
end

--- How high a side wall is at depth z (the eave, or the flat block's back
-- plane where that is lower).
function Hip.sideTop(b, z)
  if b.kind == "flat" then return math.min(b.hw, z - b.vt) end
  return b.hw
end

--- The back wall (z = b.zlo): its height, or nil.
function Hip.backWall(b)
  if b.kind == "hip" then return b.hw end
  local h = b.zlo - b.vt
  if h <= 1e-6 then return nil end
  return math.min(h, b.hw)
end

return Hip
