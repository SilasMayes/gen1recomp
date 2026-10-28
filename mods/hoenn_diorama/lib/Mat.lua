-- 4x4 matrices for the diorama camera.  Row-major flat arrays, m[r*4+c+1],
-- sent to GLSL with the "row" layout so the shader reads them the way they
-- are written here.  Pure Lua: the mesher and the tests use it headless.
local Mat = {}

function Mat.identity()
  return { 1, 0, 0, 0,
           0, 1, 0, 0,
           0, 0, 1, 0,
           0, 0, 0, 1 }
end

function Mat.mul(a, b)
  local o = {}
  for r = 0, 3 do
    for c = 0, 3 do
      local s = 0
      for k = 0, 3 do s = s + a[r * 4 + k + 1] * b[k * 4 + c + 1] end
      o[r * 4 + c + 1] = s
    end
  end
  return o
end

-- OpenGL-style perspective: right-handed eye space looking down -z, clip z
-- in [-w, w].
function Mat.perspective(fovy, aspect, near, far)
  local f = 1 / math.tan(fovy / 2)
  local nf = 1 / (near - far)
  return { f / aspect, 0, 0, 0,
           0, f, 0, 0,
           0, 0, (far + near) * nf, 2 * far * near * nf,
           0, 0, -1, 0 }
end

-- OpenGL-style orthographic projection of the eye-space box l..r, b..t,
-- -n..-f.
function Mat.ortho(l, r, b, t, n, f)
  return { 2 / (r - l), 0, 0, -(r + l) / (r - l),
           0, 2 / (t - b), 0, -(t + b) / (t - b),
           0, 0, -2 / (f - n), -(f + n) / (f - n),
           0, 0, 0, 1 }
end

local function normalize(x, y, z)
  local l = math.sqrt(x * x + y * y + z * z)
  if l == 0 then return 0, 0, 0 end
  return x / l, y / l, z / l
end

local function cross(ax, ay, az, bx, by, bz)
  return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

function Mat.lookAt(ex, ey, ez, tx, ty, tz, ux, uy, uz)
  local fx, fy, fz = normalize(tx - ex, ty - ey, tz - ez)
  local sx, sy, sz = normalize(cross(fx, fy, fz, ux, uy, uz))
  local vx, vy, vz = cross(sx, sy, sz, fx, fy, fz)
  return { sx, sy, sz, -(sx * ex + sy * ey + sz * ez),
           vx, vy, vz, -(vx * ex + vy * ey + vz * ez),
           -fx, -fy, -fz, (fx * ex + fy * ey + fz * ez),
           0, 0, 0, 1 }
end

function Mat.transform(m, x, y, z)
  return m[1] * x + m[2] * y + m[3] * z + m[4],
         m[5] * x + m[6] * y + m[7] * z + m[8],
         m[9] * x + m[10] * y + m[11] * z + m[12],
         m[13] * x + m[14] * y + m[15] * z + m[16]
end

-- The four rows as nested tables, for Shader:send(name, "row", ...).
function Mat.rows(m)
  return { { m[1], m[2], m[3], m[4] }, { m[5], m[6], m[7], m[8] },
           { m[9], m[10], m[11], m[12] }, { m[13], m[14], m[15], m[16] } }
end

return Mat
