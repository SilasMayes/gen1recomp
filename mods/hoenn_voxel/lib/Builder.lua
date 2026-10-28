-- Geometry for a block of cells: every cell's drawing laid on its relief,
-- and the steps between cells closed so that no angle on the ladder looks
-- through the world.
--
-- Everything here is textured by the lift identity (Relief.lua): a point
-- (x, y, z) shows the drawn pixel (x, z - y).  A step between two cells is
-- closed by a surface the 45-degree view sees edge-on or not at all, so the
-- drawing stays exact there:
--
--   west/east   the quad between the two edges, in the plane of the edge,
--               drawn with the higher cell's edge column
--   back        (the cell south is higher) the north cell's ground runs on
--               south under the higher one, mirrored
--   drop        (the cell north is higher, no face drawn) a wall stands at
--               the lower cell's north edge, under the higher cell's lip,
--               drawn with the higher cell's bottom rows
local lib = ...
local Relief = lib("Relief")

local Builder = {}
Builder.__index = Builder

local CELL = 16
local OVER_LIFT = 0.08          -- the over layer laid this far along (0, 1, 1)

-- face shades (Emerald 3DS's): drawn art carries its own light, walls the
-- builder invents are shaded by the way they face
Builder.SHADE_TOP = 1.0
Builder.SHADE_SOUTH = 0.60
Builder.SHADE_WEST = 0.65
Builder.SHADE_EAST = 0.55

function Builder.new(scene)
  return setmetatable({ scene = scene, batches = {}, order = {}, missing = 0, tris = 0 }, Builder)
end

-- a batch per texture: a pair's under or over layer, or a derived page
function Builder:batch(tex)
  local b = self.batches[tex.key]
  if not b then
    b = { key = tex.key, kind = tex.kind, pair = tex.pair, layer = tex.layer, page = tex.page,
      verts = {} }
    self.batches[tex.key] = b
    self.order[#self.order + 1] = tex.key
  end
  return b
end

--- A metatile's rectangle in its pair's atlas, or nil (still streaming:
-- counted as missing, so the block is built again).
function Builder:atlasTex(pair, mid, layer)
  local view = self.scene.atlas(pair)
  if not view then self.missing = self.missing + 1 return nil end
  if not view.slot(mid) then return nil end
  local ox, oy = view.origin(mid)
  layer = layer or "under"
  return { key = "a|" .. pair .. "|" .. layer, kind = "atlas", pair = pair, layer = layer,
    ox = ox, oy = oy, W = view.width, H = view.height }
end

--- A derived slot (Derived.lua).
function Builder:derivedTex(page, x, y, size)
  if not page then self.missing = self.missing + 1 return nil end
  return { key = "d|" .. page, kind = "derived", page = page, ox = x, oy = y, W = size, H = size }
end

local function vert(list, x, y, z, s, t, shade)
  list[#list + 1] = { x, y, z, s, t, shade, shade, shade, 1 }
end

--- A triangle with a texture rectangle: points (x, y, z) and their texel
-- (lu, lv) inside the 16 x 16 tile.
function Builder:triT(tex, shade, x1, y1, z1, u1, v1, x2, y2, z2, u2, v2, x3, y3, z3, u3, v3)
  if not tex then return false end
  local list = self:batch(tex).verts
  local ox, oy, W, H = tex.ox, tex.oy, tex.W, tex.H
  vert(list, x1, y1, z1, (ox + u1) / W, (oy + v1) / H, shade)
  vert(list, x2, y2, z2, (ox + u2) / W, (oy + v2) / H, shade)
  vert(list, x3, y3, z3, (ox + u3) / W, (oy + v3) / H, shade)
  self.tris = self.tris + 1
  return true
end

function Builder:tri(pair, layer, mid, shade, ...)
  return self:triT(self:atlasTex(pair, mid, layer), shade, ...)
end

function Builder:quadT(tex, shade, a, b, c, d)
  if not tex then return end
  self:triT(tex, shade, a[1], a[2], a[3], a[4], a[5], b[1], b[2], b[3], b[4], b[5],
    c[1], c[2], c[3], c[4], c[5])
  self:triT(tex, shade, a[1], a[2], a[3], a[4], a[5], c[1], c[2], c[3], c[4], c[5],
    d[1], d[2], d[3], d[4], d[5])
end

function Builder:quad(pair, layer, mid, shade, a, b, c, d)
  self:quadT(self:atlasTex(pair, mid, layer), shade, a, b, c, d)
end

-- ------- a cell's drawing on its relief

--- Lay a metatile's layer on a relief at cell (ax, ay); `lift` raises it
-- along (0, 1, 1), which the 45-degree view does not see.
function Builder:surface(pair, mid, layer, r, ax, ay, lift, shade)
  self:surfaceT(self:atlasTex(pair, mid, layer), r, ax, ay, lift, shade)
end

--- The same with any texture rectangle.
function Builder:surfaceT(tex, r, ax, ay, lift, shade)
  if not tex then return end
  lift = lift or 0
  shade = shade or Builder.SHADE_TOP
  if r.prof then return self:profileT(tex, r.prof, ax, ay, lift, shade) end
  local x0, z0 = ax * CELL, ay * CELL
  local x1, z1 = x0 + CELL, z0 + CELL
  local nw = { x0, r.nw + lift, z0 + r.nw + lift, 0, 0 }
  local ne = { x1, r.ne + lift, z0 + r.ne + lift, 16, 0 }
  local sw = { x0, r.sw + lift, z1 + r.sw + lift, 0, 16 }
  local se = { x1, r.se + lift, z1 + r.se + lift, 16, 16 }
  if r.crease == "main" then
    self:quadT(tex, shade, nw, ne, se, sw)
  else
    self:triT(tex, shade, nw[1], nw[2], nw[3], 0, 0, ne[1], ne[2], ne[3], 16, 0,
      sw[1], sw[2], sw[3], 0, 16)
    self:triT(tex, shade, ne[1], ne[2], ne[3], 16, 0, se[1], se[2], se[3], 16, 16,
      sw[1], sw[2], sw[3], 0, 16)
  end
end

-- a profiled cell: strips between its breakpoints
function Builder:profileT(tex, prof, ax, ay, lift, shade)
  local x0, z0 = ax * CELL, ay * CELL
  local pts = prof.pts
  for i = 1, #pts - 1 do
    local t0, h0 = pts[i][1], pts[i][2] + lift
    local t1, h1 = pts[i + 1][1], pts[i + 1][2] + lift
    if t1 > t0 then
      if prof.axis == "v" then
        self:quadT(tex, shade,
          { x0, h0, z0 + t0 + h0, 0, t0 }, { x0 + CELL, h0, z0 + t0 + h0, 16, t0 },
          { x0 + CELL, h1, z0 + t1 + h1, 16, t1 }, { x0, h1, z0 + t1 + h1, 0, t1 })
      else
        self:quadT(tex, shade,
          { x0 + t0, h0, z0 + h0, t0, 0 }, { x0 + t1, h1, z0 + h1, t1, 0 },
          { x0 + t1, h1, z0 + CELL + h1, t1, 16 }, { x0 + t0, h0, z0 + CELL + h0, t0, 16 })
      end
    end
  end
end

-- ------- steps

-- the breakpoints of two polylines on one span, merged
local function merged(pa, pb)
  local ts, seen = {}, {}
  for _, list in ipairs({ pa, pb }) do
    for _, p in ipairs(list) do
      if not seen[p[1]] then seen[p[1]] = true; ts[#ts + 1] = p[1] end
    end
  end
  table.sort(ts)
  return ts
end

-- walk two edges segment by segment, split where they cross: fn(t0, t1,
-- a0, a1, b0, b1, aHigher) for every part where they differ
local function each(pa, pb, fn)
  local ts = merged(pa, pb)
  for i = 1, #ts - 1 do
    local t0, t1 = ts[i], ts[i + 1]
    local a0, a1 = Relief.interp(pa, t0), Relief.interp(pa, t1)
    local b0, b1 = Relief.interp(pb, t0), Relief.interp(pb, t1)
    local d0, d1 = a0 - b0, a1 - b1
    if math.abs(d0) > 1e-4 or math.abs(d1) > 1e-4 then
      if d0 * d1 >= 0 then
        fn(t0, t1, a0, a1, b0, b1, (d0 + d1) > 0)
      else
        local f = d0 / (d0 - d1)
        local tm = t0 + (t1 - t0) * f
        local hm = a0 + (a1 - a0) * f
        fn(t0, tm, a0, hm, b0, hm, d0 > 0)
        fn(tm, t1, hm, a1, hm, b1, d1 > 0)
      end
    end
  end
end

Builder.DECK_EDGE = 4           -- how far a deck's edge goes down under it

-- a deck's side goes down its edge's thickness, not to the ground: the
-- ground goes on under it (Emerald 3DS's thin decks)
local function thin(hHigh, hLow, deck)
  if deck then return math.max(hLow, hHigh - Builder.DECK_EDGE) end
  return hLow
end

-- the west/east step at the edge x = X between cell A (west) and B (east)
-- of row ay: A's east edge and B's west edge, polylines down the rows.
function Builder:sideStep(a, b, ay, X, ea, eb, deckA, deckB)
  local z0 = ay * CELL
  each(ea, eb, function(va, vb, ha0, ha1, hb0, hb1, higherA)
    if higherA then hb0, hb1 = thin(ha0, hb0, deckA), thin(ha1, hb1, deckA)
    else ha0, ha1 = thin(hb0, ha0, deckB), thin(hb1, ha1, deckB) end
    -- the quad between A's edge and B's edge over drawn rows va..vb
    local owner = higherA and a or b
    local lu = higherA and 15.5 or 0.5
    local shade = higherA and Builder.SHADE_EAST or Builder.SHADE_WEST
    local p1 = { X, ha0, z0 + va + ha0, lu, va }
    local p2 = { X, ha1, z0 + vb + ha1, lu, vb }
    local p3 = { X, hb1, z0 + vb + hb1, lu, vb }
    local p4 = { X, hb0, z0 + va + hb0, lu, va }
    self:quad(owner.pair, "under", owner.mid, shade, p1, p2, p3, p4)
  end)
end

-- the step at the edge between cell A (north) and B (south) at column ax:
-- A's south edge and B's north edge, polylines west to east.
function Builder:rowStep(a, b, ax, ay, ea, eb, deckA, deckB)
  local Z = (ay + 1) * CELL               -- the drawn row between them
  local X0 = ax * CELL
  each(ea, eb, function(ua, ub, ha0, ha1, hb0, hb1, higherA)
    local xa, xb = X0 + ua, X0 + ub
    if higherA and deckA then
      -- a deck's south edge: its planks' thickness, the ground going on under
      hb0, hb1 = thin(ha0, hb0, true), thin(ha1, hb1, true)
    end
    if not higherA and deckB then return end   -- the way under a deck is the deck's own
    if higherA then
      -- a drop: B's wall under A's lip, showing A's bottom rows
      local function lv(hA, hB) return math.max(0, 16 - (hA - hB)) end
      local p1 = { xa, hb0, Z + hb0, ua, 16 }
      local p2 = { xb, hb1, Z + hb1, ub, 16 }
      local p3 = { xb, ha1, Z + hb1, ub, lv(ha1, hb1) }
      local p4 = { xa, ha0, Z + hb0, ua, lv(ha0, hb0) }
      self:quad(a.pair, "under", a.mid, Builder.SHADE_SOUTH, p1, p2, p3, p4)
    else
      -- a back: A's ground runs on south under B, its drawing mirrored
      local function lv(hA, hB)
        local d = hB - hA
        return d <= 16 and 16 - d or 0
      end
      local p1 = { xa, ha0, Z + ha0, ua, 16 }
      local p2 = { xb, ha1, Z + ha1, ub, 16 }
      local p3 = { xb, ha1, Z + hb1, ub, lv(ha1, hb1) }
      local p4 = { xa, ha0, Z + hb0, ua, lv(ha0, hb0) }
      self:quad(a.pair, "under", a.mid, Builder.SHADE_TOP, p1, p2, p3, p4)
    end
  end)
end

-- ------- a block

--- Build cells x0..x1-1, y0..y1-1 (absolute).  scene: cell(ax, ay),
-- relief(ax, ay), atlas(pair), over(ax, ay, cell) -> whether to lay the
-- over layer flat, ground(ax, ay, cell) -> a metatile to lay instead of the
-- cell's own drawing (the ground under a tree a model stands there).
function Builder:block(x0, y0, x1, y1)
  local scene = self.scene
  local function drawn(ax, ay)
    local c = scene.cell(ax, ay)
    if not c.mid then return c end
    if scene.hidden and scene.hidden(ax, ay) then return { void = true } end
    local g, shade, derived
    if scene.ground then g, shade, derived = scene.ground(ax, ay, c) end
    if g then return { mid = g, pair = c.pair, ground = true, shade = shade, derived = derived } end
    return c
  end
  for ay = y0, y1 - 1 do
    for ax = x0, x1 - 1 do
      local c = drawn(ax, ay)
      if c.mid then
        local r = scene.relief(ax, ay)
        if c.derived then
          local Derived = lib("Derived")
          self:surfaceT(self:derivedTex(c.derived.page, c.derived.x, c.derived.y, Derived.size()),
            r, ax, ay, 0, c.shade)
        else
          self:surface(c.pair, c.mid, "under", r, ax, ay, 0, c.shade)
        end
        if not c.ground and scene.over(ax, ay, c) then
          self:surface(c.pair, c.mid, "over", r, ax, ay, OVER_LIFT)
        end
        -- steps to the east and south neighbours (a block owns the steps on
        -- its cells' east and south edges, the edges west and north belong
        -- to the block before it)
        local e = drawn(ax + 1, ay)
        if e.mid then
          local re = scene.relief(ax + 1, ay)
          self:sideStep(c, e, ay, (ax + 1) * CELL, Relief.edge(r, "E"), Relief.edge(re, "W"),
            r.deck, re.deck)
        end
        local s = drawn(ax, ay + 1)
        if s.mid then
          local rs = scene.relief(ax, ay + 1)
          self:rowStep(c, s, ax, ay, Relief.edge(r, "S"), Relief.edge(rs, "N"), r.deck, rs.deck)
        end
      end
    end
  end
end

return Builder
