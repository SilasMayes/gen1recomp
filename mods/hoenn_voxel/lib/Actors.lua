-- The actors stand as upright cards.  Each is drawn by the engine's own
-- path into a slot of an offscreen sheet, then placed as a vertical quad at
-- its foot: a sprite pixel d above the foot stands d higher at the foot's z,
-- which is the lift identity for an upright surface, so at 45 degrees every
-- actor is where the 2D field draws it.
local lib = ...
local Source = lib("Source")

local Actors = {}

local SLOT = 96                 -- a slot's side, pixels
local AX, AY = 48, 84           -- where the actor's cell-bottom point lands
local COLS = 10
local SHEET = SLOT * COLS       -- 960 x 960: 100 slots
local BIAS = 0.02               -- toward the camera per later actor (draw order)

local sheet
local mesh, meshCap = nil, 0

local function ensureSheet()
  if not sheet then
    sheet = love.graphics.newCanvas(SHEET, SHEET, { dpiscale = 1 })
    sheet:setFilter("nearest", "nearest")
  end
  return sheet
end

--- Draw the frame's actors into the sheet.  Returns the cards to place:
-- { x, foot, lift, slot } in the absolute frame.
function Actors.collect(ctx)
  local list = ctx.actors and ctx.actors() or {}
  local door = ctx.door and ctx.door()
  local cards = {}
  if #list == 0 and not door then return cards end
  ensureSheet()
  love.graphics.push("all")
  love.graphics.setCanvas(sheet)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.origin()
  love.graphics.setShader()
  love.graphics.setColor(1, 1, 1, 1)
  local function add(e, kind)
    local n = #cards
    if n >= COLS * COLS then return end
    local sx, sy = (n % COLS) * SLOT, math.floor(n / COLS) * SLOT
    love.graphics.setScissor(sx, sy, SLOT, SLOT)
    local ok = pcall(e.draw, sx + AX, sy + AY)
    love.graphics.setScissor()
    love.graphics.setColor(1, 1, 1, 1)
    if ok then
      local x, foot = Source.toAbs(e.x, e.ground or e.y)
      cards[#cards + 1] = { x = x, foot = foot, lift = (e.ground or e.y) - e.y,
        slot = n, kind = kind or e.kind, over = e.over,
        elevation = (kind or e.kind) == "player" and ctx.player and ctx.player.elevation or nil }
    end
  end
  for _, e in ipairs(list) do add(e) end
  if door then add(door, "door") end
  love.graphics.pop()
  return cards
end

--- Place the cards: heightAt(x, z) is the ground's height under a foot.
function Actors.draw(cards, heightAt)
  if #cards == 0 then return end
  local verts = {}
  local inv = 1 / SHEET
  for i, c in ipairs(cards) do
    local g = heightAt(c.x, c.foot, c.elevation)
    local h = g + c.lift
    local z = c.foot + g + i * BIAS
    if c.kind == "door" then z = z + 0.3 end
    local sx, sy = (c.slot % COLS) * SLOT, math.floor(c.slot / COLS) * SLOT
    local x0, x1 = c.x - AX, c.x - AX + SLOT
    local yTop, yBot = h + AY, h + AY - SLOT
    local s0, s1 = sx * inv, (sx + SLOT) * inv
    local t0, t1 = sy * inv, (sy + SLOT) * inv
    local a = { x0, yTop, z, s0, t0, 1, 1, 1, 1 }
    local b = { x1, yTop, z, s1, t0, 1, 1, 1, 1 }
    local cc = { x1, yBot, z, s1, t1, 1, 1, 1, 1 }
    local d = { x0, yBot, z, s0, t1, 1, 1, 1, 1 }
    verts[#verts + 1] = a; verts[#verts + 1] = b; verts[#verts + 1] = cc
    verts[#verts + 1] = a; verts[#verts + 1] = cc; verts[#verts + 1] = d
  end
  if not mesh or meshCap < #verts then
    if mesh then mesh:release() end
    meshCap = math.max(#verts, 64 * 6)
    mesh = love.graphics.newMesh(lib("World").FORMAT, meshCap, "triangles", "stream")
  end
  mesh:setVertices(verts)
  mesh:setDrawRange(1, #verts)
  mesh:setTexture(sheet)
  love.graphics.draw(mesh)
end

return Actors
