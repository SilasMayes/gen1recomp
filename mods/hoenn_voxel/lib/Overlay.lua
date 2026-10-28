-- What the flat field draws over the world in screen space, drawn over the
-- 3D pass instead: the weather's sprites and Flash's darkness.
local lib = ...
local Source = lib("Source")
local Analysis = lib("Analysis")

local Overlay = {}

local ring, ringSegments = nil, 48

-- the dark with a lit disc of radius r round (cx, cy), out to R
local function darkness(cx, cy, r, R)
  local verts = {}
  local soft = math.max(4, r * 0.12)
  local function circle(rad, a)
    local pts = {}
    for i = 0, ringSegments do
      local t = i / ringSegments * math.pi * 2
      pts[#pts + 1] = { cx + math.cos(t) * rad, cy + math.sin(t) * rad, a }
    end
    return pts
  end
  local inner, mid, outer = circle(r - soft, 0), circle(r + soft, 1), circle(R, 1)
  local function band(a, b)
    for i = 1, ringSegments do
      local p1, p2, q1, q2 = a[i], a[i + 1], b[i], b[i + 1]
      for _, v in ipairs({ p1, p2, q2, p1, q2, q1 }) do
        verts[#verts + 1] = { v[1], v[2], 0, 0, 0, 0, 0, v[3] }
      end
    end
  end
  band(inner, mid)
  band(mid, outer)
  if not ring then
    ring = love.graphics.newMesh({ { "VertexPosition", "float", 2 }, { "VertexTexCoord", "float", 2 },
      { "VertexColor", "float", 4 } }, #verts, "triangles", "stream")
  end
  ring:setVertices(verts)
  love.graphics.draw(ring)
end

--- Draw the overlays into the bound canvas (w x h), the camera's view.
function Overlay.draw(ctx, camera, w, h)
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setShader()
  love.graphics.setDepthMode()
  if ctx.mirrored then
    -- the composite mirrors this canvas: mirror what is drawn in 2D to match
    love.graphics.translate(0, h)
    love.graphics.scale(1, -1)
  end
  local radius = ctx.flashRadius and ctx.flashRadius()
  if radius then
    local p = Source.player()
    local gh = Analysis.groundAt(p.x, p.ground)
    local sx, sy = camera:project(p.x, gh + 12, p.ground + gh)
    if sx then
      -- the radius in canvas pixels: the flat field's scale at the focus
      local s = w / ctx.vw
      darkness(sx, sy, radius * s, math.max(w, h) * 2)
    end
  end
  if ctx.drawWeather then
    love.graphics.setColor(1, 1, 1, 1)
    pcall(ctx.drawWeather, w / ctx.vw, w, h)
  end
  love.graphics.pop()
end

return Overlay
