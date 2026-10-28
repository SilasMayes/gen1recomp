-- The relief: what height every drawn point stands at.
--
-- The whole mod rests on one identity (the one Emerald 3DS builds on): a
-- point the game draws at (u, v) - world pixels, v down the screen - that
-- stands h pixels high is placed at
--
--     (x, y, z) = (u, h, v + h)          x east, y up, z south
--
-- and a camera looking north and down at 45 degrees sees it at (u, v) again,
-- whatever h is.  So every surface is textured with the drawing at
-- (x, z - y), the heights decide only what the scene does away from 45
-- degrees, and no choice of heights can make the 45-degree view wrong.
--
-- A cell's relief is its four corner heights (pixels) and the diagonal its
-- two triangles are split along: every piece the tilesets draw a mountain
-- with is one of those (a top, a face, a band, a corner), so a cell is never
-- bent or stretched.  Where two cells' edges differ the builder closes the
-- step (Builder.lua); the relief never has to.
local Relief = {}

Relief.LEVEL = 16

-- corners NW, NE, SW, SE in levels under the piece's top (Emerald 3DS's
-- BY_CORNERS), and the diagonal its crease runs along ("main" NW-SE,
-- "anti" NE-SW)
Relief.PIECES = {
  F    = { 0, 0, 0, 0 },          -- a top: level all over
  S    = { 0, 0, -1, -1 },        -- a face: vertical, one level
  E    = { 0, -1, 0, -1 },        -- a band falling east (high side west)
  W    = { -1, 0, -1, 0 },        -- a band falling west (high side east)
  E2   = { 0, -2, 0, -2 },
  W2   = { -2, 0, -2, 0 },
  cSE  = { 0, -1, -1, -1 },       -- a face and a band meeting, convex
  cSW  = { -1, 0, -1, -1 },
  vSE  = { 0, 0, 0, -1 },         -- ... concave
  vSW  = { 0, 0, -1, 0 },
}

local function crease(nw, ne, sw, se)
  return math.abs(nw - se) >= math.abs(ne - sw) and "main" or "anti"
end
Relief.crease = crease

--- A relief record for a piece standing with its top at `top` pixels;
-- `drop` overrides the level a piece falls (a fall shared between rows).
function Relief.piece(kind, top, drop)
  local p = Relief.PIECES[kind] or Relief.PIECES.F
  local L = drop or Relief.LEVEL
  local nw, ne, sw, se = top + p[1] * L, top + p[2] * L, top + p[3] * L, top + p[4] * L
  return { nw = nw, ne = ne, sw = sw, se = se, crease = crease(nw, ne, sw, se), kind = kind, top = top }
end

--- A record from corners.
function Relief.corners(nw, ne, sw, se, kind)
  return { nw = nw, ne = ne, sw = sw, se = se, crease = crease(nw, ne, sw, se), kind = kind,
    top = math.max(nw, ne, sw, se) }
end

Relief.FLAT = Relief.corners(0, 0, 0, 0, "F")

local flats = { [0] = Relief.FLAT }
--- A flat record at height h (shared: never mutate one).
function Relief.flat(h)
  local r = flats[h]
  if not r then r = Relief.corners(h, h, h, h, "F"); flats[h] = r end
  return r
end

--- Height at (fu, fv) in 0..1 across the cell, on its two triangles.
function Relief.at(r, fu, fv)
  if r.prof then
    return Relief.interp(r.prof.pts, (r.prof.axis == "v" and fv or fu) * 16)
  end
  local nw, ne, sw, se = r.nw, r.ne, r.sw, r.se
  if r.crease == "main" then
    if fu >= fv then return nw + (ne - nw) * fu + (se - ne) * fv end
    return nw + (sw - nw) * fv + (se - sw) * fu
  end
  if fu + fv <= 1 then return nw + (ne - nw) * fu + (sw - nw) * fv end
  return se + (sw - se) * (1 - fu) + (ne - se) * (1 - fv)
end

function Relief.isFlat(r)
  return not r.prof and r.nw == r.ne and r.ne == r.sw and r.sw == r.se
end

--- A profile: heights along one axis of the cell, the same across the
-- other ("v": along the drawn rows, a ledge falling south; "u": along the
-- columns).  pts = { { t, h }, ... } with t from 0 to 16.
function Relief.profile(axis, pts, kind)
  local first, last = pts[1][2], pts[#pts][2]
  local r
  if axis == "v" then
    r = Relief.corners(first, first, last, last, kind)
  else
    r = Relief.corners(first, last, first, last, kind)
  end
  local top = first
  for _, p in ipairs(pts) do if p[2] > top then top = p[2] end end
  r.top = top
  r.prof = { axis = axis, pts = pts }
  return r
end

local function interp(pts, t)
  for i = 1, #pts - 1 do
    local a, b = pts[i], pts[i + 1]
    if t <= b[1] then
      if b[1] == a[1] then return b[2] end
      return a[2] + (b[2] - a[2]) * (t - a[1]) / (b[1] - a[1])
    end
  end
  return pts[#pts][2]
end
Relief.interp = interp

--- An edge of a cell as a polyline { { t, h }, ... }, t from 0 to 16:
-- "N"/"S" run west to east, "W"/"E" north to south.
function Relief.edge(r, side)
  local p = r.prof
  if p then
    local along = (p.axis == "v") == (side == "W" or side == "E")
    if along then return p.pts end
    local t = (side == "N" or side == "W") and 0 or 16
    local h = interp(p.pts, t)
    return { { 0, h }, { 16, h } }
  end
  if side == "N" then return { { 0, r.nw }, { 16, r.ne } } end
  if side == "S" then return { { 0, r.sw }, { 16, r.se } } end
  if side == "W" then return { { 0, r.nw }, { 16, r.sw } } end
  return { { 0, r.ne }, { 16, r.se } }
end

return Relief
