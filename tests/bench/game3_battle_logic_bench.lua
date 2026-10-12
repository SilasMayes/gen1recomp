#!/usr/bin/env luajit
-- Gen 3 battle logic benchmark (AI move choice + damage + move lookup).
-- Needs an imported Ruby/Sapphire/Emerald cache:
--   GAME=ruby|sapphire|emerald POKEPORT_GBA_CACHE=<cache>/data/generated/gba \
--   luajit tests/bench/game3_battle_logic_bench.lua [iterations]
-- Prints a checksum of every decision/damage value (must not change across
-- optimisations) and median ms for each section.

package.path = "./?.lua;./?/init.lua;" .. package.path
local game = os.getenv("GAME") or "ruby"
local ITER = tonumber(arg and arg[1]) or 600
local RUNS = tonumber(os.getenv("BENCH_RUNS")) or 5

local Version = require("src.core.GameVersion")
Version.set(game)
local root = os.getenv("POKEPORT_GBA_CACHE")
if not root or root == "" then
  print("[skip] set POKEPORT_GBA_CACHE to an imported " .. game .. " cache")
  os.exit(0)
end
-- Per-game RSE caches carry their own cache_version, so tests.game3_cache
-- (FireRed-versioned) would reject them; mount the root directly.
local Dataset = require("src.core.game3.dataset")
Dataset.cacheRootOverride = root
Dataset.mountExtractRoots()

local State = require("src.core.game3.battle.state")
local Ai = require("src.core.game3.battle.ai")
local Moves = require("src.core.game3.battle.moves")
local Damage = require("src.core.game3.battle.damage")

Moves.loadRomPack()
Ai.loadPack({ force = true })

-- Deterministic generator, independent of math.random.
local function lcg(seed)
  local s = seed
  return function(lo, hi)
    s = (s * 1103515245 + 12345) % 2147483648
    local r = math.floor(s / 65536)
    if lo and hi then return lo + (r % (hi - lo + 1)) end
    return r % 65536
  end
end

local movesCount = require("src.import.gba.versions").MOVES_COUNT - 1
local gen = lcg(20260101)
local function mon(species, level)
  local mv, pp = {}, {}
  for i = 1, 4 do
    mv[i] = gen(1, math.min(354, movesCount))
    pp[i] = 20
  end
  local hp = 40 + gen(0, 120)
  return {
    species = species, level = level, hp = hp, maxHp = hp,
    moves = mv, pp = pp,
    attack = 40 + gen(0, 90), defense = 40 + gen(0, 90),
    spAtk = 40 + gen(0, 90), spDef = 40 + gen(0, 90), speed = 30 + gen(0, 100),
  }
end

local SPECIES = { 1, 4, 7, 16, 25, 37, 54, 63, 74, 92, 95, 129, 133, 143, 150, 252, 255, 258, 280, 303 }
local pairsList = {}
for i = 1, 24 do
  pairsList[i] = {
    mon(SPECIES[gen(1, #SPECIES)], 20 + gen(0, 50)),
    mon(SPECIES[gen(1, #SPECIES)], 20 + gen(0, 50)),
    double = (i % 3 == 0),
  }
end

local AI_FLAGS = { 7, 0x1F, 0x3F }

local function build(i)
  local p = pairsList[i]
  local st = State.new({
    wild = false, double = false,
    playerParty = { p[1] }, foeMon = p[2],
  })
  st.aiFlags = AI_FLAGS[(i % #AI_FLAGS) + 1]
  st.rng = lcg(1000 + i)
  return st
end

local states = {}
for i = 1, #pairsList do states[i] = build(i) end

local check = 0
local function mix(n)
  check = (check * 31 + (tonumber(n) or 0)) % 4294967291
end

local function section_ai()
  for n = 1, ITER do
    local i = (n % #states) + 1
    local st = states[i]
    st.rng = lcg(n)
    local act = Ai.chooseAction(st, 1, { rng = st.rng })
    if act then mix(act.slot or 0); mix(act.move or 0) end
  end
end

local function section_damage()
  for n = 1, ITER * 4 do
    local p = pairsList[(n % #pairsList) + 1]
    local mvId = p[2].moves[(n % 4) + 1]
    local dmg, info = Damage.calc({ mon = p[2] }, { mon = p[1] }, mvId,
      { forceRoll = 85 + (n % 16), forceCrit = (n % 11) == 0, rng = lcg(n) })
    mix(dmg or 0)
    if type(info) == "table" then mix((info.effectiveness or 1) * 100) end
  end
end

-- Rows are kept in a ring so the allocation escapes (LuaJIT would otherwise
-- sink the old per-call table and make the lookup look free).
local keep, keepN = {}, 0
local function section_moves()
  for n = 1, ITER * 20 do
    local id = (n % (movesCount - 1)) + 1
    local ok, row = pcall(Moves.get, id)
    if ok and row then
      keepN = (keepN % 64) + 1
      keep[keepN] = row
      mix(row.power or 0); mix(row.type or 0); mix(row.effect or 0)
    end
    local okp, pr = pcall(Moves.priority, id)
    if okp then mix(pr or 0) end
  end
end

local sections = { { "ai_choose", section_ai }, { "damage_calc", section_damage }, { "moves_lookup", section_moves } }

local function median(t)
  table.sort(t)
  return t[math.ceil(#t / 2)]
end

print(("[bench] game=%s iterations=%d runs=%d"):format(game, ITER, RUNS))
local total = {}
for _, s in ipairs(sections) do
  local times, alloc = {}, {}
  -- warmup (JIT) with checksum discarded
  s[2]()
  for r = 1, RUNS do
    collectgarbage("collect"); collectgarbage("stop")
    local m0 = collectgarbage("count")
    local t0 = os.clock()
    s[2]()
    times[r] = (os.clock() - t0) * 1000
    alloc[r] = collectgarbage("count") - m0
    collectgarbage("restart")
  end
  local ms, kb = median(times), median(alloc)
  total[#total + 1] = ms
  print(("BENCH %s %s ms=%.3f alloc_kb=%.1f"):format(game, s[1], ms, kb))
end
-- checksum is taken from a fresh single pass so warmup/run count can't change it
check = 0
for _, s in ipairs(sections) do s[2]() end
print(("CHECKSUM %s %d"):format(game, check))
