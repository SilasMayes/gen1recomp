-- Mountains read the way the tileset builds them: whole levels, one tile a
-- level.  This is Emerald 3DS's reading (scripts/voxel_terraces.py, MIT)
-- done again in Lua over what the game hands a pipeline at run time:
--
--   1. cells are read off their pixels and the cart: ground, top, rock (a
--      face, a band down a side), or unknown (trees, boulders: the ground
--      under them is not drawn)
--   2. a column of k rock cells between two flat cells says the upper one
--      stands k levels over the lower; a row of k bands says the same across.
--      Terraces are the flat cells joined like to like; every column and row
--      votes, the levels are taken greatest vote first, and a vote that
--      contradicts what is already decided is dropped (it becomes a step,
--      never a bent surface)
--   3. every rock cell takes the level it hangs from
--   4. the rock is settled: each cell takes the piece (Relief.PIECES) and
--      level, of a few near its own, that meets its neighbours best
--
-- Pure Lua over plain data: it runs on the main thread or in a job.
--
--   input  { w, h, general, cells = { { m, walk, water, ledge, bridge, tree,
--            berry, mud, warp, falls, puddle } ... }, tiles = { [m] = Tiles reading } }
--   output { kind = { [i] = piece or nil }, top = { [i] = pixels }, read = { [i] = "G"|"T"|"R"|"?" } }
local Terrain = {}

local GROUND, TOP, ROCK, UNKNOWN = "G", "T", "R", "?"
Terrain.GROUND, Terrain.TOP, Terrain.ROCK, Terrain.UNKNOWN = GROUND, TOP, ROCK, UNKNOWN

local function count(cls, ch, row0, row1)
  local n = 0
  for i = row0 * 16 + 1, (row1 + 1) * 16 do
    if cls:byte(i) == ch then n = n + 1 end
  end
  return n
end
local BT, BF, BG = ("T"):byte(), ("F"):byte(), ("G"):byte()

-- corners NW, NE, SW, SE in levels under a piece's top
local PIECE = {
  F = { 0, 0, 0, 0 }, S = { 0, 0, -1, -1 }, E = { 0, -1, 0, -1 }, W = { -1, 0, -1, 0 },
  E2 = { 0, -2, 0, -2 }, W2 = { -2, 0, -2, 0 },
  cSE = { 0, -1, -1, -1 }, cSW = { -1, 0, -1, -1 }, vSE = { 0, 0, 0, -1 }, vSW = { 0, 0, -1, 0 },
}
Terrain.PIECE = PIECE
local CORNERS = { "cSE", "cSW", "vSE", "vSW" }
local IS_CORNER = { cSE = true, cSW = true, vSE = true, vSW = true }

-- the heights of a piece's edge at its two ends: "N" west->east, "S"
-- west->east, "W" north->south, "E" north->south
local function edge(kind, top, side, L)
  local p = PIECE[kind]
  if side == "N" then return top + p[1] * L, top + p[2] * L end
  if side == "S" then return top + p[3] * L, top + p[4] * L end
  if side == "W" then return top + p[1] * L, top + p[3] * L end
  return top + p[2] * L, top + p[4] * L
end
Terrain.edge = edge

-- ------- union-find keeping each item's level over its root's

local function Offsets()
  local parent, off = {}, {}
  local o = {}
  function o.find(a)
    if parent[a] == nil then parent[a] = a; off[a] = 0 end
    local p = parent[a]
    if p == a then return a, 0 end
    local r, po = o.find(p)
    parent[a] = r
    off[a] = off[a] + po
    return r, off[a]
  end
  -- level(a) - level(b) = d
  function o.join(a, b, d)
    local ra, oa = o.find(a)
    local rb, ob = o.find(b)
    if ra == rb then return math.abs((oa - ob) - d) < 1e-6 end
    parent[rb] = ra
    off[rb] = oa - d - ob
    return true
  end
  return o
end

function Terrain.solve(input, T)
  local clock = os.clock
  local marks = Terrain.debug and {} or nil
  local function mark(name) if marks then marks[#marks + 1] = { name, clock() } end end
  mark("start")
  local w, h = input.w, input.h
  local L = T.LEVEL
  local cells, tiles = input.cells, input.tiles
  local N = w * h

  local function at(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return nil end
    return y * w + x + 1
  end
  local function xy(i) return (i - 1) % w, math.floor((i - 1) / w) end

  local function gen(m) return input.general and m < 0x200 end
  local function tileOf(i) local c = cells[i]; return c and tiles[c.m] end
  local function topTile(i)
    local c = cells[i]
    if not c or not gen(c.m) or not T.MOUNTAIN[c.m] then return false end
    local s = tiles[c.m]
    return s ~= nil and s.f < 0.08 and s.t >= 0.45
  end
  local function faceTile(i)
    local s = i and tileOf(i)
    return s ~= nil and s.f * 256 >= 96
  end
  local function inFace(x, y, both)
    local a, b = faceTile(at(x - 1, y)), faceTile(at(x + 1, y))
    if both then return a and b end
    return a or b
  end

  -- ------- 1. cells
  local kind, band, rim, keep = {}, {}, {}, {}
  for i = 1, N do
    local c = cells[i]
    local s = tiles[c.m]
    local x, y = xy(i)
    local k
    if c.blank or not s then
      k = GROUND
    else
      local m = c.m
      local G = gen(m)
      local mountain = G and T.MOUNTAIN[m] or false
      local t, f = s.t, s.f
      local tree = c.tree and not (mountain and t + f >= 0.25)
      local floor = c.walk and not c.water
      if tree or (G and T.LOOSE[m]) then
        k = UNKNOWN
      elseif G and T.HEADS[m] and not c.ledge and at(x, y + 1) and topTile(at(x, y + 1)) then
        k = TOP
      elseif G and (T.BAND_WEST[m] or T.BAND_EAST[m]) and not c.ledge then
        k = ROCK
        band[i] = T.BAND_WEST[m] and "W" or "E"
      elseif c.ledge or c.water or c.bridge then
        k = GROUND
      elseif ((G and T.CARVED_STEPS[m] and floor) or c.mud) and inFace(x, y) then
        k = ROCK
      elseif floor and c.warp and inFace(x, y, true) then
        k = ROCK
      elseif floor and mountain and f >= 0.5 then
        k = c.warp and ROCK or TOP
      elseif floor and mountain and f < 0.08 and t >= 0.45 then
        k = TOP
      elseif not c.walk and not mountain and t + f < 0.9 and s.gTop <= 4 then
        k = UNKNOWN       -- a roof drawn over the rock behind it
      elseif floor or (not mountain and t + f < 0.9) then
        k = GROUND
      elseif G and T.BOULDER_FOOT[m] and y > 0 and band[at(x, y - 1)] then
        k = ROCK
      elseif G and T.BOULDER[m] then
        k = TOP
      elseif t + f < 0.25 then
        k = GROUND
      elseif s.faceLow < 0.08 * 256 and t >= 0.45 then
        k = TOP
      else
        k = ROCK
      end
      if (k == TOP or k == ROCK) and (s.rim >= 3 or s.gTop >= 12) then rim[i] = true end
      if c.ledge or c.berry or (G and T.DIRT[m]) then
        keep[i] = true
        if k == ROCK then k = GROUND; band[i] = nil; rim[i] = nil end
      end
    end
    kind[i] = k
  end

  local function flat(i) return i ~= nil and (kind[i] == TOP or kind[i] == GROUND) end
  local function water(i) return i ~= nil and cells[i].water end
  local function mid(i) return cells[i].m end
  local function isFace(i)
    if band[i] then return false end
    local s = tileOf(i)
    if kind[i] == ROCK and (cells[i].mud or (gen(mid(i)) and T.CARVED_STEPS[mid(i)])) then return true end
    return s ~= nil and s.f >= T.FACE_SHARE
  end

  mark("cells")
  -- ------- 2. runs: columns of rock between two flats, rows of bands
  local runs = {}
  for x = 0, w - 1 do
    for y = 0, h - 2 do
      local hi, nx = at(x, y), at(x, y + 1)
      if flat(hi) and kind[nx] == ROCK and not band[nx] and not water(hi) then
        local k = 1
        while at(x, y + 1 + k) and kind[at(x, y + 1 + k)] == ROCK and not band[at(x, y + 1 + k)] do
          k = k + 1
        end
        local lo = at(x, y + 1 + k)
        if lo and flat(lo) and not rim[lo] then
          local list = {}
          for j = 0, k - 1 do list[#list + 1] = at(x, y + 1 + j) end
          runs[#runs + 1] = { d = "S", hi = hi, cells = list, lo = lo }
        end
      end
    end
  end
  for y = 0, h - 1 do
    for x = 0, w - 2 do
      local a, nx = at(x, y), at(x + 1, y)
      if flat(a) and band[nx] then
        local side = band[nx]
        local k = 1
        while at(x + 1 + k, y) and band[at(x + 1 + k, y)] == side do k = k + 1 end
        local e = at(x + 1 + k, y)
        if e and flat(e) then
          local list = {}
          for j = 0, k - 1 do list[#list + 1] = at(x + 1 + j, y) end
          if side == "E" and not water(a) then
            runs[#runs + 1] = { d = "E", hi = a, cells = list, lo = e }
          elseif side == "W" and not water(e) then
            local rev = {}
            for j = #list, 1, -1 do rev[#rev + 1] = list[j] end
            runs[#runs + 1] = { d = "W", hi = e, cells = rev, lo = a }
          end
        end
      end
    end
  end

  -- the levels down a run: one a cell, but an upper face end over a lower
  -- one is one diagonal wall
  local function steps(list, d)
    local out, n = {}, 0
    for j, i in ipairs(list) do
      local prev = list[j - 1]
      if d == "S" and prev and gen(mid(prev)) and T.UPPER_END[mid(prev)] and gen(mid(i))
          and T.LOWER_END[mid(i)] and out[#out] == n - 1 then
        out[#out + 1] = out[#out]
      else
        out[#out + 1] = n
        n = n + 1
      end
    end
    return out, n
  end

  mark("runs")
  -- ------- terraces: flat cells joined like to like
  local parent = {}
  local members = {}
  local apart = {}
  local function find(a)
    local p = parent[a]
    if p == nil then parent[a] = a; return a end
    if p == a then return a end
    local r = find(p)
    parent[a] = r
    return r
  end
  for _, r in ipairs(runs) do
    apart[r.hi] = apart[r.hi] or {}
    apart[r.lo] = apart[r.lo] or {}
    apart[r.hi][r.lo] = true
    apart[r.lo][r.hi] = true
  end
  for i in pairs(apart) do members[i] = { i } end
  local function join(a, b)
    local ra, rb = find(a), find(b)
    if ra == rb then return end
    local ma, mb = members[ra], members[rb]
    if ma and mb then
      for _, m in ipairs(ma) do
        for o in pairs(apart[m]) do if find(o) == rb then return end end
      end
      for _, m in ipairs(mb) do
        for o in pairs(apart[m]) do if find(o) == ra then return end end
      end
    end
    parent[rb] = ra
    if mb then
      if not ma then ma = {}; members[ra] = ma end
      for _, m in ipairs(mb) do ma[#ma + 1] = m end
      members[rb] = nil
    end
  end
  local edges = {}
  for i = 1, N do
    local k = kind[i]
    if k == TOP or k == GROUND or k == UNKNOWN then
      find(i)
      local x, y = xy(i)
      for _, n in ipairs({ at(x + 1, y), at(x, y + 1) }) do
        local nk = kind[n]
        local ok = true
        if k == TOP then
          if nk ~= TOP or (n == at(x, y + 1) and rim[n]) then ok = false end
        elseif nk ~= GROUND and nk ~= UNKNOWN then
          ok = false
        end
        if ok and cells[i].falls and not cells[n].falls and n == at(x, y + 1) then ok = false end
        if ok then
          local wa, wb = water(i), water(n)
          local rank
          if (wa and wb) or (k == GROUND and nk == GROUND and cells[i].walk and cells[n].walk
              and not wa and not wb) then
            rank = 0
          elseif mid(i) < 0x200 and mid(n) < 0x200 then
            rank = 1
          else
            rank = 2
          end
          if wa ~= wb then rank = rank + 3 end
          edges[#edges + 1] = { rank, i, n }
        end
      end
    end
  end
  table.sort(edges, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[3] < b[3]
  end)
  for _, e in ipairs(edges) do join(e[2], e[3]) end
  local comp = {}          -- flat cell -> terrace id
  local treeGround = {}    -- unknown cell -> terrace it was joined to
  for i = 1, N do
    if parent[i] ~= nil then
      if kind[i] == UNKNOWN then treeGround[i] = find(i) else comp[i] = find(i) end
    end
  end

  mark("terraces")
  -- ------- levels: votes, greatest first
  local vote, hidden, voteKeys = {}, {}, {}
  for _, r in ipairs(runs) do
    local a, b = comp[r.hi], comp[r.lo]
    if a and b and a ~= b then
      local head = false
      if r.d ~= "S" then
        for _, i in ipairs(r.cells) do if rim[i] then head = true end end
      end
      local _, n = steps(r.cells, r.d)
      local key = a .. ":" .. b .. ":" .. n
      if not vote[key] then
        vote[key] = 0
        hidden[key] = 0
        voteKeys[#voteKeys + 1] = { key = key, a = a, b = b, k = n }
      end
      vote[key] = vote[key] + (head and 1 or 2)
      if r.d == "S" then
        local lx, ly = xy(r.lo)
        local below = at(lx, ly + 1)
        if (cells[r.lo].m >= 0x200 and not cells[r.lo].walk) or (below and kind[below] == UNKNOWN) then
          hidden[key] = hidden[key] + 1
        end
      end
    end
  end
  local function weight(v)
    local n = vote[v.key]
    local wgt = n
    if hidden[v.key] * 2 >= n then wgt = wgt * 0.25 end
    return wgt
  end
  table.sort(voteKeys, function(p, q)
    local wp, wq = weight(p), weight(q)
    if wp ~= wq then return wp > wq end
    if p.k ~= q.k then return p.k < q.k end
    return p.key < q.key
  end)
  local off = Offsets()
  for _, v in ipairs(voteKeys) do off.join(v.a, v.b, v.k * L) end
  -- a rim's lip: the terrace it starts stands a level over the one behind
  local lips, lipKeys = {}, {}
  local behind = {}
  for i, t in pairs(treeGround) do behind[i] = t end
  for i, t in pairs(comp) do behind[i] = t end
  for i in pairs(rim) do
    local x, y = xy(i)
    local n = at(x, y - 1)
    if comp[i] and n and behind[n] and comp[i] ~= behind[n] then
      local key = comp[i] .. ":" .. behind[n]
      if not lips[key] then lips[key] = 0; lipKeys[#lipKeys + 1] = { key = key, a = comp[i], b = behind[n] } end
      lips[key] = lips[key] + 1
    end
  end
  table.sort(lipKeys, function(p, q)
    if lips[p.key] ~= lips[q.key] then return lips[p.key] > lips[q.key] end
    return p.key < q.key
  end)
  for _, v in ipairs(lipKeys) do off.join(v.a, v.b, L) end

  -- each block of terraces the votes tie: its biggest ground at 0
  local size, kindOf = {}, {}
  for i, t in pairs(comp) do
    size[t] = (size[t] or 0) + 1
    kindOf[t] = kindOf[t] or kind[i]
  end
  local roots = {}
  for t in pairs(size) do
    local r = off.find(t)
    roots[r] = roots[r] or {}
    table.insert(roots[r], t)
  end
  local level = {}
  for _, list in pairs(roots) do
    local ref, best = nil, -1
    for _, t in ipairs(list) do
      local score = size[t] + (kindOf[t] == GROUND and 1e6 or 0)
      if score > best or (score == best and t < ref) then ref, best = t, score end
    end
    local _, refOff = off.find(ref)
    for _, t in ipairs(list) do
      local _, o = off.find(t)
      level[t] = o - refOff
    end
  end
  -- keep the lowest ground of the map at 0 or above: what is under it is
  -- never drawn
  local function levelOf(i) return comp[i] and level[comp[i]] or nil end

  mark("levels")
  -- ------- 3. the level each rock cell hangs from
  local U = {}
  local counted = {}
  for _, r in ipairs(runs) do
    if comp[r.hi] and comp[r.lo] then
      local top, bottom = level[comp[r.hi]], level[comp[r.lo]]
      if top > bottom then
        local idx = steps(r.cells, r.d)
        for j, i in ipairs(r.cells) do
          local u = math.max(top - L * idx[j], bottom + L)
          if not U[i] or u > U[i] then U[i] = u end
          counted[i] = true
        end
      end
    end
  end
  -- a ridge drawn with bands alone: each flank counts up to the crest
  for y = 0, h - 1 do
    for x = 0, w - 2 do
      local a = at(x, y)
      if comp[a] and band[at(x + 1, y)] == "W" then
        local k = 1
        while at(x + 1 + k, y) and band[at(x + 1 + k, y)] == "W" do k = k + 1 end
        if at(x + 1 + k, y) and band[at(x + 1 + k, y)] == "E" then
          local j = 1
          while at(x + 1 + k + j, y) and band[at(x + 1 + k + j, y)] == "E" do j = j + 1 end
          local e = at(x + 1 + k + j, y)
          if e and comp[e] then
            local crest = math.max(levelOf(a) + L * k, levelOf(e) + L * j)
            for q = 0, k - 1 do
              local i = at(x + 1 + q, y)
              if not U[i] then U[i] = crest - L * (k - 1 - q) end
              counted[i] = true
            end
            for q = 0, j - 1 do
              local i = at(x + 1 + k + q, y)
              if not U[i] then U[i] = crest - L * q end
              counted[i] = true
            end
          end
        end
      end
    end
  end
  -- a flank climbing off the map's edge counts up from its foot
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local a = at(x, y)
      if comp[a] then
        for _, sd in ipairs({ { "W", 1 }, { "E", -1 } }) do
          local side, step = sd[1], sd[2]
          local k, run = 1, {}
          while at(x + step * k, y) and band[at(x + step * k, y)] == side do
            run[#run + 1] = at(x + step * k, y)
            k = k + 1
          end
          if #run > 0 and not at(x + step * k, y) then
            for q, i in ipairs(run) do
              if not U[i] then U[i] = levelOf(a) + L * q; counted[i] = true end
            end
          end
        end
      end
    end
  end
  -- bands down a column are one band
  local changed = true
  while changed do
    changed = false
    for i, side in pairs(band) do
      if not U[i] then
        local x, y = xy(i)
        for _, n in ipairs({ at(x, y - 1), at(x, y + 1) }) do
          if n and band[n] == side and U[n] then U[i] = U[n]; changed = true; break end
        end
      end
    end
  end
  -- the rest from what is round them
  local todo = {}
  for i = 1, N do if kind[i] == ROCK and not U[i] then todo[#todo + 1] = i end end
  for _ = 1, 16 do
    local left = {}
    for _, i in ipairs(todo) do
      local x, y = xy(i)
      local side = band[i]
      local high = side == "E" and at(x - 1, y) or side == "W" and at(x + 1, y) or at(x, y - 1)
      local under = (side or (at(x, y - 1) and band[at(x, y - 1)])) and 0 or -L
      local tiers = {
        { { high, 0, under } },
        { { at(x - 1, y), 0, 0 }, { at(x + 1, y), 0, 0 } },
        { { at(x, y + 1), L, L } },
      }
      if side then
        table.insert(tiers[2], { at(x, y - 1), 0, 0 })
        table.insert(tiers[2], { at(x, y + 1), 0, 0 })
      end
      local got
      for _, tier in ipairs(tiers) do
        local best
        for _, cand in ipairs(tier) do
          local n = cand[1]
          local v
          if n and comp[n] then v = level[comp[n]] + cand[2]
          elseif n and U[n] then v = U[n] + cand[3] end
          if v and (not best or v > best) then best = v end
        end
        if best then got = best break end
      end
      if got then U[i] = got else left[#left + 1] = i end
    end
    if #left == #todo then break end
    todo = left
  end
  for _, i in ipairs(todo) do U[i] = L end
  -- what nothing counted stays within the levels round it
  for i = 1, N do
    if kind[i] == ROCK and not counted[i] then
      local x, y = xy(i)
      local lo, hi
      for dy = -2, 2 do
        for dx = -2, 2 do
          local n = at(x + dx, y + dy)
          local v = n and levelOf(n)
          if v then
            if not lo or v < lo then lo = v end
            if not hi or v > hi then hi = v end
          end
        end
      end
      if lo then U[i] = math.max(lo, math.min(hi, U[i])) end
    end
  end

  mark("upper")
  -- trees, boulders, props: a patch stands at the lowest ground beside it
  local unknownLevel = {}
  local seen = {}
  for start = 1, N do
    if kind[start] == UNKNOWN and not seen[start] then
      local patch, stack = {}, { start }
      seen[start] = true
      while #stack > 0 do
        local i = table.remove(stack)
        patch[#patch + 1] = i
        local x, y = xy(i)
        for _, n in ipairs({ at(x - 1, y), at(x + 1, y), at(x, y - 1), at(x, y + 1) }) do
          if n and kind[n] == UNKNOWN and not seen[n] then seen[n] = true; stack[#stack + 1] = n end
        end
      end
      local lowest, highest
      for _, i in ipairs(patch) do
        local x, y = xy(i)
        for _, n in ipairs({ at(x - 1, y), at(x + 1, y), at(x, y - 1), at(x, y + 1) }) do
          -- a rim's back is no ground for what stands behind it
          local back = n == at(x, y + 1) and rim[n] and kind[n] == TOP
          local v = n and not back and levelOf(n)
          if v then
            if not lowest or v < lowest then lowest = v end
            if not highest or v > highest then highest = v end
          end
        end
      end
      local lv = lowest
      if not lv and treeGround[start] then lv = level[treeGround[start]] end
      for _, i in ipairs(patch) do unknownLevel[i] = lv or 0 end
    end
  end

  mark("unknown")
  -- ------- 4. pieces, settled
  local out = {}          -- i -> { kind, top }
  local pref = {}
  local fixed = {}
  for i = 1, N do
    local k = kind[i]
    if k == TOP or k == GROUND then
      out[i] = { "F", levelOf(i) or 0 }
      fixed[i] = true
      if gen(mid(i)) and T.BOULDER_HEAD[mid(i)] then
        local x, y = xy(i)
        for _, ns in ipairs({ { at(x + 1, y), "W" }, { at(x - 1, y), "E" } }) do
          local n = ns[1]
          if n and kind[n] == TOP and levelOf(n) == levelOf(i) + L then out[i] = { ns[2], levelOf(n) } end
        end
      end
    elseif k == UNKNOWN then
      out[i] = { "F", unknownLevel[i] or 0 }
      fixed[i] = true
    elseif band[i] then
      local x, y = xy(i)
      local side = band[i]
      local hi = side == "W" and at(x + 1, y) or at(x - 1, y)
      local lo = side == "W" and at(x - 1, y) or at(x + 1, y)
      if hi and lo and comp[hi] and comp[lo] and levelOf(hi) <= levelOf(lo) then
        out[i] = { "F", levelOf(hi) }
        fixed[i] = true
      else
        pref[i] = side
        out[i] = { side, U[i] or L }
      end
    else
      pref[i] = isFace(i) and "S" or "F"
      out[i] = { pref[i], U[i] or L }
    end
  end

  local C = T.COST
  local KF = { F = "F", S = "S", W = "W", E = "E", W2 = "W", E2 = "E",
    cSE = "c", cSW = "c", vSE = "v", vSW = "v" }
  local abs, max = math.abs, math.max
  local SAMPLES = 5
  -- the cost of an edge, a the north / west piece's, b the other's
  local function edgeCost(a0, a1, b0, b1, back)
    local total = 0
    for s = 0, SAMPLES - 1 do
      local t = s / (SAMPLES - 1)
      local p, q = a0 + (a1 - a0) * t, b0 + (b1 - b0) * t
      local d = abs(p - q)
      if d >= 0.5 then
        local k = 1 + 0.5 * (d / L - 1)
        if back == nil then total = total + 0.5 * k
        elseif q > p then total = total + k * back
        else total = total + k end
      end
    end
    return total / SAMPLES
  end
  local pit = C.PITS[1][1]
  local function kindAt(n)
    local o = out[n]
    if o and not keep[n] then return o[1] end
    return "F"
  end
  -- neighbours: west, east, north, south
  local NW_, NE_, NN_, NS_ = {}, {}, {}, {}
  local function live(n) return n ~= nil and out[n] ~= nil and kind[n] ~= UNKNOWN end
  local function cost(i, pk, ptop)
    local total = 0
    local pf = KF[pk]
    -- west: the neighbour is the west one (p), this cell the east one (q)
    local n = NW_[i]
    if n then
      local a0, a1 = edge(pk, ptop, "W", L)
      local b0, b1 = edge(out[n][1], out[n][2], "E", L)
      if keep[n] and (b0 - a0 > 0.5 or b1 - a1 > 0.5) then total = total + C.KEPT end
      local kw = KF[kindAt(n)]
      if (kw == "W" and max(b0 - a0, b1 - a1) > 0.5) or (pf == "E" and max(a0 - b0, a1 - b1) > 0.5) then
        total = total + C.FIN
      end
      total = total + edgeCost(b0, b1, a0, a1, nil)
    end
    n = NE_[i]
    if n then
      local a0, a1 = edge(pk, ptop, "E", L)
      local b0, b1 = edge(out[n][1], out[n][2], "W", L)
      if keep[n] and (b0 - a0 > 0.5 or b1 - a1 > 0.5) then total = total + C.KEPT end
      local ke = KF[kindAt(n)]
      if (pf == "W" and max(a0 - b0, a1 - b1) > 0.5) or (ke == "E" and max(b0 - a0, b1 - a1) > 0.5) then
        total = total + C.FIN
      end
      total = total + edgeCost(a0, a1, b0, b1, nil)
    end
    n = NN_[i]
    if n then
      local a0, a1 = edge(pk, ptop, "N", L)
      local b0, b1 = edge(out[n][1], out[n][2], "S", L)
      if keep[n] and (b0 - a0 > 0.5 or b1 - a1 > 0.5) then total = total + C.KEPT end
      local north, south = kindAt(n), pk
      local back = (north == "F" or (north ~= "S" and south == "F")) and C.BACK or pit
      total = total + edgeCost(b0, b1, a0, a1, back)
    end
    n = NS_[i]
    if n then
      local a0, a1 = edge(pk, ptop, "S", L)
      local b0, b1 = edge(out[n][1], out[n][2], "N", L)
      if keep[n] and (b0 - a0 > 0.5 or b1 - a1 > 0.5) then total = total + C.KEPT end
      local north, south = pk, kindAt(n)
      local back = (north == "F" or (north ~= "S" and south == "F")) and C.BACK or pit
      total = total + edgeCost(a0, a1, b0, b1, back)
    end
    total = total + C.OFF_LEVEL * abs(ptop - (U[i] or ptop)) / L
    if IS_CORNER[pk] then total = total + C.CORNER
    elseif pref[i] and pf ~= pref[i] then total = total + C.OTHER_KIND
    elseif pk == "W2" or pk == "E2" then total = total + C.STEEP end
    return total
  end
  local free = {}
  for i = 1, N do
    if out[i] and not fixed[i] and not keep[i] and (kind[i] == ROCK or kind[i] == TOP) then
      free[#free + 1] = i
      local x, y = xy(i)
      local n = at(x - 1, y); NW_[i] = live(n) and n or nil
      n = at(x + 1, y); NE_[i] = live(n) and n or nil
      n = at(x, y - 1); NN_[i] = live(n) and n or nil
      n = at(x, y + 1); NS_[i] = live(n) and n or nil
    end
  end
  local ROCK_KINDS = { "F", "S", CORNERS[1], CORNERS[2], CORNERS[3], CORNERS[4] }
  local BAND_KINDS = { W = { "W", "W2" }, E = { "E", "E2" } }
  local tops = {}
  for _, stage in ipairs(C.PITS) do
    pit = stage[1]
    local dirty = {}
    for _, i in ipairs(free) do dirty[i] = true end
    for _ = 1, stage[2] do
      local moved = 0
      local nextDirty = {}
      for _, i in ipairs(free) do
        if dirty[i] then
          local cur = out[i]
          local kinds = band[i] and BAND_KINDS[band[i]] or ROCK_KINDS
          local u = U[i] or cur[2]
          local nt = 0
          for d = -2, 2 do nt = nt + 1; tops[nt] = u + L * d end
          local best, bestCost = nil, cost(i, cur[1], cur[2])
          for ki = 1, #kinds do
            local k2 = kinds[ki]
            for ti = 1, nt + 1 do
              local t = ti <= nt and tops[ti] or cur[2]
              if not (k2 == cur[1] and t == cur[2]) then
                local cc = cost(i, k2, t)
                if cc < bestCost - 1e-6 then best, bestCost = { k2, t }, cc end
              end
            end
          end
          if best then
            out[i] = best
            moved = moved + 1
            nextDirty[i] = true
            for _, n in ipairs({ NW_[i], NE_[i], NN_[i], NS_[i] }) do nextDirty[n] = true end
          end
        end
      end
      dirty = nextDirty
      if moved == 0 then break end
    end
  end

  mark("settle")
  if marks then
    local out = {}
    for j = 2, #marks do out[#out + 1] = ("%s %.0fms"):format(marks[j][1], (marks[j][2] - marks[j - 1][2]) * 1000) end
    print("terrain " .. table.concat(out, ", "))
  end
  local result = { kind = {}, top = {}, read = kind, band = band, rim = rim, keep = keep }
  for i = 1, N do
    local o = out[i]
    result.kind[i] = o and o[1] or "F"
    result.top[i] = o and o[2] or 0
  end
  return result
end

return Terrain
