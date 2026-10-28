-- The camera: perspective, yaw 0, looking north and down at `pitch` degrees
-- (90 would be straight down).  It frames the same width of world the flat
-- field shows, at the ground under the focus, so every rung of the ladder
-- keeps the player's surroundings in view and only the angle changes.
--
-- World space is world pixels: x east, y up, z south.  A drawn pixel (u, v)
-- of something h high stands at (u, h, v + h) (Lift.lua), so the focus on
-- ground of height h is (fx, h, fz + h).
local lib = ...
local Mat = lib("Mat")

local Camera = {}
Camera.__index = Camera

Camera.FOV = math.rad(35)       -- vertical, as Emerald 3DS frames its world
Camera.EASE = 0.25              -- of the way to the asked pitch per 1/60 s

function Camera.new()
  return setmetatable({ pitch = nil, want = 45 }, Camera)
end

function Camera:update(dt, deg)
  self.want = deg
  if not self.pitch then self.pitch = deg return end
  local k = 1 - (1 - Camera.EASE) ^ math.max(0, (dt or 0) * 60)
  self.pitch = self.pitch + (deg - self.pitch) * k
  if math.abs(self.pitch - deg) < 0.01 then self.pitch = deg end
end

--- Frame the focus (world px) for a w x h canvas showing vw world px across.
function Camera:frame(fx, fy, fz, w, h, vw)
  local a = math.rad(self.pitch or self.want)
  local aspect = w / h
  -- the distance at which the canvas is vw world pixels wide at the focus
  local d = vw / (2 * math.tan(Camera.FOV / 2) * aspect)
  local yaw = math.rad(self.yaw or 0)       -- a debug view only: the game looks north
  local ex = fx + d * math.cos(a) * math.sin(yaw)
  local ey = fy + d * math.sin(a)
  local ez = fz + d * math.cos(a) * math.cos(yaw)
  self.eye = { ex, ey, ez }
  self.focus = { fx, fy, fz }
  self.distance = d
  self.view = Mat.lookAt(ex, ey, ez, fx, fy, fz, 0, 1, 0)
  self.proj = Mat.perspective(Camera.FOV, aspect, math.max(1, d * 0.05), d * 8 + 2048)
  -- LÖVE 11 canvases are flipped against the window: flip clip y
  local flip = { { 1, 0, 0, 0 }, { 0, -1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }
  self.viewProj = Mat.mul(flip, Mat.mul(self.proj, self.view))
  self.w, self.h = w, h
  if self.oblique then
    -- a check, never the game's view: the GBA's own projection, (x, z - y)
    -- straight onto the canvas, vw x (vw * h / w) drawn pixels across it,
    -- nearer the camera the more y + z
    local sx, sy = 2 / vw, 2 / (vw * h / w)
    local cz = fz - fy
    local depth = 1 / 4096
    self.viewProj = {
      { sx, 0, 0, -fx * sx },
      { 0, -sy, sy, -cz * sy },
      { 0, -depth, -depth, (fy + fz) * depth },
      { 0, 0, 0, 1 },
    }
  end
end

--- Screen point of a world point (canvas pixels), or nil behind the eye.
function Camera:project(x, y, z)
  local X, Y, _, W = Mat.transform(self.viewProj, x, y, z)
  if W <= 1e-6 then return nil end
  return (X / W * 0.5 + 0.5) * self.w, (Y / W * 0.5 + 0.5) * self.h, W
end

--- The world rectangle (x, z) the view can reach on the planes from
-- `low` to `high` pixels high: where to build and draw.
function Camera:groundBounds(low, high)
  local f = self.focus
  low = low or (f[2] - 48)
  high = high or (f[2] + 64)
  local e = self.eye
  local V = self.view
  local sx, sy, sz = V[1][1], V[1][2], V[1][3]
  local ux, uy, uz = V[2][1], V[2][2], V[2][3]
  local fx, fy, fz = -V[3][1], -V[3][2], -V[3][3]
  local ty = math.tan(Camera.FOV / 2)
  local tx = ty * (self.w / self.h)
  local far = self.distance * 6
  local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
  for _, nx in ipairs({ -1, 1 }) do
    for _, ny in ipairs({ -1, 1 }) do
      local dx = sx * nx * tx + ux * ny * ty + fx
      local dy = sy * nx * tx + uy * ny * ty + fy
      local dz = sz * nx * tx + uz * ny * ty + fz
      for _, plane in ipairs({ low, high }) do
        local t = far
        if dy < -1e-6 then t = math.min(far, (plane - e[2]) / dy) end
        if t < 0 then t = far end
        local x, z = e[1] + dx * t, e[3] + dz * t
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if z < z0 then z0 = z end
        if z > z1 then z1 = z end
      end
    end
  end
  return x0, x1, z0, z1
end

return Camera
