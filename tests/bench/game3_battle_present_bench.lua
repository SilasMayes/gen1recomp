-- Gen 3 battle presentation benchmark (POKEPORT_DRIVER script, run under xvfb).
--   POKEPORT_IDENTITY=<imported identity> POKEPORT_VERSION=ruby|sapphire|emerald \
--   POKEPORT_DRIVER=tests/bench/game3_battle_present_bench.lua xvfb-run -a love .
-- Plays one wild battle with ten different moves and prints PBENCH lines:
-- frame-time percentiles, the worst spikes, and the cost of every animation
-- lookup (the first one pays for loading the animation pack).

local U = require("tests.drivers.util")

return function(game)
  local version = os.getenv("POKEPORT_VERSION") or "emerald"
  local function out(...) print("PBENCH", version, ...) end

  for _ = 1, 900 do
    if game.phase == "boot" and game.boot then break end
    U.wait(1)
  end
  game:_handleBootAction({ action = "new_game", name = "BENCH", gender = 0 })
  U.wait(240)

  local Runtime = require("src.core.game3.runtime")
  local Party = require("src.core.game3.party")
  local BattleBridge = require("src.core.game3.battle_bridge")
  local Battle = require("src.core.game3.battle")
  local Ui = require("src.core.game3.battle.ui")
  local Anim = require("src.core.game3.battle.anim")
  local AnimSeq = require("src.core.game3.battle.anim_seq")
  local C = require("src.core.game3.constants").of(version)
  local session = Runtime.getSession()
  if not session then out("error", "no session") love.event.quit(1) return end

  local function sp(name) return C.species.byName["SPECIES_" .. name] end
  local function mv(name) return C.moves.byName["MOVE_" .. name] end

  session.party = {}
  Party.giveMon(session, sp("SALAMENCE"), 50, "SALAMENCE")
  local m = session.party[1]
  m.moves = { mv("EMBER"), mv("THUNDERBOLT"), mv("EARTHQUAKE"), mv("SWORDS_DANCE") }
  m.pp = { 40, 40, 40, 40 }
  m.maxPp = { 40, 40, 40, 40 }
  m.hp = m.maxHp or m.hp

  -- time every animation script lookup; the first call loads the pack
  local lookups = {}
  for _, fn in ipairs({ "scriptForMove", "scriptForStatus" }) do
    local orig = Anim[fn]
    if type(orig) == "function" then
      Anim[fn] = function(...)
        local t0 = love.timer.getTime()
        local a, b, c = orig(...)
        lookups[#lookups + 1] = { fn = fn, ms = (love.timer.getTime() - t0) * 1000 }
        return a, b, c
      end
    end
  end

  -- optional: PBENCH_WRAP=1 times every exported function of the animation
  -- modules (inclusive ms) to attribute hitches; off for the headline numbers
  local wrapStats = {}
  if os.getenv("PBENCH_WRAP") == "1" then
    for _, modName in ipairs({ "anim", "anim_vm", "anim_pal", "anim_tasks", "anim_seq", "anim_context", "anim_ctx",
                               "anim_callbacks", "ball_open", "healthbox", "ui", "pic_coords", "intro_seq" }) do
      local ok2, mod = pcall(require, "src.core.game3.battle." .. modName)
      if ok2 and type(mod) == "table" then
        for k, v in pairs(mod) do
          if type(v) == "function" and k ~= "update" and k ~= "draw" then
            local label = modName .. "." .. k
            local function fin(a, ...)
              local ms = (love.timer.getTime() - a) * 1000
              local e = wrapStats[label]
              if not e then e = { n = 0, total = 0, max = 0 }; wrapStats[label] = e end
              e.n, e.total = e.n + 1, e.total + ms
              if ms > e.max then e.max = ms end
              return ...
            end
            mod[k] = function(...)
              return fin(love.timer.getTime(), v(...))
            end
          end
        end
      end
    end
  end

  if os.getenv("PBENCH_WRAP") == "1" then
    local Audio = require("src.core.game3.audio")
    local origWarm = Audio.prewarmSe
    Audio.prewarmSe = function(id, pr)
      out("prewarm_queued", tostring(id), "prio", tostring(pr))
      return origWarm(id, pr)
    end
    local origPlay = Audio.playSe
    Audio.playSe = function(id, opts)
      local a = love.timer.getTime()
      local r1, r2 = origPlay(id, opts)
      local ms = (love.timer.getTime() - a) * 1000
      if ms > 5 then out("slow_se", tostring(id), string.format("%.1fms", ms)) end
      return r1, r2
    end
  end

  local t0 = love.timer.getTime()
  local ok, err = BattleBridge.startWild(Runtime._mod, game, { species = sp("ZIGZAGOON"), level = 45 }, { fade = false })
  if not ok then out("error", tostring(err)) love.event.quit(1) return end

  local frames, spikes = {}, {}
  local last = love.timer.getTime()
  local packFlag = Anim._packLoaded
  local packLoadedAt
  local function describe()
    local s = AnimSeq._steps and AnimSeq._steps[AnimSeq._i]
    local what = s and (tostring(s.kind) .. ":" .. tostring(s.data and (s.data.name or s.data.move) or "")) or "-"
    return string.format("phase=%s mode=%s step=%s", tostring(Battle._phase), tostring(Ui._mode), what)
  end
  local function step()
    U.wait(1)
    local now = love.timer.getTime()
    local ms = (now - last) * 1000
    frames[#frames + 1] = ms
    if ms > 40 then spikes[#spikes + 1] = string.format("#%d %.1fms %s", #frames, ms, describe()) end
    if Anim._packLoaded and not packFlag and not packLoadedAt then
      packLoadedAt = string.format("frame #%d (%.1f ms frame) %s", #frames, ms, describe())
      packFlag = true
    end
    last = now
  end

  local lastTap, f = 0, 0
  local function pump_text()
    f = f + 1
    if Ui.dialogPending and Ui.dialogPending() and f - lastTap >= 14 then
      lastTap = f
      U.tap(game, "a")
      return true
    end
    return false
  end
  local function at_command() return Battle.isActive() and Battle._phase == "command" and Ui._mode == "menu" end

  for _ = 1, 4000 do
    if at_command() then break end
    if not pump_text() then step() end
  end
  local battleStartMs = (love.timer.getTime() - t0) * 1000
  local st = Battle.getState()
  if not st then out("error", "no battle state") love.event.quit(1) return end
  st.enemy.mon.maxHp = 9999
  st.player.mon.maxHp = 9999

  -- Real play: the mon's own four moves, three rounds each (the first use of
  -- each is the interesting one; later rounds show steady-state frame cost).
  frames = {}
  last = love.timer.getTime()
  for round = 1, 3 do
    for slot = 1, 4 do
      local id = st.player.mon.moves[slot]
      if id and id ~= 0 then
        st.player.mon.pp = st.player.mon.pp or {}
        st.player.mon.pp[slot] = 10
        st.enemy.mon.hp, st.player.mon.hp = 9999, 9999
        Ui._pendingCommand = { kind = "move", move = id, slot = slot, user = "player" }
        Ui._mode = "none"
        for i = 1, 3000 do
          if not Battle.isActive() then break end
          if i > 5 and at_command() then break end
          if not pump_text() then step() end
        end
      end
    end
  end

  table.sort(frames)
  local n = #frames
  local function pct(p) return frames[math.max(1, math.min(n, math.ceil(n * p)))] or 0 end
  local sum = 0
  for _, v in ipairs(frames) do sum = sum + v end
  out("frames", n)
  out("battle_start_ms", string.format("%.1f", battleStartMs))
  out("frame_avg_ms", string.format("%.3f", n > 0 and sum / n or 0))
  out("frame_p50_ms", string.format("%.3f", pct(0.50)))
  out("frame_p95_ms", string.format("%.3f", pct(0.95)))
  out("frame_p99_ms", string.format("%.3f", pct(0.99)))
  out("frame_max_ms", string.format("%.3f", frames[n] or 0))
  local worst = {}
  for i = n, math.max(1, n - 4), -1 do worst[#worst + 1] = string.format("%.1f", frames[i]) end
  out("worst5_ms", table.concat(worst, ","))
  local first = lookups[1] and lookups[1].ms or 0
  local total = 0
  for _, l in ipairs(lookups) do total = total + l.ms end
  out("anim_pack_loaded", tostring(Anim._packLoaded), packLoadedAt or "before benchmark window")
  for i = 1, math.min(#spikes, 12) do out("spike", spikes[i]) end
  out("anim_lookups", #lookups)
  out("first_anim_lookup_ms", string.format("%.1f", first))
  out("anim_lookup_total_ms", string.format("%.1f", total))
  if next(wrapStats) then
    local rows = {}
    for k, e in pairs(wrapStats) do rows[#rows + 1] = { k = k, e = e } end
    table.sort(rows, function(a, b) return a.e.max > b.e.max end)
    for i = 1, math.min(#rows, 18) do
      local r = rows[i]
      out("wrap", string.format("%-34s n=%-6d max=%8.1fms total=%9.1fms", r.k, r.e.n, r.e.max, r.e.total))
    end
  end
  love.event.quit(0)
end
