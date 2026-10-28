-- One frame of the diorama: sky, terrain chunks, actor cards, then the
-- field's own screen-space overlays (Flash darkness, weather).
local lib = ...
local Camera = lib("Camera")
local World = lib("World")
local Actors = lib("Actors")
local Mat = lib("Mat")

local Scene = {}
Scene.__index = Scene

local GEOMETRY_GLSL = [[
uniform mat4 u_viewProj;
uniform mat4 u_lightViewProj;
uniform vec3 u_eye;
varying float v_dist;
varying vec4 v_light;
#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  v_dist = distance(vertex_position.xyz, u_eye);
  v_light = u_lightViewProj * vec4(vertex_position.xyz, 1.0);
  return u_viewProj * vec4(vertex_position.xyz, 1.0);
}
#endif
#ifdef PIXEL
uniform vec3 u_fogColor;
uniform vec2 u_fog;
uniform float u_cut;
uniform Image u_shadowMap;
uniform float u_shadowOn;
uniform vec2 u_shadowTexel;
uniform float u_shadowBias;
uniform float u_shadowDark;
float lit(vec2 at, float depth) {
  return depth - u_shadowBias > Texel(u_shadowMap, at).r ? 0.0 : 1.0;
}
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
  vec4 t = Texel(tex, uv);
  if (t.a < u_cut) discard;
  vec3 c = t.rgb * color.rgb;
  if (u_shadowOn > 0.5) {
    vec3 lp = v_light.xyz / v_light.w * 0.5 + 0.5;
    if (lp.x > 0.0 && lp.x < 1.0 && lp.y > 0.0 && lp.y < 1.0 && lp.z < 1.0) {
      vec2 o = u_shadowTexel * 0.5;
      float l = lit(lp.xy + vec2(-o.x, -o.y), lp.z) + lit(lp.xy + vec2(o.x, -o.y), lp.z)
              + lit(lp.xy + vec2(-o.x, o.y), lp.z) + lit(lp.xy + vec2(o.x, o.y), lp.z);
      c *= mix(u_shadowDark, 1.0, l * 0.25);
    }
  }
  float f = clamp((v_dist - u_fog.x) / max(u_fog.y - u_fog.x, 1.0), 0.0, 1.0);
  // u_cut > 0: alpha-tested cards, solid where they are drawn;
  // u_cut == 0: blended decals (shadows) keep their alpha
  float a = u_cut > 0.0 ? 1.0 : t.a * color.a;
  return vec4(mix(c, u_fogColor, f * f), a);
}
#endif
]]


-- The sun's depth pass: the same cards and boxes seen from the sun, depth
-- only, holes cut where the art is clear.
local SHADOW_GLSL = [[
uniform mat4 u_lightViewProj;
#ifdef VERTEX
vec4 position(mat4 transform_projection, vec4 vertex_position) {
  return u_lightViewProj * vec4(vertex_position.xyz, 1.0);
}
#endif
#ifdef PIXEL
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
  if (Texel(tex, uv).a < 0.5) discard;
  return vec4(1.0);
}
#endif
]]

-- Where the sun is: shadows fall east and a little north of what casts
-- them (per pixel of height), so fronts facing the camera stay lit and the
-- painted light from the left agrees.
local SUN = { 0.55, -0.3 }
local SHADOW_SIZE = 2048
local SHADOW_DARK = 0.72

-- pitch for each rung of the ladder (OFF is rung 0)
Scene.PITCH = { 45, 35, 25 }
-- how far above the camera's ground raised ground may stand, in pixels
Scene.RELIEF_REACH = 96

local SKY_TOP = { 0.53, 0.74, 0.93 }
local SKY_LOW = { 0.80, 0.90, 0.97 }
local DARK = { 0.0, 0.0, 0.0 }

function Scene.new(params)
  params = params or {}
  return setmetatable({
    shadows = params.shadows ~= false,
    camera = Camera.new(),
    world = World.new(params),
    actors = Actors.new(),
    canvas = nil,
    level = 0,
    budget = 0.004,
    ok = nil,
  }, Scene)
end

local function compile(src)
  local ok, shader = pcall(love.graphics.newShader, src)
  if ok then return shader end
  return nil, shader
end

--- Whether this machine can draw the diorama at all: shaders and a canvas
-- with a depth buffer.  Answered once.
function Scene:available()
  if self.ok ~= nil then return self.ok end
  local ok = false
  if love and love.graphics and love.graphics.newShader and love.graphics.setDepthMode then
    local shader, err = compile(GEOMETRY_GLSL)
    if shader then
      local okCanvas, probe = pcall(love.graphics.newCanvas, 4, 4, { dpiscale = 1 })
      if okCanvas and probe then
        local okDepth = pcall(function()
          love.graphics.push("all")
          love.graphics.setCanvas({ probe, depth = true })
          love.graphics.clear(0, 0, 0, 1)
          love.graphics.pop()
        end)
        if probe.release then probe:release() end
        ok = okDepth
      end
      self.shader = shader
    else
      self.why = err
    end
  end
  self.ok = ok
  return ok
end

function Scene:setParams(params)
  self.shadows = params.shadows ~= false
  self.world:setParams(params)
end

-- The sun's depth canvas, made on first use; false where this machine
-- cannot sample a depth canvas (the scene then draws without shadows).
function Scene:shadowTargets()
  if self.shadowMap ~= nil then return self.shadowMap or nil end
  self.shadowMap = false
  local G = love.graphics
  if not (G.getCanvasFormats and G.newCanvas) then return nil end
  local okF, formats = pcall(G.getCanvasFormats, true)
  if not okF or type(formats) ~= "table" then return nil end
  local fmt = (formats.depth24 and "depth24") or (formats.depth32f and "depth32f")
    or (formats.depth16 and "depth16") or nil
  if not fmt then return nil end
  local okS, shader = pcall(G.newShader, SHADOW_GLSL)
  if not okS then return nil end
  local okD, depth = pcall(G.newCanvas, SHADOW_SIZE, SHADOW_SIZE,
    { format = fmt, readable = true, dpiscale = 1 })
  local okC, color = pcall(G.newCanvas, SHADOW_SIZE, SHADOW_SIZE, { format = "r8", dpiscale = 1 })
  if not okC then okC, color = pcall(G.newCanvas, SHADOW_SIZE, SHADOW_SIZE, { dpiscale = 1 }) end
  if not (okD and okC) then return nil end
  depth:setFilter("nearest", "nearest")
  self.shadowMap = { depth = depth, color = color, shader = shader }
  return self.shadowMap
end

-- An orthographic camera at the sun, framing the ground the camera sees
-- (and everything standing on it), snapped to whole shadow texels so the
-- edges hold still while the camera moves.
local function sunMatrix(minX, maxX, minZ, maxZ, yLo, yHi)
  local lx, ly, lz = -SUN[1], 1, -SUN[2]
  local len = math.sqrt(lx * lx + ly * ly + lz * lz)
  lx, ly, lz = lx / len, ly / len, lz / len
  local cx, cz = (minX + maxX) / 2, (minZ + maxZ) / 2
  local view = Mat.lookAt(cx + lx * 1000, ly * 1000, cz + lz * 1000, cx, 0, cz, 0, 0, -1)
  local x0, x1, y0, y1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
  for _, x in ipairs({ minX, maxX }) do
    for _, z in ipairs({ minZ, maxZ }) do
      for _, y in ipairs({ yLo or -8, yHi or 72 }) do
        local vx, vy, vz = Mat.transform(view, x, y, z)
        x0, x1 = math.min(x0, vx), math.max(x1, vx)
        y0, y1 = math.min(y0, vy), math.max(y1, vy)
        z0, z1 = math.min(z0, vz), math.max(z1, vz)
      end
    end
  end
  local span = math.max(x1 - x0, y1 - y0)
  local texel = span / SHADOW_SIZE
  x0 = math.floor(x0 / texel) * texel
  y0 = math.floor(y0 / texel) * texel
  local proj = Mat.ortho(x0, x0 + span, y0, y0 + span, -z1 - 16, -z0 + 16)
  return Mat.mul(proj, view), span, (-z0 + 16) - (-z1 - 16)
end

function Scene:update(dt, level)
  self.level = level or 0
  local deg = Scene.PITCH[self.level]
  if deg then self.camera:update(dt, deg) end
end

function Scene:invalidate()
  self.world:clear()
  self.world.mapId = nil
  self.actors:release()
  if self.canvas and self.canvas.release then pcall(self.canvas.release, self.canvas) end
  self.canvas = nil
  if self.sky and self.sky.mesh.release then pcall(self.sky.mesh.release, self.sky.mesh) end
  self.sky = nil
end

local function ensureCanvas(self, w, h)
  local c = self.canvas
  if c and c:getWidth() == w and c:getHeight() == h then return c end
  if c and c.release then c:release() end
  c = love.graphics.newCanvas(w, h, { dpiscale = 1 })
  c:setFilter("nearest", "nearest")
  self.canvas = c
  return c
end

local function drawSky(self, w, h, outdoors)
  local G = love.graphics
  if not outdoors then
    G.clear(DARK[1], DARK[2], DARK[3], 1)
    return
  end
  G.clear(SKY_LOW[1], SKY_LOW[2], SKY_LOW[3], 1)
  local sky = self.sky
  if not (sky and sky.w == w and sky.h == h) then
    if sky and sky.mesh.release then sky.mesh:release() end
    sky = { w = w, h = h, mesh = love.graphics.newMesh({
      { 0, 0, 0, 0, SKY_TOP[1], SKY_TOP[2], SKY_TOP[3], 1 },
      { w, 0, 0, 0, SKY_TOP[1], SKY_TOP[2], SKY_TOP[3], 1 },
      { w, h, 0, 0, SKY_LOW[1], SKY_LOW[2], SKY_LOW[3], 1 },
      { 0, h, 0, 0, SKY_LOW[1], SKY_LOW[2], SKY_LOW[3], 1 },
    }, "fan", "static") }
    self.sky = sky
  end
  G.draw(sky.mesh)
end

-- Black everywhere but a disc: a ring from the lit radius out past the
-- canvas corners, so it needs no shader and no screen-space convention.
function Scene:drawDarkness(cx, cy, r, w, h)
  local G = love.graphics
  local R = (w + h) * 2
  local verts = {}
  local n = 64
  for i = 0, n do
    local a = i / n * math.pi * 2
    local c, s = math.cos(a), math.sin(a)
    verts[#verts + 1] = { cx + c * r, cy + s * r, 0, 0, 0, 0, 0, 1 }
    verts[#verts + 1] = { cx + c * R, cy + s * R, 0, 0, 0, 0, 0, 1 }
  end
  local mesh = self.darkMesh
  if not mesh then
    mesh = G.newMesh(#verts, "strip", "dynamic")
    self.darkMesh = mesh
  end
  mesh:setVertices(verts)
  G.setColor(1, 1, 1, 1)
  G.draw(mesh)
end

--- Render the field.  Returns the canvas, or nil to let the engine show the
-- flat field this frame (nothing built yet, or the camera has no rung).
function Scene:draw(ctx)
  if not self:available() then return nil end
  local deg = Scene.PITCH[ctx.level or self.level]
  if not deg then return nil end
  if not self.camera.pitch then self.camera:update(0, deg) end
  local w, h = ctx.width, ctx.height
  if not (w and h and w > 0 and h > 0) then return nil end

  local world = self.world
  world:follow(ctx)
  local ox, oy = world:offset()
  -- look where the flat field looks: its view's centre, which is the
  -- player's cell unless a script pans the camera or a shop frames the
  -- counter
  local cx0 = ctx.cam and ctx.cam.x or (ctx.player.x - 8 - (ctx.vw or 0) / 2)
  local cy0 = ctx.cam and ctx.cam.y or (ctx.player.ground - 16 - (ctx.vh or 0) / 2)
  local fx = cx0 + (ctx.vw or 0) / 2 + ox
  local fz = cy0 + (ctx.vh or 0) / 2 + oy
  local scale = ctx.scale or 1
  local cam = self.camera
  -- one atlas lookup per pair per frame
  local views = {}
  local function atlasOf(pair)
    local v = views[pair]
    if v == nil then
      v = ctx.atlas(pair) or false
      views[pair] = v
    end
    return v or nil
  end
  -- the camera looks at the ground where the field looks, at its height
  -- (raised ground stands as far south as it is lifted: Relief.lua), easing
  -- there so a flight of stairs is a glide, not a jump
  local want = world:heightAt(ctx, atlasOf, fx, fz)
  if self.focusH == nil or self.focusSpace ~= world.space then self.focusH = want end
  self.focusSpace = world.space
  self.focusH = self.focusH + (want - self.focusH) * 0.25
  if math.abs(want - self.focusH) < 0.05 then self.focusH = want end
  local fh = self.focusH
  cam:frame(fx, fh, fz + fh, w, h, scale, true)

  -- what the camera can see, in current-map pixels (raised ground sits
  -- further south than its cells: look that much further north for it)
  local minX, maxX, minZ, maxZ = cam:groundBounds(0)
  -- (the sun frames what is seen: raised ground stands south of its cells)
  local seenZ = minZ
  minZ = minZ - Scene.RELIEF_REACH
  local clock = love.timer and love.timer.getTime or nil
  local chunks, fresh, total = world:prepare(ctx, atlasOf, minX - ox, maxX - ox,
    minZ - oy - 48, maxZ - oy + 48, fx - ox, fz - oy, self.budget, clock)
  -- right after a warp nothing is built: keep the flat field up (the fade
  -- usually covers it) and spend more of the frame catching up
  if fresh < math.min(total, 6) then
    world:prepare(ctx, atlasOf, minX - ox, maxX - ox, minZ - oy - 48, maxZ - oy + 48,
      fx - ox, fz - oy, 0.02, clock)
    return nil
  end

  local cards = self.actors:prepare(ctx, ox, oy, function(x, z)
    return world:heightAt(ctx, atlasOf, x, z)
  end)

  local G = love.graphics
  local shader = self.shader
  -- the sun's pass: depth of everything standing, from the sun
  local sm = self.shadows and self:shadowTargets() or nil
  local lightVP, depthRange
  if sm then
    local span
    -- as low and as high as what is drawn reaches (raised ground included)
    local yLo, yHi = -8, 72
    for _, ch in ipairs(chunks) do
      if ch.yLo and ch.yLo < math.huge then
        yLo, yHi = math.min(yLo, ch.yLo), math.max(yHi, ch.yHi)
      end
    end
    lightVP, span, depthRange = sunMatrix(minX - 64, maxX + 64, seenZ - 64,
      maxZ + 64 + math.max(0, yHi - 72), yLo, yHi)
    G.push("all")
    G.setCanvas({ sm.color, depthstencil = sm.depth })
    G.clear(1, 1, 1, 1, false, 1)
    G.setShader(sm.shader)
    sm.shader:send("u_lightViewProj", "row", Mat.rows(lightVP))
    G.setDepthMode("lequal", true)
    G.setMeshCullMode("none")
    G.setBlendMode("replace")
    world.cutouts:flush()
    for _, ch in ipairs(chunks) do
      for _, g in ipairs(ch.meshes) do
        local view = atlasOf(g.pair)
        local tex
        if g.page then
          tex = world.cutouts:image(g.page)
        else
          tex = view and (g.layer == "u" and view.image or view.overImage)
        end
        if tex then
          g.mesh:setTexture(tex)
          G.draw(g.mesh)
        end
      end
    end
    G.pop()
  end

  local canvas = ensureCanvas(self, w, h)
  G.push("all")
  G.setCanvas({ canvas, depth = true })
  G.origin()
  G.setScissor()
  G.setBlendMode("alpha")
  G.setColor(1, 1, 1, 1)
  local outdoors = ctx.outdoors ~= false
  drawSky(self, w, h, outdoors)
  G.clear(false, false, true)

  shader:send("u_viewProj", "row", Mat.rows(cam.viewProj))
  if sm then
    shader:send("u_lightViewProj", "row", Mat.rows(lightVP))
    shader:send("u_shadowMap", sm.depth)
    shader:send("u_shadowOn", 1)
    shader:send("u_shadowTexel", { 1 / SHADOW_SIZE, 1 / SHADOW_SIZE })
    -- a pixel and a half of world depth, in the depth canvas's 0..1
    shader:send("u_shadowBias", 1.5 / depthRange)
    -- a room's light is soft; the sun outside is not
    shader:send("u_shadowDark", ctx.outdoors == false and 0.84 or SHADOW_DARK)
  else
    shader:send("u_lightViewProj", "row", Mat.rows(Mat.identity()))
    shader:send("u_shadowOn", 0)
  end
  shader:send("u_eye", cam.eye)
  local fogColor = outdoors and SKY_LOW or DARK
  shader:send("u_fogColor", fogColor)
  shader:send("u_fog", { cam.distance * 2.2, cam.distance * (outdoors and 5.5 or 3.6) })
  shader:send("u_cut", 0.5)
  G.setShader(shader)
  G.setDepthMode("lequal", true)
  G.setMeshCullMode("none")

  -- derived art made while building lands on the GPU before it is drawn
  world.cutouts:flush()
  local drawn = 0
  for _, layer in ipairs({ "u", "o" }) do
    for _, ch in ipairs(chunks) do
      for _, g in ipairs(ch.meshes) do
        if g.layer == layer then
          local view = atlasOf(g.pair)
          local tex
          if g.page then
            tex = world.cutouts:image(g.page)
          else
            tex = view and (layer == "u" and view.image or view.overImage)
          end
          if tex then
            g.mesh:setTexture(tex)
            G.draw(g.mesh)
            drawn = drawn + g.quads
          end
        end
      end
    end
  end
  -- shadows blend over the ground without writing depth, then the cards
  shader:send("u_cut", 0)
  G.setDepthMode("lequal", false)
  self.actors:drawShadows(cards)
  shader:send("u_cut", 0.5)
  G.setDepthMode("lequal", true)
  self.actors:draw(cards)

  G.setDepthMode()
  G.setShader()
  G.setCanvas(canvas)

  -- The field's own overlays, flat in screen space.  Where the engine
  -- mirrors the finished canvas (ctx.mirrored), these are mirrored first so
  -- they come out the right way up with the 3D pass.
  G.push()
  if ctx.mirrored then
    G.translate(0, h)
    G.scale(1, -1)
  end
  -- Flash darkness: the field's lit circle, centred where the camera looks
  local radius = ctx.flashRadius and ctx.flashRadius()
  if radius then
    local sx, sy, depth = cam:project(fx, 12, fz)
    if sx then self:drawDarkness(sx, sy, radius * cam:pixelScaleAt(depth), w, h) end
  end
  if ctx.drawWeather then
    pcall(ctx.drawWeather, scale, w, h)
  end
  G.pop()
  G.pop()

  self.stats = { chunks = #chunks, fresh = fresh, total = total, quads = drawn, actors = #cards }
  return canvas
end

return Scene
