-- Reads each placed map once: gathers what the cart and the art say of its
-- cells into plain data, has Terrain count its levels, and stores the
-- reliefs for the builder.  A map is read again when its revision changes
-- (a metatile write); one whose tileset is still streaming in waits.
local lib, mod = ...
local Source = lib("Source")
local Analysis = lib("Analysis")
local Tiles = lib("Tiles")
local Roles = lib("Roles")
local Terrain = lib("Terrain")
local Relief = lib("Relief")
local T = lib("data/terrain")
local Trees = lib("Trees")
local TD = lib("data/trees")
local Buildings = lib("Buildings")
local Props = lib("Props")
local Decks = lib("Decks")
local Cache = lib("Cache")

local Reader = {}

local readRev = {}          -- map id -> revision read
local pending = {}          -- map id -> { handle, input, revision, t0 }
local sources               -- the job's source files

local function primaryOf(pair)
  return pair and pair:match("^([^_]+)__") or pair
end

--- Gather a map's cells; nil while a tileset streams in.
function Reader.gather(m)
  local cells, tiles = {}, {}
  local pair
  local ctx = Source.ctx()
  local indoors = ctx and ctx.outdoors == false
  for y = 0, m.height - 1 do
    for x = 0, m.width - 1 do
      local c = Source.cell(m.ax + x, m.ay + y)
      local i = y * m.width + x + 1
      if not c.mid then
        cells[i] = { m = 0, blank = true, walk = false }
      else
        pair = pair or c.pair
        local s = tiles[c.mid]
        if s == nil then
          s = Tiles.get(c.pair, c.mid)
          if not s then return nil end
          tiles[c.mid] = s
        end
        local r = Roles.of(c, Source.walkable)
        local general = primaryOf(c.pair) == "general" and c.mid < 0x200
        local tree = (general and TD.PART[c.mid] ~= nil) or (not r.walk and not r.water and
          ((s.leafO >= 0.5 and s.cover >= 0.2) or s.leafU >= 0.45))
        cells[i] = {
          blank = indoors and s.dark or nil,
          m = c.mid, walk = r.walk, water = r.water, ledge = r.jump ~= nil, jump = r.jump,
          bridge = r.bridge, tree = tree, berry = r.berry, mud = r.mud, warp = r.door,
          falls = r.falls, puddle = r.puddle, elev = c.elev, beh = r.beh,
        }
      end
    end
  end
  return {
    w = m.width, h = m.height, pair = pair,
    general = primaryOf(pair) == "general",
    cells = cells, tiles = tiles,
  }
end

-- a ledge: a berm along the drawn lip (Emerald 3DS's reading), its face
-- upright where it falls south, a 45-degree band where it falls west or east
local LIP_BACK = 8
local function ledgeRelief(s, jump, level)
  if not (s and s.cls and jump) then return nil end
  local dx, dy = jump[1], jump[2]
  local function rock(i) local ch = s.cls:sub(i, i) return ch == "T" or ch == "F" end
  if dy > 0 then
    local r0, r1
    for y = 0, 15 do
      local n = 0
      for x = 0, 15 do if rock(y * 16 + x + 1) then n = n + 1 end end
      if n >= 6 then r0 = r0 or y; r1 = y + 1 end
    end
    if not r0 then return nil end
    local d = math.max(3, math.min(8, r1 - r0))
    if r0 + d > 16 then r0 = 16 - d end
    local pts = { { 0, level } }
    if r0 - LIP_BACK > 0 then pts[#pts + 1] = { r0 - LIP_BACK, level } end
    pts[#pts + 1] = { r0, level + d }
    pts[#pts + 1] = { r0 + d, level }
    if r0 + d < 16 then pts[#pts + 1] = { 16, level } end
    return Relief.profile("v", pts, "ledge")
  elseif dx ~= 0 and dy == 0 then
    local c0, c1
    for x = 0, 15 do
      local n = 0
      for y = 0, 15 do if rock(y * 16 + x + 1) then n = n + 1 end end
      if n >= 6 then c0 = c0 or x; c1 = x + 1 end
    end
    if not c0 then return nil end
    local d = math.max(3, math.min(8, c1 - c0))
    local pts = { { 0, level } }
    if dx < 0 then
      -- falls west: the rock on the west side, its lip on the band's east edge
      if c0 > 0 then pts[#pts + 1] = { c0, level } end
      pts[#pts + 1] = { c1, level + d }
      if c1 + LIP_BACK < 16 then pts[#pts + 1] = { c1 + LIP_BACK, level } end
      pts[#pts + 1] = { 16, level }
    else
      if c0 - LIP_BACK > 0 then pts[#pts + 1] = { c0 - LIP_BACK, level } end
      pts[#pts + 1] = { c0, level + d }
      if c1 < 16 then pts[#pts + 1] = { c1, level } end
      pts[#pts + 1] = { 16, level }
    end
    return Relief.profile("u", pts, "ledge")
  end
  return nil
end

local function reliefOf(result, n, input, ridges, groundNear, mass, decks)
  local out = {}
  for i = 1, n do
    local k, top = result.kind[i], result.top[i]
    local c = input.cells[i]
    local r
    if c.ledge then r = ledgeRelief(input.tiles[c.m], c.jump, top) end
    if ridges and ridges[i] then
      local x, y = (i - 1) % input.w, math.floor((i - 1) / input.w)
      local g = groundNear(x, y)
      r = Props.ridge(input.tiles[c.m], g and input.tiles[g], top, Relief)
    end
    if mass and mass[i] then r = Props.massRelief(mass[i], Relief) end
    if r then out[i] = r
    elseif k == "F" then out[i] = Relief.flat(top) else out[i] = Relief.piece(k, top) end
    if decks and decks[i] then
      -- a deck: its own record (shared flat ones are never marked), whose
      -- steps go down only its edge's thickness
      local d = out[i]
      if not d.prof and d == Relief.flat(d.nw) then d = Relief.corners(d.nw, d.ne, d.sw, d.se, d.kind) end
      d.deck = true
      out[i] = d
    end
  end
  return out
end

-- A map's levels are counted from its own biggest ground: shift them so it
-- meets the maps already read where they touch (the commonest difference
-- across the seam, ground to ground).
local function seamShift(m, input, result)
  local votes, best, shift = {}, 0, 0
  local w, h = m.width, m.height
  for id, o in pairs(Source.state.placed) do
    local res = id ~= m.id and Analysis.result(id)
    if res and res.terrain then
      local function other(ax, ay)
        local lx, ly = ax - o.ax, ay - o.ay
        if lx < 0 or ly < 0 or lx >= o.width or ly >= o.height then return nil end
        return ly * o.width + lx + 1
      end
      for y = 0, h - 1 do
        for x = 0, w - 1 do
          if x == 0 or y == 0 or x == w - 1 or y == h - 1 then
            local i = y * w + x + 1
            local k = result.read[i]
            if (k == "G" or k == "T") and not input.cells[i].blank then
              for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
                local j = other(m.ax + x + d[1], m.ay + y + d[2])
                if j then
                  local ok = res.terrain.read[j]
                  if ok == "G" or ok == "T" then
                    local diff = res.terrain.top[j] - result.top[i]
                    votes[diff] = (votes[diff] or 0) + 1
                    local v = votes[diff]
                    if v > best or (v == best and math.abs(diff) < math.abs(shift)) then
                      best, shift = v, diff
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return shift
end

-- everything after the count: the seam, the trees, buildings and props
local function finish(id, m, input, result, seconds)
  local shift = seamShift(m, input, result)
  if shift ~= 0 then
    for i = 1, m.width * m.height do result.top[i] = result.top[i] + shift end
  end
  local c1 = os.clock()
  local decks, under = Decks.apply(input, result)
  local info, groundNear = Trees.read(input, result)
  -- the way beneath a deck: its ground at its own level
  for i, level in pairs(under) do
    local x, y = (i - 1) % m.width, math.floor((i - 1) / m.width)
    local g = groundNear(x, y)
    if g then
      info[i] = info[i] or {}
      info[i].under = { level = level, ground = g }
    end
  end
  local buildings = Buildings.read(input, result, input.pair, info, groundNear)
  local ridges, mass = Props.read(input, result, info, groundNear)
  if Reader.debug then print(("reader %s: count %.0fms, models %.0fms"):format(id, seconds * 1000,
    (os.clock() - c1) * 1000)) end
  Analysis.store(id, {
    width = m.width, height = m.height, input = input, terrain = result, pair = input.pair,
    relief = reliefOf(result, m.width * m.height, input, ridges, groundNear, mass, decks),
    info = info,
    buildings = buildings, decks = decks, seconds = seconds,
  })
  readRev[id] = m.revision
end

local function jobs()
  return mod and mod.job and (not mod.job.available or mod.job:available()) and mod.job or nil
end

local function now() return love.timer and love.timer.getTime() or os.clock() end

--- Read what needs reading: count terrain in a job where the host has
-- them, else here.  Returns true while anything is still being read.
function Reader.update()
  local busy = false
  for id, m in pairs(Source.state.placed) do
    if m.width > 0 and m.height > 0 and readRev[id] ~= m.revision then
      local p = pending[id]
      if p and p.revision ~= m.revision then
        if p.handle then jobs():release(p.handle) end
        pending[id], p = nil, nil
      end
      if p then
        local r = jobs():poll(p.handle)
        if r.status == "ok" then
          jobs():release(p.handle)
          pending[id] = nil
          Cache.write(p.input, r.result)
          finish(id, m, p.input, r.result, now() - p.t0)
        elseif r.status == "pending" then
          busy = true
        else
          -- the job failed: count here
          jobs():release(p.handle)
          pending[id] = nil
          if Reader.debug then print("reader job failed: " .. tostring(r.err)) end
          local t0 = now()
          finish(id, m, p.input, Terrain.solve(p.input, T), now() - t0)
        end
      else
        local input = Reader.gather(m)
        local kept = input and not Reader.noCache and Cache.read(input)
        if kept then
          finish(id, m, input, kept, 0)
        elseif input then
          local J = jobs()
          local handle
          if J and not Reader.inline then
            if not sources then
              sources = { terrain = mod:read("lib/Terrain.lua"), data = mod:read("data/terrain.lua") }
            end
            handle = J:run("jobs/read.lua", { terrain = sources.terrain, data = sources.data,
              input = input }, { maxSeconds = 20 })
          end
          if handle then
            pending[id] = { handle = handle, input = input, revision = m.revision, t0 = now() }
            busy = true
          else
            local t0 = now()
            local result = Terrain.solve(input, T)
            Cache.write(input, result)
            finish(id, m, input, result, now() - t0)
          end
        else
          busy = true      -- a tileset still streaming in
        end
      end
    end
  end
  return busy
end

--- Whether a map has been read at its current revision.
function Reader.done(id)
  local m = Source.state.placed[id]
  return m ~= nil and readRev[id] == m.revision
end

function Reader.forget()
  local J = jobs()
  for _, p in pairs(pending) do if J and p.handle then J:release(p.handle) end end
  readRev, pending = {}, {}
end

return Reader
