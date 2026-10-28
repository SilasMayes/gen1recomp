-- Everything that moves, stood up in the diorama.
--
-- Each frame the engine's own draw path paints every actor (ctx.actors) and
-- the door animation (ctx.door) into cells of one sprite sheet, foot on a
-- known point.  The scene then stands a card per actor at its foot, textured
-- from that cell.  Nothing about an actor's look is re-implemented here, so
-- palettes, poses, the follower, field effects and other mods' actors come
-- through exactly as the 2D field draws them.
local lib = ...
local Mesher = lib("Mesher")

local Actors = {}
Actors.__index = Actors

local CELL_W, CELL_H = 64, 80    -- one actor's cell in the sheet
local FOOT_X, FOOT_Y = 32, 72    -- where its foot lands inside the cell
local COLS = 16

function Actors.new()
  return setmetatable({ canvas = nil, rows = 0, cards = {}, mesh = nil, capacity = 0 }, Actors)
end

function Actors:release()
  if self.canvas and self.canvas.release then pcall(self.canvas.release, self.canvas) end
  if self.mesh and self.mesh.release then pcall(self.mesh.release, self.mesh) end
  if self.shadowMesh and self.shadowMesh.release then pcall(self.shadowMesh.release, self.shadowMesh) end
  self.canvas, self.mesh, self.rows, self.capacity = nil, nil, 0, 0
  self.shadowMesh, self.shadowCap = nil, 0
end

local function ensureCanvas(self, n)
  local rows = math.max(2, math.ceil(n / COLS))
  if self.canvas and self.rows >= rows then return self.canvas end
  if self.canvas and self.canvas.release then self.canvas:release() end
  self.rows = rows
  self.canvas = love.graphics.newCanvas(COLS * CELL_W, rows * CELL_H, { dpiscale = 1 })
  self.canvas:setFilter("nearest", "nearest")
  return self.canvas
end

--- Paint this frame's actors into the sheet and lay out their cards.
-- `ox, oy` move a current-map position into the diorama's absolute frame;
-- `heightAt(x, z)`, when given, is the height of the ground there
-- (absolute frame, before the slide): an actor on raised ground stands on
-- it, moved as far south as it is lifted (Relief.lua).
function Actors:prepare(ctx, ox, oy, heightAt)
  local entries = ctx.actors and ctx.actors() or {}
  local door = ctx.door and ctx.door() or nil
  local list = {}
  for i = 1, #entries do
    -- the field's own jump shadow is a sprite lying on the ground; the
    -- diorama casts its own blob shadow instead of standing it up
    if entries[i].kind ~= "field_effect_shadow" then list[#list + 1] = entries[i] end
  end
  if door then
    list[#list + 1] = { x = door.x, y = door.y, ground = door.y, kind = "door",
      draw = door.draw, cy = door.cy }
  end
  local cards = self.cards
  for i = #cards, 1, -1 do cards[i] = nil end
  if #list == 0 then return cards end

  local canvas = ensureCanvas(self, #list)
  local G = love.graphics
  G.push("all")
  G.setCanvas(canvas)
  G.clear(0, 0, 0, 0)
  G.origin()
  G.setShader()
  G.setBlendMode("alpha")
  G.setColor(1, 1, 1, 1)
  for i, e in ipairs(list) do
    local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
    local cx, cy = col * CELL_W, row * CELL_H
    G.setScissor(cx, cy, CELL_W, CELL_H)
    local ok = pcall(e.draw, cx + FOOT_X, cy + FOOT_Y)
    G.setScissor()
    G.setColor(1, 1, 1, 1)
    if ok then
      local lift = (e.ground or e.y) - e.y
      -- stand on the middle of the cell the actor occupies; a door sits a
      -- hair in front of the facade it belongs to
      local z = (e.ground or e.y) - 8
      if e.kind == "door" then z = (e.cy + 1) * 16 + 0.1 end
      local k = e.kind
      local base = heightAt and heightAt(e.x + ox, (e.ground or e.y) - 8 + oy) or 0
      cards[#cards + 1] = {
        x = e.x + ox, z = z + oy + base, lift = lift, base = base,
        u = cx, v = cy, over = e.over,
        -- people cast a blob shadow; doors and field effects do not
        shadow = k == "player" or k == "npc" or k == "follower",
      }
    end
  end
  G.pop()
  return cards
end

--- One mesh of upright cards for the prepared actors.
function Actors:mesh_(cards)
  local W, H = self.canvas:getWidth(), self.canvas:getHeight()
  local verts, idx = {}, {}
  for _, c in ipairs(cards) do
    local x0, x1 = c.x - FOOT_X, c.x + (CELL_W - FOOT_X)
    local yb = c.lift + (c.base or 0) - (CELL_H - FOOT_Y)
    local yt = c.lift + (c.base or 0) + FOOT_Y
    local u0, v0 = c.u / W, c.v / H
    local u1, v1 = (c.u + CELL_W) / W, (c.v + CELL_H) / H
    local b = #verts
    verts[b + 1] = { x0, yt, c.z, u0, v0, 1, 1, 1, 1 }
    verts[b + 2] = { x1, yt, c.z, u1, v0, 1, 1, 1, 1 }
    verts[b + 3] = { x1, yb, c.z, u1, v1, 1, 1, 1, 1 }
    verts[b + 4] = { x0, yb, c.z, u0, v1, 1, 1, 1, 1 }
    local n = #idx
    idx[n + 1], idx[n + 2], idx[n + 3] = b + 1, b + 2, b + 3
    idx[n + 4], idx[n + 5], idx[n + 6] = b + 1, b + 3, b + 4
  end
  local need = #verts
  if not self.mesh or self.capacity < need then
    if self.mesh and self.mesh.release then self.mesh:release() end
    self.capacity = math.max(need, 64)
    self.mesh = love.graphics.newMesh(Mesher.FORMAT, self.capacity, "triangles", "dynamic")
  end
  self.mesh:setVertices(verts)
  self.mesh:setVertexMap(idx)
  self.mesh:setDrawRange(1, #idx)
  self.mesh:setTexture(self.canvas)
  return self.mesh
end

function Actors:draw(cards)
  if #cards == 0 or not self.canvas then return end
  love.graphics.draw(self:mesh_(cards))
end

-- A soft dark ellipse, made once.
local function shadowImage()
  local w, h = 32, 16
  local data = love.image.newImageData(w, h)
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local dx, dy = (x + 0.5 - w / 2) / (w / 2), (y + 0.5 - h / 2) / (h / 2)
      local r = math.sqrt(dx * dx + dy * dy)
      local a = r < 1 and (1 - r * r) or 0
      data:setPixel(x, y, 0, 0, 0, a)
    end
  end
  local img = love.graphics.newImage(data)
  img:setFilter("linear", "linear")
  return img
end

--- Blob shadows under the people, on the ground: drawn blended, after the
-- opaque scene and before the cards, so a shadow never hides a sprite.
function Actors:drawShadows(cards)
  local verts, idx = {}, {}
  for _, c in ipairs(cards) do
    if c.shadow then
      local shrink = math.max(0.45, 1 - (c.lift or 0) / 40)
      local hw, hd = 7 * shrink, 3.5 * shrink
      local y = 0.3 + (c.base or 0)
      local b = #verts
      local a = 0.38 * shrink
      verts[b + 1] = { c.x - hw, y, c.z - hd, 0, 0, 1, 1, 1, a }
      verts[b + 2] = { c.x + hw, y, c.z - hd, 1, 0, 1, 1, 1, a }
      verts[b + 3] = { c.x + hw, y, c.z + hd, 1, 1, 1, 1, 1, a }
      verts[b + 4] = { c.x - hw, y, c.z + hd, 0, 1, 1, 1, 1, a }
      local n = #idx
      idx[n + 1], idx[n + 2], idx[n + 3] = b + 1, b + 2, b + 3
      idx[n + 4], idx[n + 5], idx[n + 6] = b + 1, b + 3, b + 4
    end
  end
  if #verts == 0 then return end
  self.shadowTex = self.shadowTex or shadowImage()
  local need = #verts
  if not self.shadowMesh or self.shadowCap < need then
    if self.shadowMesh and self.shadowMesh.release then self.shadowMesh:release() end
    self.shadowCap = math.max(need, 64)
    self.shadowMesh = love.graphics.newMesh(Mesher.FORMAT, self.shadowCap, "triangles", "dynamic")
  end
  self.shadowMesh:setVertices(verts)
  self.shadowMesh:setVertexMap(idx)
  self.shadowMesh:setDrawRange(1, #idx)
  self.shadowMesh:setTexture(self.shadowTex)
  love.graphics.draw(self.shadowMesh)
end

Actors.CELL_W, Actors.CELL_H, Actors.FOOT_X, Actors.FOOT_Y = CELL_W, CELL_H, FOOT_X, FOOT_Y

return Actors
