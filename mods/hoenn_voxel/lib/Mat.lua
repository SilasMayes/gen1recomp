-- 4x4 matrices, row-major ({ {a,b,c,d}, ... }), sent to shaders with the
-- "row" layout.  Pure Lua.
local Mat = {}

function Mat.identity()
  return { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }
end

function Mat.mul(a, b)
  local out = {}
  for i = 1, 4 do
    local r = {}
    for j = 1, 4 do
      r[j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j] + a[i][4] * b[4][j]
    end
    out[i] = r
  end
  return out
end

-- OpenGL-style perspective (clip z in -1..1), fovy in radians
function Mat.perspective(fovy, aspect, near, far)
  local f = 1 / math.tan(fovy / 2)
  return {
    { f / aspect, 0, 0, 0 },
    { 0, f, 0, 0 },
    { 0, 0, (far + near) / (near - far), 2 * far * near / (near - far) },
    { 0, 0, -1, 0 },
  }
end

function Mat.ortho(l, r, b, t, n, f)
  return {
    { 2 / (r - l), 0, 0, -(r + l) / (r - l) },
    { 0, 2 / (t - b), 0, -(t + b) / (t - b) },
    { 0, 0, -2 / (f - n), -(f + n) / (f - n) },
    { 0, 0, 0, 1 },
  }
end

local function norm(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l == 0 then return 0, 0, 0 end
  return x / l, y / l, z / l
end
Mat.norm = norm

function Mat.lookAt(ex, ey, ez, tx, ty, tz, ux, uy, uz)
  local fx, fy, fz = norm(tx - ex, ty - ey, tz - ez)
  local sx, sy, sz = norm(fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux)
  local vx, vy, vz = sy * fz - sz * fy, sz * fx - sx * fz, sx * fy - sy * fx
  return {
    { sx, sy, sz, -(sx * ex + sy * ey + sz * ez) },
    { vx, vy, vz, -(vx * ex + vy * ey + vz * ez) },
    { -fx, -fy, -fz, fx * ex + fy * ey + fz * ez },
    { 0, 0, 0, 1 },
  }
end

function Mat.transform(m, x, y, z)
  local X = m[1][1] * x + m[1][2] * y + m[1][3] * z + m[1][4]
  local Y = m[2][1] * x + m[2][2] * y + m[2][3] * z + m[2][4]
  local Z = m[3][1] * x + m[3][2] * y + m[3][3] * z + m[3][4]
  local W = m[4][1] * x + m[4][2] * y + m[4][3] * z + m[4][4]
  return X, Y, Z, W
end

-- the flat list LÖVE's Shader:send takes for a matrix uniform
function Mat.rows(m)
  return { m[1], m[2], m[3], m[4] }
end

return Mat
