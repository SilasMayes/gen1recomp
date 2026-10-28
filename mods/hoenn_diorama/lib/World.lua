-- The built diorama: cells sampled from ctx, folded by Shape, meshed by
-- Mesher, cached per 16x16 chunk.
--
-- Geometry lives in an absolute frame that survives walking across a map
-- seam: when the current map changes to one that was placed beside it, the
-- new map's offset in the old frame moves the origin, so every chunk already
-- built is still right where it was.  A warp (no shared frame) starts over.
-- A metatile write anywhere in the loaded maps (ctx.world() revisions) marks
-- the chunks stale; stale chunks keep drawing until their rebuild lands, so
-- a Cut tree or a moving puzzle never blinks.
--
-- Structures stand up with their ground colours taken out (Cutouts): each
-- pair's usual ground, the fallback key for a structure with no open ground
-- beside it (deep in a forest), is picked once per warp from the maps'
-- own cells so every chunk agrees on it.
local lib = ...
local Shape = lib("Shape")
local Mesher = lib("Mesher")
local Cutouts = lib("Cutouts")
local Relief = lib("Relief")

local World = {}
World.__index = World

local C = 16
local CHUNK = 16

function World.new(params)
  return setmetatable({
    params = params or {},
    chunks = {},       -- key -> chunk
    cells = {},        -- absolute cell key -> info
    space = 0,         -- bumps on every warp
    originX = 0, originY = 0,
    mapId = nil,
    placed = nil,      -- last frame's ctx.world()
    signature = nil,
    generation = 0,    -- bumps when built geometry goes stale
    frame = 0,
    cutouts = Cutouts.new(),
    grounds = {},      -- pair -> its usual ground cell, or false
    walls = nil,       -- the current room's back wall height, in rows
    reliefs = {},      -- map id#revision -> { r, ax, ay } (Relief.lua)
  }, World)
end

local function key(ax, ay) return ax .. "," .. ay end

local function releaseChunk(ch)
  for _, g in ipairs(ch.meshes or {}) do
    if g.mesh and g.mesh.release then pcall(g.mesh.release, g.mesh) end
  end
  ch.meshes = nil
end

function World:clear()
  for _, ch in pairs(self.chunks) do releaseChunk(ch) end
  self.chunks = {}
  self.cells = {}
  self.job = nil
  self.grounds = {}
  self.walls = nil
  self.reliefs = {}
  self.cutouts:release()
end

function World:setParams(params)
  self.params = params
  self:markStale()
end

function World:markStale()
  self.generation = self.generation + 1
  self.cells = {}
  self.job = nil
end

-- ------- following the current map

local function signatureOf(placed)
  local parts = {}
  for _, m in ipairs(placed or {}) do
    parts[#parts + 1] = tostring(m.id) .. "@" .. tostring(m.ox) .. "," .. tostring(m.oy)
      .. "#" .. tostring(m.revision)
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

--- Track the current map: keep the frame across a seam, start over on a warp,
-- and go stale when any loaded layout changed.
function World:follow(ctx)
  self.outdoors = ctx.outdoors
  local mapId = ctx.mapId
  local placed = ctx.world and ctx.world() or {}
  if mapId ~= self.mapId then
    local moved = false
    if self.mapId ~= nil and self.placed then
      for _, m in ipairs(self.placed) do
        if m.id == mapId then
          self.originX = self.originX + m.ox
          self.originY = self.originY + m.oy
          moved = true
          break
        end
      end
    end
    if not moved then
      self:clear()
      self.space = self.space + 1
      self.originX, self.originY = 0, 0
    else
      -- the same cells, but void sampling and borders follow the root map
      self:markStale()
    end
    self.mapId = mapId
  end
  self.placed = placed
  local sig = signatureOf(placed)
  if sig ~= self.signature then
    if self.signature ~= nil then self:markStale() end
    self.signature = sig
  end
end

-- ------- cells

function World:info(ctx, atlasOf, ax, ay)
  local k = key(ax, ay)
  local c = self.cells[k]
  if c then return c end
  local mid, pair, coll, elev, beh, void = ctx.cell(ax - self.originX, ay - self.originY)
  c = { mid = mid, pair = pair, coll = coll, elev = elev, beh = beh, void = void }
  local pending = false
  if mid ~= nil then
    c.walk = ctx.walkable(coll or 0xff)
    local view = pair and atlasOf(pair)
    if view then
      c.over = view.layered and view.coverage(mid) or 0
    else
      c.over = 0
      pending = true
    end
  end
  c.kind = Shape.classify(c)
  c.pending = pending
  if self.outdoors ~= false and self.params.relief ~= false then
    local nw, ne, se, sw, surface, rk = self:heights(ctx, ax, ay)
    c.rNW, c.rNE, c.rSE, c.rSW, c.relief = nw, ne, se, sw, surface
    -- a mountain's top is ground at its level, walked on or not
    if rk == "top" and (c.kind == "solid" or c.kind == "object") then c.kind = "floor" end
  end
  if not pending then self.cells[k] = c end
  return c
end

-- ------- the height of the ground (Relief.lua)

-- The relief of the placed map `m` (current-map frame), solved once per
-- layout revision and kept in the absolute frame.
function World:reliefOf(ctx, m)
  local k = tostring(m.id) .. "#" .. tostring(m.revision)
  local rel = self.reliefs[k]
  if rel then return rel end
  local ox, oy = m.ox or 0, m.oy or 0
  local function sample(x, y)
    local mid, pair, coll, _, beh, void = ctx.cell(ox + x, oy + y)
    return { mid = mid, pair = pair, beh = beh, void = void,
      walk = mid ~= nil and ctx.walkable(coll or 0xff) or false }
  end
  rel = { r = Relief.solve(sample, m.width or 0, m.height or 0),
    ax = self.originX + ox, ay = self.originY + oy, w = m.width or 0, h = m.height or 0 }
  self.reliefs[k] = rel
  return rel
end

--- The corners of absolute cell (ax, ay), in pixels (nw, ne, se, sw), and
-- whether it is a mountain piece with a surface of its own.  A cell past
-- every map's edge takes the level of the nearest map's edge.
function World:heights(ctx, ax, ay)
  local best, bestD
  for _, m in ipairs(self.placed or {}) do
    if (m.width or 0) > 0 and (m.height or 0) > 0 then
      local x0, y0 = self.originX + (m.ox or 0), self.originY + (m.oy or 0)
      local dx = ax < x0 and x0 - ax or (ax >= x0 + m.width and ax - (x0 + m.width - 1) or 0)
      local dy = ay < y0 and y0 - ay or (ay >= y0 + m.height and ay - (y0 + m.height - 1) or 0)
      local d = dx + dy
      if d == 0 then best = m break end
      if not bestD or d < bestD then best, bestD = m, d end
    end
  end
  if not best then return 0, 0, 0, 0, false end
  local rel = self:reliefOf(ctx, best)
  local x, y = ax - rel.ax, ay - rel.ay
  local nw, ne, se, sw = rel.r.corners(x, y)
  return nw, ne, se, sw, rel.r.surface(x, y), (rel.r.class(x, y))
end

--- The height of the ground under absolute world point (px, pz) (pixels,
-- before the slide), between its cell's corners.
function World:heightAt(ctx, atlasOf, px, pz)
  local ax, ay = math.floor(px / C), math.floor(pz / C)
  local c = self:info(ctx, atlasOf, ax, ay)
  local nw, ne, se, sw = c.rNW or 0, c.rNE or 0, c.rSE or 0, c.rSW or 0
  local fx, fz = px / C - ax, pz / C - ay
  local n = nw + (ne - nw) * fx
  local s = sw + (se - sw) * fx
  return n + (s - n) * fz
end

-- The floor metatile a pair's maps show most, scanning the current map
-- first and the placed neighbours only when it has none of that pair.
-- Asked from a built cell of `pair`, so that pair's atlas is resident and
-- the answer can be kept.
function World:groundOf(ctx, atlasOf, pair)
  local g = self.grounds[pair]
  if g ~= nil then return g or nil end
  local counts, first = {}, {}
  local function scan(m)
    local bx, by = self.originX + (m.ox or 0), self.originY + (m.oy or 0)
    for y = 0, (m.height or 0) - 1 do
      for x = 0, (m.width or 0) - 1 do
        local c = self:info(ctx, atlasOf, bx + x, by + y)
        if c.pair == pair and c.kind == "floor" and c.walk and not c.pending then
          counts[c.mid] = (counts[c.mid] or 0) + 1
          first[c.mid] = first[c.mid] or c
        end
      end
    end
  end
  local placed = self.placed or {}
  if placed[1] then scan(placed[1]) end
  if next(counts) == nil then
    for i = 2, #placed do scan(placed[i]) end
  end
  local best, n = nil, 0
  for mid, k in pairs(counts) do
    if k > n or (k == n and mid < best) then best, n = mid, k end
  end
  g = best and first[best] or false
  self.grounds[pair] = g
  return g or nil
end

-- How many rows a room's back wall usually is: down each column of the
-- current map, the blocked cells from the first one that is not filler (a
-- metatile in one flat colour) to the first walkable cell; the commonest
-- count wins.  Kept until the next warp.
function World:wallHeight(ctx, atlasOf)
  if self.walls ~= nil then return self.walls or nil end
  local m = (self.placed or {})[1]
  local counts = {}
  if m then
    local bx, by = self.originX + (m.ox or 0), self.originY + (m.oy or 0)
    for x = 0, (m.width or 0) - 1 do
      local h, started = 0, false
      for y = 0, (m.height or 0) - 1 do
        local c = self:info(ctx, atlasOf, bx + x, by + y)
        if c.walk then break end
        local view = c.pair and atlasOf(c.pair)
        local flat = view and self.cutouts:colourCount(view, c.mid) == 1
        if not flat then
          started = true
          h = h + 1
        elseif started then
          break
        end
      end
      if h >= 1 then counts[h] = (counts[h] or 0) + 1 end
    end
  end
  local best, n = nil, 0
  for h, k in pairs(counts) do
    if k > n or (k == n and h < best) then best, n = h, k end
  end
  self.walls = best or false
  return best
end

-- ------- chunks

--- Build one chunk's geometry.  Returns the mesh groups, or nil while a
-- tileset pair it needs is still streaming in.
function World:buildChunk(ctx, atlasOf, cx, cy, tick)
  local quads = {}
  local pending = false
  local function info(ax, ay)
    local c = self:info(ctx, atlasOf, ax, ay)
    if c.pending then pending = true end
    return c
  end
  local cutouts = self.cutouts
  local params = setmetatable({
    keyFraction = function(c, keyMid)
      local view = c.pair and atlasOf(c.pair)
      return view and cutouts:fraction(view, c.mid, keyMid) or nil
    end,
    shownFraction = function(c, keyMid)
      local view = c.pair and atlasOf(c.pair)
      return view and cutouts:compositeFraction(view, c.mid, keyMid) or nil
    end,
    groundOf = function(pair)
      return self:groundOf(ctx, atlasOf, pair)
    end,
    keyColours = function(c)
      local view = c.pair and atlasOf(c.pair)
      return view and cutouts:colourCount(view, c.mid) or nil
    end,
    pixels = function(c)
      local view = c.pair and atlasOf(c.pair)
      return view and cutouts:pixels(view, c.mid) or nil
    end,
    composite = function(c)
      local view = c.pair and atlasOf(c.pair)
      return view and cutouts:composite(view, c.mid) or nil
    end,
    indoor = ctx.outdoors == false,
    wallHeight = ctx.outdoors == false and self:wallHeight(ctx, atlasOf) or nil,
  }, { __index = self.params })
  local x0, y0 = cx * CHUNK, cy * CHUNK
  Shape.build(info, x0, y0, x0 + CHUNK, y0 + CHUNK, params, function(q)
    quads[#quads + 1] = q
  end, tick)
  if pending then return nil end
  local groups, missing = Mesher.build(quads, atlasOf, function(view, q)
    local page, x, y = cutouts:resolve(view, q.mid, q.key, q.art)
    if page then return page, x, y, Cutouts.PAGE end
    return nil
  end)
  if missing then return nil end
  -- how low and high it reaches (the sun's frame must hold it all)
  local yLo, yHi = math.huge, -math.huge
  for _, q in ipairs(quads) do
    if q.poly then
      for _, v in ipairs(q.poly) do
        if v[2] < yLo then yLo = v[2] end
        if v[2] > yHi then yHi = v[2] end
      end
    elseif q.p then
      for i = 2, 11, 3 do
        local y = q.p[i]
        if y < yLo then yLo = y end
        if y > yHi then yHi = y end
      end
    end
  end
  return groups, #quads, yLo, yHi
end

local function upload(groups)
  local out = {}
  for _, g in ipairs(groups) do
    if #g.verts > 0 then
      local mesh = love.graphics.newMesh(Mesher.FORMAT, g.verts, "triangles", "static")
      mesh:setVertexMap(g.idx)
      out[#out + 1] = { pair = g.pair, layer = g.layer, page = g.page, mesh = mesh,
        quads = math.ceil(#g.idx / 6) }
    end
  end
  return out
end

--- Make sure the chunks covering [minX, maxX] x [minZ, maxZ] (world pixels,
-- current-map frame) exist and are fresh, nearest first, within `budget`
-- seconds.  Returns the chunks to draw and how many of them are current.
function World:prepare(ctx, atlasOf, minX, maxX, minZ, maxZ, focusX, focusZ, budget, clock)
  local ox, oy = self.originX * C, self.originY * C
  local c0x = math.floor((minX + ox) / (C * CHUNK)) - 1
  local c1x = math.floor((maxX + ox) / (C * CHUNK)) + 1
  local c0y = math.floor((minZ + oy) / (C * CHUNK)) - 1
  local c1y = math.floor((maxZ + oy) / (C * CHUNK)) + 2
  local fx, fy = (focusX + ox) / (C * CHUNK), (focusZ + oy) / (C * CHUNK)
  local want = {}
  for cy = c0y, c1y do
    for cx = c0x, c1x do
      local d = (cx + 0.5 - fx) ^ 2 + (cy + 0.5 - fy) ^ 2
      want[#want + 1] = { cx = cx, cy = cy, d = d }
    end
  end
  table.sort(want, function(a, b) return a.d < b.d end)

  self.frame = (self.frame or 0) + 1
  local start = clock and clock() or 0
  local function overBudget()
    return clock ~= nil and (clock() - start) > budget
  end
  local drawList, fresh = {}, 0
  local live = {}
  for _, w in ipairs(want) do
    local k = self.space .. ":" .. key(w.cx, w.cy)
    live[k] = true
    local ch = self.chunks[k]
    if not ch then
      ch = { cx = w.cx, cy = w.cy, generation = -1 }
      self.chunks[k] = ch
    end
    if ch.generation ~= self.generation and not overBudget()
        and (ch.retryAt or 0) <= self.frame then
      self:step(ctx, atlasOf, ch, overBudget)
    end
    if ch.generation == self.generation then fresh = fresh + 1 end
    if ch.meshes then drawList[#drawList + 1] = ch end
  end
  -- drop what the camera has left well behind
  for k, ch in pairs(self.chunks) do
    if not live[k] then
      ch.idle = (ch.idle or 0) + 1
      if ch.idle > 240 then
        releaseChunk(ch)
        self.chunks[k] = nil
      end
    else
      ch.idle = 0
    end
  end
  return drawList, fresh, #want
end

-- Advance the build of `ch`, a row at a time, until it lands or the frame's
-- budget runs out; a build that does not finish resumes next frame where it
-- left off, so no single frame pays for a whole chunk on a slow device.
-- Only one chunk is in flight; asking for another drops the first.
function World:step(ctx, atlasOf, ch, overBudget)
  local job = self.job
  if not (job and job.chunk == ch and job.generation == self.generation) then
    local generation = self.generation
    job = { chunk = ch, generation = generation }
    job.co = coroutine.create(function()
      return self:buildChunk(ctx, atlasOf, ch.cx, ch.cy, coroutine.yield)
    end)
    self.job = job
  end
  while true do
    local ok, groups, nquads, yLo, yHi = coroutine.resume(job.co)
    if not ok then
      self.job = nil
      error(groups, 0)
    end
    if coroutine.status(job.co) == "dead" then
      self.job = nil
      if groups then
        releaseChunk(ch)
        ch.meshes = upload(groups)
        ch.quads = nquads
        ch.yLo, ch.yHi = yLo, yHi
        ch.generation = self.generation
        ch.retryAt = nil
      else
        -- a tileset pair it needs is still streaming in: let the other
        -- chunks have the budget for a while before trying again
        ch.retryAt = (self.frame or 0) + 20
      end
      return
    end
    if overBudget() then return end
  end
end

--- The absolute frame's offset in world pixels: add it to a current-map
-- position to place it among the chunks.
function World:offset()
  return self.originX * C, self.originY * C
end

return World
