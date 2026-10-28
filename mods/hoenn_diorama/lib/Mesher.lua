-- Shape quads -> vertex arrays, one group per (tileset pair, layer), ready
-- for love.graphics.newMesh.  Pure Lua; the GPU objects are made in World.
local Mesher = {}

-- Vertex layout the scene shader reads.
Mesher.FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexColor", "byte", 4 },
}

-- Texels are sampled nearest; an edge exactly on a cell boundary can pick
-- the neighbouring metatile, so the outer edges are pulled in a hair.
local INSET = 0.02

-- a polygon's texel, kept inside its cell by the same hair
local function clampTexel(t)
  if t < INSET then return INSET end
  if t > 16 - INSET then return 16 - INSET end
  return t
end

local function inset(a, b)
  if a == b then return a, b end
  if a < b then return a + INSET, b - INSET end
  return a - INSET, b + INSET
end

--- Group quads by pair and layer.  `atlasOf(pair)` returns the atlas view
-- (ctx.atlas) or nil; a quad whose pair has no atlas yet makes the build
-- report the pair as missing and the whole chunk is retried later, so a
-- chunk never goes up half textured.
--
-- `artOf(view, quad)`, when given, places a quad that asks for derived art
-- (quad.art, Cutouts.lua): it returns the page number, the cell's pixel
-- origin on that page and the page size, or nil to fall back to the atlas.
-- Those quads group by page instead (group.page).
function Mesher.build(quads, atlasOf, artOf)
  local groups, order, missing = {}, {}, nil
  local views = {}
  for _, q in ipairs(quads) do
    local view = views[q.pair]
    if view == nil then
      view = atlasOf(q.pair) or false
      views[q.pair] = view
    end
    if not view then
      missing = missing or {}
      missing[q.pair] = true
    else
      local hasLayer = q.layer == "u" or view.layered
      local ox, oy = view.origin(q.mid)
      local W, H = view.width, view.height
      local page
      if hasLayer and ox and q.art and q.layer == "u" and artOf then
        local pg, px, py, size = artOf(view, q)
        if pg then
          page, ox, oy, W, H = pg, px, py, size, size
        end
      end
      if hasLayer and ox then
        local key = q.pair .. "|" .. q.layer .. (page and ("|p" .. page) or "")
        local g = groups[key]
        if not g then
          g = { pair = q.pair, layer = q.layer, page = page, verts = {}, idx = {} }
          groups[key] = g
          order[#order + 1] = key
        end
        local verts, idx = g.verts, g.idx
        local base = #verts
        if q.poly then
          -- a convex polygon, each corner with its own texel and light
          local s0 = q.shade or 1
          for i, v in ipairs(q.poly) do
            local s = v[6] or s0
            verts[base + i] = {
              v[1], v[2], v[3],
              (ox + clampTexel(v[4])) / W, (oy + clampTexel(v[5])) / H,
              s, s, s, 1,
            }
          end
          for i = 2, #q.poly - 1 do
            local n = #idx
            idx[n + 1], idx[n + 2], idx[n + 3] = base + 1, base + i, base + i + 1
          end
        else
          local u0, u1 = inset(q.u0, q.u1)
          local v0, v1 = inset(q.v0, q.v1)
          local hi = q.shade or 1
          local lo = q.low or hi
          local p = q.p
          local uv = { u0, v0, u1, v0, u1, v1, u0, v1 }
          for i = 0, 3 do
            -- TL, TR carry the top edge's light; BR, BL the bottom edge's
            local s = i < 2 and hi or lo
            verts[base + i + 1] = {
              p[i * 3 + 1], p[i * 3 + 2], p[i * 3 + 3],
              (ox + uv[i * 2 + 1]) / W, (oy + uv[i * 2 + 2]) / H,
              s, s, s, 1,
            }
          end
          local n = #idx
          idx[n + 1], idx[n + 2], idx[n + 3] = base + 1, base + 2, base + 3
          idx[n + 4], idx[n + 5], idx[n + 6] = base + 1, base + 3, base + 4
        end
      end
    end
  end
  local list = {}
  for _, key in ipairs(order) do list[#list + 1] = groups[key] end
  return list, missing
end

return Mesher
