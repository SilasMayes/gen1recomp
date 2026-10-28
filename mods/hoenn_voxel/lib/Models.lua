-- What stands on the cells: tree crowns as leaning cards (and, later,
-- buildings).  Every model is textured by the lift identity, so at 45
-- degrees it is the drawing again.
local lib = ...
local Analysis = lib("Analysis")
local Relief = lib("Relief")
local Derived = lib("Derived")
local Source = lib("Source")
local TD = lib("data/trees")

local Models = {}

local CELL = 16
local TREE_COT = 1 / math.tan(math.rad(TD.ANGLE))

-- a tree cell's part of its crown card: the plane through the base row's
-- south edge, at the ground's height there, leaning back at ANGLE; a point
-- on it at height y shows the drawn row  v = vb - (y - hg) * (1 + cot)
local function treePart(b, ax, ay, c, info, m, COT)
  local baseY = info.abs and info.base or info.base + m.ay
  local hg = Relief.at(Analysis.relief(ax, baseY), 0.5, 0.5)
  local vb = (baseY + 1) * CELL
  local k = 1 + COT
  local function at(v)
    local y = hg + (vb - v) / k
    return y, vb + hg - (y - hg) * COT
  end
  local vTop, vBot = ay * CELL, math.min(ay * CELL + CELL, vb)
  if vBot <= vTop then return end
  local yt, zt = at(vTop)
  local yb, zb = at(vBot)
  local page, tx, ty = Derived.cutout(c.pair, c.mid, info.ground)
  local tex = b:derivedTex(page, tx, ty, Derived.size())
  local x0, x1 = ax * CELL, ax * CELL + CELL
  local lb = vBot - vTop
  b:quadT(tex, 1.0,
    { x0, yt, zt, 0, 0 }, { x1, yt, zt, 16, 0 }, { x1, yb, zb, 16, lb }, { x0, yb, zb, 0, lb })
end

-- ------- buildings

-- the profile of a building's column: the height h(v) of the drawn row v
-- (facade upright from the bottom, roof rising from the eave at its pitch)
local function profile(bld, x, base)
  local vt = bld.cols[x] * CELL + 0
  local vb = bld.vb
  local He = bld.facade
  local t = math.tan(math.rad(bld.pitch))
  local k = t / (1 + t)
  local ve = vb - He
  local p = { vt = vt, vb = vb, ve = ve, He = He, k = k, base = base }
  function p.h(v)
    if v >= ve then return base + (vb - v) end
    return base + He + (ve - v) * k
  end
  -- the drawn row a height on the end wall is dressed from
  function p.row(y)
    local hy = y - base
    if hy <= He then return vb - hy end
    return ve - (hy - He) / k
  end
  p.top = p.h(vt)
  p.ridgeZ = vt + p.top
  p.backZ = p.ridgeZ - (p.top - base - He)
  return p
end

-- the column strip of a building cell: its rows on the profile, split at
-- the eave, under and over layers
local function buildingCell(b, ax, ay, c, p)
  local x0, x1 = ax * CELL, ax * CELL + CELL
  local rowTop = ay * CELL
  local cuts = { rowTop }
  if p.ve > rowTop and p.ve < rowTop + CELL then cuts[#cuts + 1] = p.ve end
  cuts[#cuts + 1] = rowTop + CELL
  local under = b:atlasTex(c.pair, c.mid, "under")
  local over = b.scene.over(ax, ay, c) and b:atlasTex(c.pair, c.mid, "over")
  for i = 1, #cuts - 1 do
    local va, vb = cuts[i], cuts[i + 1]
    local ha, hb = p.h(va), p.h(vb)
    local la, lb = va - rowTop, vb - rowTop
    for layer, tex in pairs({ u = under, o = over or nil }) do
      local e = layer == "o" and 0.08 or 0
      b:quadT(tex, 1.0,
        { x0, ha + e, va + ha + e, 0, la }, { x1, ha + e, va + ha + e, 16, la },
        { x1, hb + e, vb + hb + e, 16, lb }, { x0, hb + e, vb + hb + e, 0, lb })
    end
  end
end

-- an end wall of a building column, in the plane x = X, dressed by height:
-- each slice from the cell its height is drawn in (that cell's edge column)
local function buildingEnd(b, ax, p, X, west, m, cellAt)
  local base = p.base
  local ys = { base }
  local function add(y) if y > base + 1e-3 and y < p.top - 1e-3 then ys[#ys + 1] = y end end
  add(base + p.He)
  -- heights where the dressing row crosses a cell boundary
  for v = math.floor(p.vt / CELL) * CELL + CELL, p.vb - 1, CELL do
    if v >= p.ve then add(base + (p.vb - v)) else add(base + p.He + (p.ve - v) * p.k) end
  end
  ys[#ys + 1] = p.top
  table.sort(ys)
  -- dressed a few pixels in from the drawn edge: past its outline
  local u = west and 3.5 or 12.5
  local shade = west and lib("Builder").SHADE_WEST or lib("Builder").SHADE_EAST
  local nudge = west and -0.02 or 0.02
  local function front(y)
    if y - base <= p.He then return p.vb end
    local v = p.row(y)
    return v + y
  end
  local function back(y)
    if y - base <= p.He then return p.backZ end
    return p.ridgeZ - (p.top - y)
  end
  for i = 1, #ys - 1 do
    local ya, yb = ys[i], ys[i + 1]
    if yb - ya > 1e-3 then
      local vm = p.row((ya + yb) / 2)
      local row = math.floor(vm / CELL)
      local c = cellAt(ax, row)
      if c and c.mid then
        local la, lb = p.row(ya) - row * CELL, p.row(yb) - row * CELL
        local under = b:atlasTex(c.pair, c.mid, "under")
        local over = b.scene.over(ax, row, c) and b:atlasTex(c.pair, c.mid, "over")
        for layer, tex in pairs({ u = under, o = over or nil }) do
          local e = layer == "o" and nudge * 2 or nudge
          b:quadT(tex, shade,
            { X + e, ya, front(ya), u, la }, { X + e, yb, front(yb), u, lb },
            { X + e, yb, back(yb), u, lb }, { X + e, ya, back(ya), u, la })
        end
      end
    end
  end
end

--- Stand the models of cells x0..x1-1, y0..y1-1.
function Models.build(b, x0, y0, x1, y1)
  for ay = y0, y1 - 1 do
    for ax = x0, x1 - 1 do
      local info, m = Analysis.info(ax, ay)
      if info and info.under then
        -- the way beneath a deck, at its own level
        local c = Source.cell(ax, ay)
        if c.mid then
          b:surface(c.pair, info.under.ground, "under", Relief.flat(info.under.level), ax, ay)
        end
      end
      if info and info.tree then
        local c = Source.cell(ax, ay)
        if c.mid then treePart(b, ax, ay, c, info, m, TREE_COT) end
      elseif info and info.prop then
        local c = Source.cell(ax, ay)
        if c.mid then treePart(b, ax, ay, c, info, m, 0) end
      elseif info and info.building then
        local c = Source.cell(ax, ay)
        local res = Analysis.result(m.id)
        local bld = res and res.buildings and res.buildings[info.building]
        if c.mid and bld then
          local lx = ax - m.ax
          local base = bld.level or 0
          local p = profile(bld, lx, base)
          -- the profile is in map-local drawn rows: shift it to absolute
          local dy = m.ay * CELL
          p.vt, p.vb, p.ve = p.vt + dy, p.vb + dy, p.ve + dy
          p.ridgeZ, p.backZ = p.ridgeZ + dy, p.backZ + dy
          local h0 = p.h
          p.h = function(v) return h0(v - dy) end
          local r0 = p.row
          p.row = function(y) return r0(y) + dy end
          buildingCell(b, ax, ay, c, p)
          -- its ends: once per column, from the column's bottom cell
          if ay - m.ay == bld.bottom then
            local function cellAt(cx, row) return Source.cell(cx, row) end
            if lx == bld.x0 or bld.cols[lx - 1] ~= bld.cols[lx] then
              buildingEnd(b, ax, p, ax * CELL, true, m, cellAt)
            end
            if lx == bld.x1 or bld.cols[lx + 1] ~= bld.cols[lx] then
              buildingEnd(b, ax, p, ax * CELL + CELL, false, m, cellAt)
            end
          end
        end
      end
    end
  end
end

Models.UNDER_TREES = 0.72      -- the ground under a crown, in its shade

--- The metatile to lay under a model instead of the cell's drawing, and
-- for a tree the derived tile of it in the crown's shade.
function Models.ground(ax, ay, c)
  local info = Analysis.info(ax, ay)
  if info and (info.tree or info.building or info.prop) and info.ground then
    if info.tree then
      local page, x, y = Derived.shadedGround(c.pair, c.mid, info.ground, Models.UNDER_TREES)
      return info.ground, nil, page and { page = page, x = x, y = y }
    end
    return info.ground
  end
  return nil
end

return Models
