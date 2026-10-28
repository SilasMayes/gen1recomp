-- The height of the ground: mountains and cliffs counted off the drawing.
--
-- Hoenn's General tileset draws a mountain with a handful of square pieces,
-- and every one of them spans exactly one level (16 pixels):
--
--   top    flat: the terrace's surface (the game tags it MOUNTAIN_TOP)
--   face   the south wall, vertical: one tile down is one level down
--   band   a west or east side, a 45 degree slope one tile wide: one tile
--          across is one level down
--
-- So heights are counted, not guessed.  The walkable ground and the tops are
-- cut into regions (ground joins ground, top joins top, water joins water).
-- A column of k face tiles between two regions says the upper one stands k
-- levels over the lower; a row of k bands says the same across.  The votes
-- are taken most-agreed first; one that contradicts what is decided is
-- dropped (it leaves a wall, never a bent surface).  Regions with nothing
-- between them but trees, houses, ledges or a shore are one level.  The
-- largest ground is level 0.
--
-- Heights live on the corners of the cells.  A face tile hangs from its
-- north edge (its north corners a level over its south ones), a band from
-- its high side.  Lifted by h and moved h south, a point of the drawing is
-- seen at 45 degrees exactly where the 2D field drew it (Hip.lua), so a cell
-- whose corners are a level apart north to south is a vertical wall, east to
-- west a 45 degree slope, and the whole relief is exact at 45 degrees.
--
-- The tile roles follow Emerald 3DS's mountains (ZallaxDev/emerald-3ds,
-- MIT: voxel_terraces.py, gen_voxel_relief.py), which counted Hoenn's levels
-- this way first; the solve here is a simpler one.
--
-- Pure Lua.  `sample(x, y)` gives a map cell { mid, pair, walk, beh }.
local Relief = {}

Relief.LEVEL = 16

local function set(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

-- the General tileset's mountain pieces
local FACE = set({ 0x07c, 0x0a9, 0x09f, 0x0a7, 0x091, 0x079, 0x1b0, 0x0af, 0x0cf, 0x1f0, 0x1f1 })
-- a band whose high side is east (it falls west), and the other way
local BAND_W = set({ 0x070, 0x073, 0x088, 0x06b, 0x080, 0x083, 0x068, 0x172, 0x175, 0x177, 0x17a })
local BAND_E = set({ 0x072, 0x075, 0x0a2, 0x08a, 0x06d, 0x082, 0x084, 0x06a, 0x174, 0x176, 0x17c, 0x0a4 })
local DIRT = set({ 0x113, 0x114, 0x115, 0x14b, 0x14c, 0x14d })
local BOULDER = set({ 0x093, 0x094, 0x09b, 0x09c })
local MOUNTAIN = {}
for m = 0x064, 0x0bf do MOUNTAIN[m] = true end
for m = 0x172, 0x192 do MOUNTAIN[m] = true end
for _, m in ipairs({ 0x1a0, 0x1a8, 0x1b0, 0x1f0, 0x1f1 }) do MOUNTAIN[m] = true end
for m in pairs(FACE) do MOUNTAIN[m] = true end
for m in pairs(DIRT) do MOUNTAIN[m] = nil end
for m in pairs(BOULDER) do MOUNTAIN[m] = nil end
Relief.FACE, Relief.BAND_W, Relief.BAND_E, Relief.MOUNTAIN = FACE, BAND_W, BAND_E, MOUNTAIN

local GENERAL = "gTileset_General"

local function isWater(name)
  if not name then return false end
  if name == "SHALLOW_WATER" or name:find("PUDDLE", 1, true) then return false end
  return name:find("WATER", 1, true) ~= nil or name:find("CURRENT", 1, true) ~= nil
    or name:find("OCEAN", 1, true) ~= nil
end

--- What a cell is to the relief: "ground", "top", "water", "ledge",
-- "rock" (with its role: "face", "bandW", "bandE" or "corner"), "other"
-- (a house, a tree, a sign: it stands on the ground beside it) or "void".
function Relief.classify(c)
  if not c or c.mid == nil or c.void then return "void" end
  local beh = c.beh
  if beh and beh:sub(1, 5) == "JUMP_" then return "ledge" end
  local general = c.pair and c.pair:sub(1, #GENERAL) == GENERAL and c.mid < 0x200
  -- (the tag is the ground's: a tree or a town's own cliff drawn over a
  -- top carries it too, and only what is walked on or the General
  -- tileset's own top piece is a top)
  if beh == "MOUNTAIN_TOP" and (c.walk or (general and MOUNTAIN[c.mid])) then return "top" end
  if general and MOUNTAIN[c.mid] and not isWater(beh) then
    local m = c.mid
    if BAND_W[m] then return "rock", "bandW" end
    if BAND_E[m] then return "rock", "bandE" end
    if FACE[m] then return "rock", "face" end
    return "rock", "corner"
  end
  if isWater(beh) then return "water" end
  if c.walk then return "ground" end
  return "other"
end

-- ------- weighted union-find over region levels

local function newSets()
  return { parent = {}, off = {} }
end

local function find(s, r)
  local p = s.parent[r]
  if p == nil or p == r then return r, 0 end
  local root, po = find(s, p)
  s.parent[r] = root
  s.off[r] = s.off[r] + po
  return root, s.off[r]
end

-- L(a) - L(b) = d; false when it contradicts what is decided
local function join(s, a, b, d)
  local ra, oa = find(s, a)
  local rb, ob = find(s, b)
  if ra == rb then return oa - ob == d end
  s.parent[rb] = ra
  s.off[rb] = oa - ob - d
  return true
end

--- Solve one map.  Returns an object with
--   r.corners(x, y) -> nw, ne, se, sw in pixels, for every cell in the map
--   r.surface(x, y) -> true for a mountain piece that is its own surface
--                      (its corners can differ), false for anything that
--                      just stands at a level
--   r.levels        number of distinct levels (1: the map is flat)
function Relief.solve(sample, w, h)
  local n = w * h
  local cls, role = {}, {}
  local function idx(x, y) return y * w + x + 1 end
  local function inside(x, y) return x >= 0 and y >= 0 and x < w and y < h end
  -- a map whose mountains are drawn with its town's own tiles (Route 112's
  -- red rock, Route 115's beige: their cliffs carry the top's tag) has
  -- levels the General pieces cannot count; it lies flat
  local own, rocks = 0, 0
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local c = sample(x, y)
      local k, r = Relief.classify(c)
      cls[idx(x, y)], role[idx(x, y)] = k, r
      if k == "rock" then rocks = rocks + 1
      elseif c and c.beh == "MOUNTAIN_TOP" and not c.walk and k ~= "top" then own = own + 1 end
    end
  end
  if own > rocks then
    for i = 1, w * h do
      if cls[i] == "rock" or cls[i] == "top" then cls[i], role[i] = "ground", nil end
    end
  end

  -- regions: ground joins ground, top joins top, water joins water, and
  -- what stands joins what stands (a wood, a row of houses: it stands on one
  -- level, which a cliff under it tells even when no ground is in sight)
  local region, size, kindOf = {}, {}, {}
  local nreg = 0
  for i = 1, n do
    local k = cls[i]
    if region[i] == nil and (k == "ground" or k == "top" or k == "water" or k == "other") then
      nreg = nreg + 1
      local stack, count = { i }, 0
      region[i] = nreg
      while #stack > 0 do
        local j = table.remove(stack)
        count = count + 1
        local x, y = (j - 1) % w, math.floor((j - 1) / w)
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          local nx, ny = x + d[1], y + d[2]
          if inside(nx, ny) then
            local q = idx(nx, ny)
            if region[q] == nil and cls[q] == k then
              region[q] = nreg
              stack[#stack + 1] = q
            end
          end
        end
      end
      size[nreg], kindOf[nreg] = count, k
    end
  end
  local function regionAt(x, y)
    if not inside(x, y) then return nil end
    return region[idx(x, y)]
  end
  -- ground, a top or water: what has a level of its own
  local function open_(r) return r ~= nil and kindOf[r] ~= "other" end

  -- votes: { a, b, d } meaning L(a) - L(b) = d, counted
  local tally, order = {}, {}
  local function vote(a, b, d, weight)
    if a == nil or b == nil or a == b then return end
    if a > b then a, b, d = b, a, -d end
    local key = a .. ":" .. b .. ":" .. d
    local v = tally[key]
    if not v then
      v = { a = a, b = b, d = d, w = 0 }
      tally[key] = v
      order[#order + 1] = v
    end
    v.w = v.w + weight
  end
  local HARD, SOFT = 1, 0.001

  -- a column of faces (and their corner pieces) between two regions
  local vruns = {}
  for x = 0, w - 1 do
    local y = 0
    while y < h do
      local i = idx(x, y)
      if cls[i] == "rock" and role[i] ~= "bandW" and role[i] ~= "bandE" then
        local y0 = y
        while y + 1 < h and cls[idx(x, y + 1)] == "rock" and role[idx(x, y + 1)] ~= "bandW"
            and role[idx(x, y + 1)] ~= "bandE" do
          y = y + 1
        end
        local run = { x = x, y0 = y0, y1 = y, n = regionAt(x, y0 - 1), s = regionAt(x, y + 1) }
        vruns[#vruns + 1] = run
        if run.n and run.s then
          if kindOf[run.n] == "water" and kindOf[run.s] == "water" then
            -- rocks in the sea: the sea on both sides is one
            vote(run.n, run.s, 0, HARD)
          elseif open_(run.n) and open_(run.s) then
            vote(run.n, run.s, y - y0 + 1, HARD)
          else
            -- over or under what stands, only the faces count (the corner
            -- pieces of a terrace's diagonal edge stack without rising)
            local faces = 0
            for yy = y0, y do
              if role[idx(x, yy)] == "face" then faces = faces + 1 end
            end
            if faces > 0 then vote(run.n, run.s, faces, HARD) end
          end
        end
      end
      y = y + 1
    end
  end
  -- a row of bands between two regions; two runs back to back (a crest)
  -- stand on the same ground
  local hruns = {}
  for y = 0, h - 1 do
    local x = 0
    while x < w do
      local i = idx(x, y)
      if cls[i] == "rock" and (role[i] == "bandW" or role[i] == "bandE") then
        local r = role[i]
        local x0 = x
        while x + 1 < w and cls[idx(x + 1, y)] == "rock" and role[idx(x + 1, y)] == r do x = x + 1 end
        local run = { y = y, x0 = x0, x1 = x, role = r, west = regionAt(x0 - 1, y), east = regionAt(x + 1, y) }
        hruns[#hruns + 1] = run
        local k = x - x0 + 1
        if run.west and run.east then
          if kindOf[run.west] == "water" and kindOf[run.east] == "water" then
            vote(run.west, run.east, 0, HARD)
          elseif r == "bandW" then vote(run.east, run.west, k, HARD) else vote(run.west, run.east, k, HARD) end
        end
      end
      x = x + 1
    end
  end
  -- what joins two regions at one level: what stands on ground stands at
  -- its level; a ledge; ground beside a top (but not behind it: a top's
  -- north edge is its back, over lower ground); a shore
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local i = idx(x, y)
      local k = cls[i]
      if k == "other" then
        -- (a top south of it has its back to it, as to ground)
        local r = region[i]
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          local q = regionAt(x + d[1], y + d[2])
          if open_(q) and kindOf[q] ~= "water" and not (d[2] == 1 and kindOf[q] == "top") then
            vote(r, q, 0, SOFT)
          end
        end
      elseif k == "ledge" then
        local around = {}
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          local r = regionAt(x + d[1], y + d[2])
          if r and kindOf[r] ~= "water" then around[#around + 1] = r end
        end
        for a = 1, #around do
          for b = a + 1, #around do vote(around[a], around[b], 0, SOFT) end
        end
      elseif k == "ground" or k == "top" then
        local r = region[i]
        local e, s = regionAt(x + 1, y), regionAt(x, y + 1)
        if not open_(e) then e = nil end
        if not open_(s) then s = nil end
        if e and e ~= r and kindOf[e] ~= "water" then vote(r, e, 0, SOFT) end
        if s and s ~= r then
          -- ground south of a top meets its foot; a top south of ground has
          -- its back to it
          if kindOf[s] == "water" then
            vote(r, s, 0, SOFT * 0.5)
          elseif not (k == "ground" and kindOf[s] == "top") then
            vote(r, s, 0, SOFT)
          end
        end
        if e and kindOf[e] == "water" then vote(r, e, 0, SOFT * 0.5) end
      elseif k == "water" then
        local r = region[i]
        local e, s = regionAt(x + 1, y), regionAt(x, y + 1)
        if open_(e) and kindOf[e] ~= "water" then vote(e, r, 0, SOFT * 0.5) end
        if open_(s) and kindOf[s] ~= "water" then vote(s, r, 0, SOFT * 0.5) end
      end
    end
  end

  table.sort(order, function(p, q)
    if p.w ~= q.w then return p.w > q.w end
    if p.a ~= q.a then return p.a < q.a end
    if p.b ~= q.b then return p.b < q.b end
    return p.d < q.d
  end)
  local sets = newSets()
  for r = 1, nreg do sets.parent[r], sets.off[r] = r, 0 end
  for _, v in ipairs(order) do join(sets, v.a, v.b, v.d) end

  -- each set of joined regions: its largest ground is level 0
  local best = {}
  for r = 1, nreg do
    local root, o = find(sets, r)
    local score = size[r] + (kindOf[r] == "ground" and 1e6 or 0)
    local b = best[root]
    if not b or score > b.score then best[root] = { score = score, off = o } end
  end
  local level, grounded = {}, {}
  for r = 1, nreg do
    local root, o = find(sets, r)
    level[r] = o - best[root].off
    if open_(r) then grounded[root] = true end
  end
  -- what stands has a level of its own only joined to some ground (a rock
  -- alone in the sea is no measure of anything)
  for r = 1, nreg do
    if not open_(r) and not grounded[(find(sets, r))] then level[r] = nil end
  end

  -- corners, in levels: nw, ne, se, sw per cell
  local NW, NE, SE, SW = {}, {}, {}, {}
  local surface = {}
  local function setAll(i, v) NW[i], NE[i], SE[i], SW[i] = v, v, v, v end
  for i = 1, n do
    if open_(region[i]) then setAll(i, level[region[i]]) end
  end
  -- faces hang from the ground north of them, a level a tile
  for _, run in ipairs(vruns) do
    local top = run.n and level[run.n]
    local foot = run.s and level[run.s]
    if top and foot and top > foot then
      for y = run.y0, run.y1 do
        local i = idx(run.x, y)
        local up = math.max(top - (y - run.y0), foot)
        local down = math.max(up - 1, foot)
        NW[i], NE[i], SE[i], SW[i] = up, up, down, down
        surface[i] = true
      end
    end
  end
  -- bands from their high side, a level a tile; a crest (bands back to
  -- back over one ground) rises a level a tile from either foot
  for _, run in ipairs(hruns) do
    local k = run.x1 - run.x0 + 1
    local low, high
    if run.role == "bandW" then
      low, high = run.west and level[run.west], run.east and level[run.east]
    else
      low, high = run.east and level[run.east], run.west and level[run.west]
    end
    -- a crest: a run rising east met by one falling east (a rock in the
    -- sea, a ridge) rises from its foot as far as it is wide
    local crest = run.role == "bandW" and inside(run.x1 + 1, run.y)
      and cls[idx(run.x1 + 1, run.y)] == "rock" and role[idx(run.x1 + 1, run.y)] == "bandE"
    local back = run.role == "bandE" and inside(run.x0 - 1, run.y)
      and cls[idx(run.x0 - 1, run.y)] == "rock" and role[idx(run.x0 - 1, run.y)] == "bandW"
    if (crest or back) and low and not high then high = low + k end
    if low and high and high > low then
      for x = run.x0, run.x1 do
        local i = idx(x, run.y)
        local from = run.role == "bandW" and (x - run.x0) or (run.x1 - x)
        local a = math.min(low + from, high)
        local b = math.min(a + 1, high)
        if not surface[i] then
          if run.role == "bandW" then
            NW[i], SW[i], NE[i], SE[i] = a, a, b, b
          else
            NE[i], SE[i], NW[i], SW[i] = a, a, b, b
          end
          surface[i] = true
        end
      end
    end
  end

  -- a row of faces is one wall: a face or a corner piece the column count
  -- left undecided (rock over it, not ground) hangs like the face beside it
  local function hangs(i)
    return surface[i] and NW[i] == NE[i] and SW[i] == SE[i] and NW[i] == SW[i] + 1
  end
  repeat
    local grew = false
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local i = idx(x, y)
        if cls[i] == "rock" and not surface[i] and (role[i] == "face" or role[i] == "corner") then
          -- (unless what is over it ends lower: a corner piece under a
          -- slope turns the face into the side)
          local up = y > 0 and idx(x, y - 1)
          for _, dx in ipairs({ 1, -1 }) do
            local j = inside(x + dx, y) and idx(x + dx, y)
            if j and hangs(j) and role[j] == "face" and not surface[i]
                and not (up and SW[up] ~= nil and (SW[up] ~= NW[j] or SE[up] ~= NE[j])) then
              NW[i], NE[i], SE[i], SW[i] = NW[j], NE[j], SE[j], SW[j]
              surface[i] = true
              grew = true
            end
          end
        end
      end
    end
  until not grew

  -- the rest of the rock (a face's end, a terrace's corner) meets what is
  -- round it: each corner the highest its decided neighbours give that
  -- point, a few passes deep
  local function cornerOf(i, which)
    if which == 1 then return NW[i] elseif which == 2 then return NE[i]
    elseif which == 3 then return SE[i] else return SW[i] end
  end
  for _ = 1, 3 do
    local updates = {}
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local i = idx(x, y)
        if cls[i] == "rock" and not surface[i] then
          -- lattice points: nw (x, y), ne (x+1, y), se (x+1, y+1), sw (x, y+1)
          local pts = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }
          local got, any = {}, false
          for p = 1, 4 do
            local px, py = x + pts[p][1], y + pts[p][2]
            local v
            -- the four cells round lattice point (px, py) and which of
            -- their corners it is
            for _, cc in ipairs({ { px - 1, py - 1, 3 }, { px, py - 1, 4 }, { px, py, 1 }, { px - 1, py, 2 } }) do
              if inside(cc[1], cc[2]) then
                local j = idx(cc[1], cc[2])
                if j ~= i and (surface[j] or open_(region[j])) then
                  local cv = cornerOf(j, cc[3])
                  if cv and (v == nil or cv > v) then v = cv end
                end
              end
            end
            got[p] = v
            if v then any = true end
          end
          if any then updates[#updates + 1] = { i, got } end
        end
      end
    end
    if #updates == 0 then break end
    for _, u in ipairs(updates) do
      local i, got = u[1], u[2]
      local lo = math.huge
      for p = 1, 4 do if got[p] then lo = math.min(lo, got[p]) end end
      for p = 1, 4 do if got[p] == nil then got[p] = lo end end
      NW[i], NE[i], SE[i], SW[i] = got[1], got[2], got[3], got[4]
      surface[i] = true
    end
  end

  -- a piece of rock spans one level at most: it hangs from its highest
  -- corner, and where its foot is lower still a step closes the gap
  for i = 1, n do
    if surface[i] then
      local hi = math.max(NW[i], NE[i], SE[i], SW[i])
      NW[i], NE[i] = math.max(NW[i], hi - 1), math.max(NE[i], hi - 1)
      SE[i], SW[i] = math.max(SE[i], hi - 1), math.max(SW[i], hi - 1)
    end
  end

  -- what stands on the ground (houses, trees, signs, ledges, rock nothing
  -- decided): the level in front of it, down its column; over a cliff's
  -- face, the cliff's top; but between higher ground in front (a top, a
  -- slope: its north edge is its back) and lower ground or water behind,
  -- it stands on that; else the nearest level
  -- (looking no further than the tallest thing that stands: past that, a
  -- mass of rock the tileset does not count is no thing standing)
  local REACH = 6
  local front, behind = {}, {}
  for x = 0, w - 1 do
    local f, b, run = nil, nil, 0
    for y = h - 1, 0, -1 do
      local i = idx(x, y)
      if NW[i] == nil then
        run = run + 1
        if run <= REACH then front[i] = f end
      else
        f, run = { math.max(NW[i], NE[i]), not (surface[i] and math.min(NW[i], NE[i]) > math.max(SW[i], SE[i])) }, 0
      end
    end
    for y = 0, h - 1 do
      local i = idx(x, y)
      if NW[i] == nil then
        behind[i] = b
      else
        b = (not surface[i] and (cls[i] == "ground" or cls[i] == "water")) and NW[i] or nil
      end
    end
  end
  local stand = {}
  for i = 1, n do
    local f, b = front[i], behind[i]
    if f then
      stand[i] = (f[2] and b and b < f[1]) and b or f[1]
    else
      stand[i] = nil
    end
  end
  for i = 1, n do
    if NW[i] == nil and stand[i] ~= nil then setAll(i, stand[i]) end
  end
  -- anything left (rock with nothing round it, cells at the map's top
  -- edge): the nearest decided level, else 0
  local queue, head = {}, 1
  for i = 1, n do if NW[i] ~= nil then queue[#queue + 1] = i end end
  while head <= #queue do
    local i = queue[head]
    head = head + 1
    local x, y = (i - 1) % w, math.floor((i - 1) / w)
    local v = surface[i] and math.min(NW[i], NE[i], SE[i], SW[i]) or NW[i]
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local nx, ny = x + d[1], y + d[2]
      if inside(nx, ny) then
        local q = idx(nx, ny)
        if NW[q] == nil then
          setAll(q, v)
          queue[#queue + 1] = q
        end
      end
    end
  end
  for i = 1, n do if NW[i] == nil then setAll(i, 0) end end

  local seen, levels = {}, 0
  for i = 1, n do
    for _, v in ipairs({ NW[i], NE[i], SE[i], SW[i] }) do
      if not seen[v] then seen[v] = true levels = levels + 1 end
    end
  end

  -- past the map's edge (its border): the level most of that edge has, so
  -- the border lies flat whatever stands along the edge
  local function edgeLevel(cells)
    local count, best, bestN = {}, 0, -1
    for _, i in ipairs(cells) do
      local v = math.min(NW[i], NE[i], SE[i], SW[i])
      count[v] = (count[v] or 0) + 1
    end
    for v, c in pairs(count) do
      if c > bestN or (c == bestN and v < best) then best, bestN = v, c end
    end
    return best
  end
  local north, south, west, east = {}, {}, {}, {}
  for x = 0, w - 1 do north[#north + 1], south[#south + 1] = idx(x, 0), idx(x, h - 1) end
  for y = 0, h - 1 do west[#west + 1], east[#east + 1] = idx(0, y), idx(w - 1, y) end
  local edgeN, edgeS = edgeLevel(north), edgeLevel(south)
  local edgeW, edgeE = edgeLevel(west), edgeLevel(east)

  local L = Relief.LEVEL
  local r = { w = w, h = h, levels = levels, regions = nreg }
  function r.corners(x, y)
    if not inside(x, y) then
      local v
      if y < 0 then v = edgeN elseif y >= h then v = edgeS
      elseif x < 0 then v = edgeW else v = edgeE end
      v = v * L
      return v, v, v, v
    end
    local i = idx(x, y)
    return NW[i] * L, NE[i] * L, SE[i] * L, SW[i] * L
  end
  function r.surface(x, y)
    return inside(x, y) and surface[idx(x, y)] == true
  end
  function r.class(x, y)
    if not inside(x, y) then return "void" end
    return cls[idx(x, y)], role[idx(x, y)]
  end
  return r
end

return Relief
