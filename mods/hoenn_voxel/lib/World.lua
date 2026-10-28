-- The built world: 8 x 8 blocks of cells in the absolute frame (Source.lua),
-- each a handful of meshes, one per texture.  A block is rebuilt when what
-- it was built from changes - a metatile write (the map's revision), the
-- map's analysis, a seam crossing for a block that showed border - and
-- dropped on a warp.
local lib = ...
local Source = lib("Source")
local Builder = lib("Builder")
local Derived = lib("Derived")

local World = {}

World.CHUNK = 8
World.BUDGET = 0.006            -- seconds of building per frame once the view is up

local FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexColor", "byte", 4 },
}
World.FORMAT = FORMAT

local chunks = {}
local epoch = -1
local stats = { chunks = 0, tris = 0, built = 0 }
World.stats = stats

local scene         -- set by World.configure: what the builder reads

function World.configure(s) scene = s end

local function release(ch)
  for _, m in ipairs(ch.meshes or {}) do
    if m.mesh and m.mesh.release then m.mesh:release() end
  end
  ch.meshes = {}
end

function World.flush()
  for _, ch in pairs(chunks) do release(ch) end
  chunks = {}
end

-- what a block was built from: the maps it touches (one cell round it, for
-- the steps on its edges), their revisions and analyses
local function signature(cx, cy)
  local N = World.CHUNK
  local x0, y0 = cx * N - 1, cy * N - 1
  local x1, y1 = x0 + N + 2, y0 + N + 2
  local parts = {}
  local covered = false
  for id, m in pairs(Source.state.placed) do
    if m.ax < x1 and m.ay < y1 and m.ax + m.width > x0 and m.ay + m.height > y0 then
      parts[#parts + 1] = id .. "@" .. m.ax .. "," .. m.ay .. "#" .. m.revision .. "/" ..
        (scene.version and scene.version(id) or 0)
      if m.ax <= x0 and m.ay <= y0 and m.ax + m.width >= x1 and m.ay + m.height >= y1 then
        covered = true
      end
    end
  end
  table.sort(parts)
  -- a block showing border follows whatever map was read last
  if not covered and scene.stamp then parts[#parts + 1] = "B" .. scene.stamp() end
  return table.concat(parts, ";")
end

local function build(cx, cy)
  local N = World.CHUNK
  local b = Builder.new(scene)
  local x0, y0 = cx * N, cy * N
  b:block(x0, y0, x0 + N, y0 + N)
  if scene.models then scene.models(b, x0, y0, x0 + N, y0 + N) end
  local ch = { cx = cx, cy = cy, meshes = {}, missing = b.missing, tris = b.tris }
  -- a block that showed border is stale once the border changes
  for ay = y0 - 1, y0 + N do
    for ax = x0 - 1, x0 + N do
      local c = Source.cell(ax, ay)
      if c.void then ch.void = true break end
    end
    if ch.void then break end
  end
  for _, key in ipairs(b.order) do
    local batch = b.batches[key]
    if #batch.verts > 0 then
      local mesh = love.graphics.newMesh(FORMAT, batch.verts, "triangles", "static")
      ch.meshes[#ch.meshes + 1] = { kind = batch.kind, pair = batch.pair, layer = batch.layer,
        page = batch.page, mesh = mesh }
    end
  end
  stats.built = stats.built + 1
  return ch
end

local function stale(ch, sig)
  if ch.sig ~= sig then return true end
  if ch.void and ch.seam ~= Source.state.seam then return true end
  if ch.missing > 0 then return true end
  return false
end

--- Make sure the blocks covering cells x0..x1, y0..y1 are built (the ones
-- nearest the focus first), within the frame's budget once `ready` is true.
-- Returns the list of blocks to draw and whether all of them are current.
function World.update(x0, y0, x1, y1, fx, fy, ready)
  if epoch ~= Source.state.epoch then
    World.flush()
    epoch = Source.state.epoch
  end
  local N = World.CHUNK
  local cx0, cy0 = math.floor(x0 / N), math.floor(y0 / N)
  local cx1, cy1 = math.floor(x1 / N), math.floor(y1 / N)
  local want = {}
  for cy = cy0, cy1 do
    for cx = cx0, cx1 do
      local dx, dy = (cx + 0.5) * N - fx, (cy + 0.5) * N - fy
      want[#want + 1] = { cx = cx, cy = cy, d = dx * dx + dy * dy }
    end
  end
  table.sort(want, function(a, b) return a.d < b.d end)
  local t0 = love.timer and love.timer.getTime() or os.clock()
  local list, current = {}, true
  for _, w in ipairs(want) do
    local key = w.cx .. "," .. w.cy
    local ch = chunks[key]
    local sig = signature(w.cx, w.cy)
    if not ch or stale(ch, sig) then
      local now = love.timer and love.timer.getTime() or os.clock()
      if not ready or now - t0 < World.BUDGET then
        if ch then release(ch) end
        ch = build(w.cx, w.cy)
        ch.sig, ch.seam = sig, Source.state.seam
        chunks[key] = ch
        if ch.missing > 0 then current = false end
      else
        current = false
      end
    end
    if ch then
      ch.used = true
      list[#list + 1] = ch
    end
  end
  -- forget blocks well out of view
  local n, tris = 0, 0
  for key, ch in pairs(chunks) do
    if ch.cx < cx0 - 3 or ch.cx > cx1 + 3 or ch.cy < cy0 - 3 or ch.cy > cy1 + 3 then
      release(ch)
      chunks[key] = nil
    else
      n = n + 1
      tris = tris + (ch.tris or 0)
    end
  end
  stats.chunks, stats.tris = n, tris
  return list, current
end

--- Draw the blocks' meshes with whatever atlas images are current.
function World.draw(list)
  for _, ch in ipairs(list) do
    for _, m in ipairs(ch.meshes) do
      local img
      if m.kind == "derived" then
        img = Derived.image(m.page)
      else
        local view = Source.atlas(m.pair)
        img = view and (m.layer == "over" and view.overImage or view.image)
      end
      if img then
        m.mesh:setTexture(img)
        love.graphics.draw(m.mesh)
      end
    end
  end
end

return World
