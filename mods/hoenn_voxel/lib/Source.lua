-- What the mod reads of the game, once per frame, in one place.
--
-- The engine hands cells in current-map space; the mod keeps everything it
-- builds in an ABSOLUTE frame that survives walking over a seam into the
-- next map: abs = cur + anchor.  When the current map changes to one the
-- previous frame had placed at (ox, oy), the anchor moves by that offset and
-- every chunk already built stays where it is.  Any other change (a warp)
-- starts a new frame.
local Source = {}

Source.CELL = 16

local state = {
  anchorX = 0, anchorY = 0,
  mapId = nil,
  placed = {},        -- id -> { id, ax, ay, width, height, revision }
  epoch = 0,          -- bumps on a warp: everything built is stale
  seam = 0,           -- bumps on a seam crossing: void cells are stale
}
Source.state = state

local ctx           -- this frame's
local cellMemo = {}
local memoFrame = 0

--- Bind this frame's ctx.  Returns what changed: "warp", "seam" or nil.
function Source.begin(c)
  ctx = c
  memoFrame = memoFrame + 1
  cellMemo = {}
  local list = c.world and c.world() or {}
  local changed
  if c.mapId ~= state.mapId then
    local prev = state.mapId and state.placed[c.mapId]
    if prev then
      -- walked over a seam: the new map was placed last frame
      state.anchorX, state.anchorY = prev.ax, prev.ay
      state.seam = state.seam + 1
      changed = "seam"
    else
      state.anchorX, state.anchorY = 0, 0
      state.epoch = state.epoch + 1
      changed = "warp"
    end
    state.mapId = c.mapId
  end
  local placed = {}
  for _, e in ipairs(list) do
    placed[e.id] = {
      id = e.id, ax = e.ox + state.anchorX, ay = e.oy + state.anchorY,
      width = e.width or 0, height = e.height or 0, revision = e.revision or 0,
    }
  end
  state.placed = placed
  return changed
end

function Source.ctx() return ctx end

--- The map a cell (absolute) lies in, or nil for the border / void.
function Source.mapAt(ax, ay)
  for _, m in pairs(state.placed) do
    if ax >= m.ax and ay >= m.ay and ax < m.ax + m.width and ay < m.ay + m.height then
      return m
    end
  end
  return nil
end

local EMPTY = { void = true, blank = true, coll = 0xff, elev = 0 }

--- The cell at absolute (ax, ay): { mid, pair, coll, elev, beh, void, blank }.
-- blank is a cell the BLACK void fill blanks (no metatile at all).
function Source.cell(ax, ay)
  local key = ay * 65536 + ax
  local c = cellMemo[key]
  if c then return c end
  if not ctx then return EMPTY end
  local mid, pair, coll, elev, beh, void = ctx.cell(ax - state.anchorX, ay - state.anchorY)
  if mid == nil then
    c = EMPTY
  else
    c = { mid = mid, pair = pair, coll = coll or 0xff, elev = elev or 0, beh = beh,
      void = void == true }
  end
  cellMemo[key] = c
  return c
end

function Source.walkable(coll)
  if ctx and ctx.walkable then return ctx.walkable(coll) end
  return coll ~= 0x07 and coll ~= 0xff and coll ~= 0x29
end

--- The player's foot in the absolute frame (world pixels).
function Source.player()
  local p = ctx.player
  local dx, dy = state.anchorX * Source.CELL, state.anchorY * Source.CELL
  return {
    x = p.x + dx, y = p.y + dy, ground = (p.ground or p.y) + dy, lift = p.lift or 0,
    cellX = p.cellX + state.anchorX, cellY = p.cellY + state.anchorY,
    facing = p.facing, elevation = p.elevation, surfing = p.surfing, biking = p.biking,
    moving = p.moving,
  }
end

--- Current-map world pixels to absolute world pixels.
function Source.toAbs(x, y)
  return x + state.anchorX * Source.CELL, y + state.anchorY * Source.CELL
end

-- ------- atlases

local atlasMemo = {}

--- The atlas view of a pair this frame (nil while it streams in).
function Source.atlas(pair)
  if not pair then return nil end
  local a = atlasMemo[pair]
  if a ~= nil and a.frame == memoFrame then return a.view end
  local view = ctx and ctx.atlas(pair) or nil
  atlasMemo[pair] = { frame = memoFrame, view = view }
  return view
end

return Source
