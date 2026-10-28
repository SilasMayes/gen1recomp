-- The GPU side: one shader, the canvas the engine composites, its depth.
local lib = ...
local Mat = lib("Mat")

local Render = {}

local SHADER = [[
uniform mat4 u_viewProj;
uniform vec3 u_eye;
uniform vec4 u_fog;         // rgb, density per world pixel past u_fogStart
uniform float u_fogStart;
varying float v_dist;
#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  v_dist = distance(vertex_position.xyz, u_eye);
  return u_viewProj * vertex_position;
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
  vec4 t = Texel(tex, uv);
  if (t.a < 0.5) discard;
  vec3 c = t.rgb * color.rgb;
  float f = clamp((v_dist - u_fogStart) * u_fog.a, 0.0, 1.0);
  return vec4(mix(c, u_fog.rgb, f), 1.0);
}
#endif
]]

local shader, canvas, cw, ch

function Render.ok()
  if not (love and love.graphics and love.graphics.newShader) then return false end
  if shader == nil then
    local ok, s = pcall(love.graphics.newShader, SHADER)
    shader = ok and s or false
  end
  return shader ~= false
end

function Render.canvas(w, h)
  if not canvas or cw ~= w or ch ~= h then
    if canvas then canvas:release() end
    canvas = love.graphics.newCanvas(w, h, { dpiscale = 1 })
    canvas:setFilter("nearest", "nearest")
    cw, ch = w, h
  end
  return canvas
end

--- Begin the 3D pass into the canvas: clear to `sky`, depth on.
function Render.begin(cam, sky, fog)
  local c = canvas
  love.graphics.push("all")
  love.graphics.setCanvas({ c, depth = true })
  love.graphics.clear(sky[1], sky[2], sky[3], 1, false, 1)
  love.graphics.origin()
  love.graphics.setDepthMode("lequal", true)
  love.graphics.setMeshCullMode("none")
  love.graphics.setBlendMode("alpha")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setShader(shader)
  shader:send("u_viewProj", "row", Mat.rows(cam.viewProj))
  shader:send("u_eye", cam.eye)
  fog = fog or { sky[1], sky[2], sky[3], 0 }
  shader:send("u_fog", fog)
  shader:send("u_fogStart", fog.start or 1e9)
end

function Render.finish()
  love.graphics.setShader()
  love.graphics.setDepthMode()
  love.graphics.pop()
  return canvas
end

return Render
