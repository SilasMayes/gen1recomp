-- A map's count, kept between sessions in mod.cache.  The key is a
-- fingerprint of everything the count reads (the cells, the readings of
-- their metatiles) and of the code and data that count it, so a different
-- ROM, a patched map or a new rule never reads an old answer.
local lib, mod = ...

local Cache = {}

local bit = bit or bit32

-- FNV-1a, 32 bits
local function fnv(s, h)
  h = h or 2166136261
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i))
    -- h * 16777619 = (h << 24) + h * 403, each part exact in a double
    h = bit.band(bit.lshift(h, 24) + h * 403, 0xffffffff)
  end
  return h
end
Cache.fnv = fnv

local rules
local function ruleStamp()
  if rules == nil then
    local a = mod and mod:read("lib/Terrain.lua") or ""
    local b = mod and mod:read("data/terrain.lua") or ""
    rules = ("%08x"):format(fnv(b, fnv(a)) % 0x100000000)
  end
  return rules
end

local FIELDS = { "m", "walk", "water", "ledge", "bridge", "tree", "berry", "mud", "warp", "falls",
  "puddle", "blank" }

--- The fingerprint of a map's input.
function Cache.fingerprint(input)
  local parts = { input.w, "x", input.h, ":", tostring(input.pair), ":", tostring(input.general) }
  for i = 1, input.w * input.h do
    local c = input.cells[i]
    for _, f in ipairs(FIELDS) do
      local v = c[f]
      parts[#parts + 1] = v == true and "1" or (v == false or v == nil) and "0" or tostring(v)
    end
    parts[#parts + 1] = ";"
  end
  local mids = {}
  for m in pairs(input.tiles) do mids[#mids + 1] = m end
  table.sort(mids)
  for _, m in ipairs(mids) do
    local s = input.tiles[m]
    parts[#parts + 1] = ("%d:%.4f,%.4f,%d,%d,%d,%s;"):format(m, s.t, s.f, s.faceLow, s.rim, s.gTop, s.cls)
  end
  local h = fnv(table.concat(parts))
  return ("%s-%08x"):format(ruleStamp(), h % 0x100000000)
end

local function key(fp) return "terrain/" .. fp .. ".txt" end

--- The count of an input, if it was kept.
function Cache.read(input)
  if not (mod and mod.cache) then return nil end
  local ok, bytes = pcall(mod.cache.read, mod.cache, key(Cache.fingerprint(input)))
  if not ok or type(bytes) ~= "string" or bytes == "" then return nil end
  local n = input.w * input.h
  local r = { kind = {}, top = {}, read = {}, band = {}, rim = {}, keep = {} }
  local i = 0
  for kind, top, rd, band, rim, keep in bytes:gmatch("([%w]+),(%-?[%d%.]+),(.),(.),(.),(.);") do
    i = i + 1
    r.kind[i], r.top[i], r.read[i] = kind, tonumber(top), rd
    if band ~= "-" then r.band[i] = band end
    if rim == "1" then r.rim[i] = true end
    if keep == "1" then r.keep[i] = true end
  end
  if i ~= n then return nil end
  return r
end

--- Keep a count.
function Cache.write(input, r)
  if not (mod and mod.cache) then return end
  local parts = {}
  for i = 1, input.w * input.h do
    parts[i] = ("%s,%s,%s,%s,%s,%s;"):format(r.kind[i] or "F", tostring(r.top[i] or 0),
      r.read[i] or "G", r.band[i] or "-", r.rim[i] and "1" or "0", r.keep[i] and "1" or "0")
  end
  pcall(mod.cache.write, mod.cache, key(Cache.fingerprint(input)), table.concat(parts))
end

return Cache
