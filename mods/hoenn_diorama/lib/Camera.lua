-- The diorama camera: a perspective camera south of the player, pitched
-- down at the ladder's angle, framed so the scene matches the flat field's
-- size at the player.
--
-- Hoenn's sprites and facades are drawn in three-quarter view, which already
-- reads as "seen from about 45 degrees".  A real camera at pitch p shortens
-- anything upright by cos(p), which would squash every sprite, so the image
-- is stretched back up by 1 / cos(p): upright art keeps exactly its pixel
-- proportions, and only the ground's depth changes with the angle (by
-- tan(p)).  At 45 degrees that is the 2D field again, with parallax.
local lib = ...
local Mat = lib("Mat")

local Camera = {}
Camera.__index = Camera

local rad = math.rad

Camera.FOV = rad(30)

function Camera.new()
  return setmetatable({ pitch = nil, target = nil }, Camera)
end

-- Ease toward the ladder's pitch on real frame time.
function Camera:update(dt, targetDeg)
  if not targetDeg then return end
  local want = rad(targetDeg)
  if not self.pitch then
    self.pitch = want
    return
  end
  local k = 1 - math.exp(-(dt or 0) * 10)
  self.pitch = self.pitch + (want - self.pitch) * k
  if math.abs(self.pitch - want) < 1e-4 then self.pitch = want end
end

--- Frame the camera on the point (fx, fy, fz) for a w x h canvas at `scale`
-- canvas pixels per world pixel.  `flip` pre-flips clip y for a LOVE 11
-- canvas (the convention the engine composites a world override with).
function Camera:frame(fx, fy, fz, w, h, scale, flip)
  local p = self.pitch or rad(45)
  local fov = Camera.FOV
  local fpx = (h / 2) / math.tan(fov / 2)
  local d = fpx / scale
  local ex, ey, ez = fx, fy + d * math.sin(p), fz + d * math.cos(p)
  local view = Mat.lookAt(ex, ey, ez, fx, fy, fz, 0, 1, 0)
  local near, far = d * 0.08, d * 8
  local proj = Mat.perspective(fov, w / h, near, far)
  local stretch = 1 / math.cos(p)
  local post = Mat.identity()
  post[6] = stretch * (flip and -1 or 1)
  self.viewProj = Mat.mul(post, Mat.mul(proj, view))
  self.eye = { ex, ey, ez }
  self.focus = { fx, fy, fz }
  self.distance, self.near, self.far = d, near, far
  self.w, self.h, self.scale, self.flip = w, h, scale, flip
  self.stretch = stretch
  return self.viewProj
end

--- World point -> canvas pixel (origin top-left, y down), and its depth;
-- nil when behind the camera.
function Camera:project(x, y, z)
  local m = self.viewProj
  local cx, cy, _, cw = Mat.transform(m, x, y, z)
  if cw <= 1e-6 then return nil end
  local nx, ny = cx / cw, cy / cw
  if self.flip then ny = -ny end
  return (nx * 0.5 + 0.5) * self.w, (0.5 - ny * 0.5) * self.h, cw
end

--- Canvas pixels per world pixel for something upright at the given depth.
function Camera:pixelScaleAt(depth)
  if not depth or depth <= 0 then return self.scale end
  return self.scale * self.distance / depth
end

--- The patch of ground the camera can see: minX, maxX, minZ, maxZ in world
-- pixels, from the four screen corners cast onto the ground plane y = gy.
-- Rays that miss the ground (above the horizon) stop at the far plane.
function Camera:groundBounds(gy)
  gy = gy or 0
  local p = self.pitch or rad(45)
  local ex, ey, ez = self.eye[1], self.eye[2], self.eye[3]
  local t = math.tan(Camera.FOV / 2)
  local aspect = self.w / self.h
  -- camera basis: forward looks north and down, right is +x, up is the rest
  local fy, fz = -math.sin(p), -math.cos(p)
  local uy, uz = math.cos(p), -math.sin(p)
  local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
  for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
    local sx = corner[1] * t * aspect
    local sy = corner[2] * t / self.stretch
    -- direction = forward + right * sx + up * sy
    local dx = sx
    local dy = fy + uy * sy
    local dz = fz + uz * sy
    local dist
    if dy < -1e-4 then
      dist = (gy - ey) / dy
      local len = math.sqrt(dx * dx + dy * dy + dz * dz)
      if dist * len > self.far then dist = self.far / len end
    else
      dist = self.far / math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    local x, z = ex + dx * dist, ez + dz * dist
    if x < minX then minX = x end
    if x > maxX then maxX = x end
    if z < minZ then minZ = z end
    if z > maxZ then maxZ = z end
  end
  return minX, maxX, minZ, maxZ
end

return Camera
