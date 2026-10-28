-- What each placed map is made of, worked out once per map and kept: the
-- relief of every cell and what stands on it.  Filled in by the readers
-- (Roles, Terrain, Models); until a map is read its cells are flat.
local lib = ...
local Source = lib("Source")
local Relief = lib("Relief")

local Analysis = {}

local results = {}      -- map id -> { width, height, relief = { [i] = rec }, version }

function Analysis.result(id) return results[id] end

function Analysis.version(id)
  local r = results[id]
  return r and r.version or 0
end

Analysis.stamp = 0

function Analysis.store(id, result)
  local old = results[id]
  result.version = (old and old.version or 0) + 1
  results[id] = result
  Analysis.stamp = Analysis.stamp + 1
end

function Analysis.forget(id)
  if id then results[id] = nil else results = {} end
end

-- the border: past the last map the world goes on at the height of the
-- nearest map's edge (a plateau reaching the edge does not fall away)
local function nearestEdge(ax, ay)
  local best, bm, bx, by
  for _, m in pairs(Source.state.placed) do
    local r = results[m.id]
    if r and r.relief and m.width > 0 then
      local cx = math.max(m.ax, math.min(m.ax + m.width - 1, ax))
      local cy = math.max(m.ay, math.min(m.ay + m.height - 1, ay))
      local d = math.abs(cx - ax) + math.abs(cy - ay)
      if not best or d < best then best, bm, bx, by = d, m, cx, cy end
    end
  end
  return bm, bx, by, best
end

local borderMemo, borderEpoch = {}, nil

local function borderRelief(ax, ay)
  -- indoors the border is the dark round a room: it lies at the floor
  local ctx = Source.ctx()
  if ctx and ctx.outdoors == false then return Relief.FLAT end
  local m, cx, cy, d = nearestEdge(ax, ay)
  if not m or d > 24 then return Relief.FLAT end
  local r = results[m.id].relief[(cy - m.ay) * m.width + (cx - m.ax) + 1]
  if not r then return Relief.FLAT end
  local h
  if ay < cy then h = math.min(r.nw, r.ne)
  elseif ay > cy then h = math.min(r.sw, r.se)
  elseif ax < cx then h = math.min(r.nw, r.sw)
  else h = math.min(r.ne, r.se) end
  return Relief.flat(h)
end

--- The relief of the cell at absolute (ax, ay).
function Analysis.relief(ax, ay)
  local m = Source.mapAt(ax, ay)
  if not m then
    local key = ay * 65536 + ax
    local sig = Source.state.epoch .. ":" .. Source.state.seam .. ":" .. Analysis.stamp
    if borderEpoch ~= sig then borderMemo, borderEpoch = {}, sig end
    local r = borderMemo[key]
    if not r then r = borderRelief(ax, ay); borderMemo[key] = r end
    return r
  end
  local r = results[m.id]
  if not (r and r.relief) then return Relief.FLAT end
  return r.relief[(ay - m.ay) * m.width + (ax - m.ax) + 1] or Relief.FLAT
end

-- the border's trees: a General tree drawn in the border block stands as
-- the trees do, its rows paired by the block's phase
local TD = lib("data/trees")
local borderInfo = {}
local function borderTree(ax, ay)
  local c = Source.cell(ax, ay)
  if not (c.mid and c.pair and c.pair:match("^general__") and c.mid < 0x200) then return nil end
  local part = TD.PART[c.mid]
  if part ~= "U" and part ~= "L" then return nil end
  local key = c.mid .. ":" .. ay
  local base = part == "U" and ay + 1 or ay
  local h = borderRelief(ax, base)
  return { tree = true, base = base, abs = true, ground = TD.GROUND[c.mid] or 0x001,
    level = h.nw }
end

--- What stands on the cell at absolute (ax, ay) (a tree, a building's
-- part), or nil; and the map it is in.
function Analysis.info(ax, ay)
  local m = Source.mapAt(ax, ay)
  if not m then return borderTree(ax, ay), nil end
  local r = results[m.id]
  if not (r and r.info) then return nil end
  return r.info[(ay - m.ay) * m.width + (ax - m.ax) + 1], m
end

--- Whether a cell is not drawn at all (the dark round a room).
function Analysis.hidden(ax, ay)
  local m = Source.mapAt(ax, ay)
  if not m then
    local ctx = Source.ctx()
    if ctx and ctx.outdoors == false then
      -- the border indoors: dark, unless something is drawn there
      local c = Source.cell(ax, ay)
      local Tiles = lib("Tiles")
      local s = c.mid and Tiles.get(c.pair, c.mid)
      return s ~= nil and s.dark
    end
    return false
  end
  local r = results[m.id]
  local c = r and r.input and r.input.cells[(ay - m.ay) * m.width + (ax - m.ax) + 1]
  return c ~= nil and c.blank == true and c.m ~= 0
end

--- The height of the ground under a foot drawn at absolute world pixels
-- (x, v): the cell the foot stands in, at its centre.
-- With an elevation (the player's), a deck's underpass answers for the way
-- beneath it when the elevation is the ground's.
function Analysis.groundAt(x, v, elevation)
  local ax, ay = math.floor(x / 16), math.floor((v - 0.5) / 16)
  if elevation and elevation <= 3 then
    local info = Analysis.info(ax, ay)
    if info and info.under then return info.under.level end
  end
  return Relief.at(Analysis.relief(ax, ay), 0.5, 0.5)
end

return Analysis
