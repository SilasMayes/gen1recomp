# Gen 3 battle performance

Measured on the Ruby (1.2), Sapphire (1.2) and Emerald (1.0) ROMs with the
benchmarks in `tests/bench/` (see its README). "Before" is commit `7e2307f`,
"after" is this branch. Medians of 5 (logic) and 3 (presentation) interleaved
runs on one machine; compare ratios, not absolute times.

## What changed

- AI flag tests use `bit.band`/`bit.bor` instead of 32-step software loops.
- `Types.typeCalc` reads a per-attacking-type index of the type chart and no
  longer builds a closure per call.
- `Moves.get` returns a cached, shared read-only row instead of building a new
  table each call (invalidated when link rows or the ROM pack change).
- The AI VM shares one `jump` method instead of a closure per move, and AI
  damage is memoised for the length of one decision (it is pure there).
- `Damage` no longer re-requires modules or allocates tables on every call.
- The animation pack and the sound effects each known move plays are queued on
  the existing `Warm` budget when a battle starts, instead of being built on
  the frame the move first runs.

Results are bit-identical: the benchmark checksum covers every AI decision and
damage value.

## Logic benchmark (LuaJIT, real ROM data; median of 5 runs; lower is better)

| Game | Metric | Before | After | Improvement |
|---|---|---:|---:|---:|
| ruby | ai_choose (ms / pass) | 126.27 | 29.46 | +76.7% |
| ruby | ai_choose (KB allocated / pass) | 49360.30 | 15350.10 | +68.9% |
| ruby | damage_calc (ms / pass) | 9.71 | 4.92 | +49.3% |
| ruby | damage_calc (KB allocated / pass) | 5475.00 | 3468.80 | +36.6% |
| ruby | moves_lookup (ms / pass) | 1.94 | 0.90 | +53.4% |
| ruby | result checksum identical | ['1823984210'] | ['1823984210'] | yes |
| sapphire | ai_choose (ms / pass) | 115.37 | 33.29 | +71.1% |
| sapphire | ai_choose (KB allocated / pass) | 49717.50 | 15351.60 | +69.1% |
| sapphire | damage_calc (ms / pass) | 9.47 | 4.71 | +50.2% |
| sapphire | damage_calc (KB allocated / pass) | 5475.00 | 3468.80 | +36.6% |
| sapphire | moves_lookup (ms / pass) | 1.98 | 0.67 | +66.1% |
| sapphire | result checksum identical | ['1823984210'] | ['1823984210'] | yes |
| emerald | ai_choose (ms / pass) | 142.63 | 34.32 | +75.9% |
| emerald | ai_choose (KB allocated / pass) | 60149.90 | 15690.90 | +73.9% |
| emerald | damage_calc (ms / pass) | 9.24 | 4.99 | +46.0% |
| emerald | damage_calc (KB allocated / pass) | 5475.00 | 3469.40 | +36.6% |
| emerald | moves_lookup (ms / pass) | 2.10 | 0.86 | +58.8% |
| emerald | result checksum identical | ['442136261'] | ['442136261'] | yes |

## Presentation benchmark (LÖVE under Xvfb software GL; median of 3 runs; lower is better)

| Game | Metric | Before | After | Improvement |
|---|---|---:|---:|---:|
| ruby | avg frame ms | 7.34 | 7.27 | +1.0% |
| ruby | p95 frame ms | 11.45 | 11.49 | -0.3% |
| ruby | p99 frame ms | 14.72 | 14.71 | +0.0% |
| ruby | worst frame ms | 142.76 | 121.51 | +14.9% |
| ruby | battle start→menu ms | 5413.50 | 6146.30 | -13.5% |
| ruby | frames over 40 ms (count) | 12.00 | 5.00 | +58.3% |
| sapphire | avg frame ms | 7.25 | 7.14 | +1.5% |
| sapphire | p95 frame ms | 11.31 | 10.96 | +3.1% |
| sapphire | p99 frame ms | 14.62 | 14.48 | +1.0% |
| sapphire | worst frame ms | 138.89 | 62.87 | +54.7% |
| sapphire | battle start→menu ms | 5259.70 | 6030.40 | -14.7% |
| sapphire | frames over 40 ms (count) | 12.00 | 5.00 | +58.3% |
| emerald | avg frame ms | 6.68 | 6.50 | +2.7% |
| emerald | p95 frame ms | 10.23 | 10.01 | +2.2% |
| emerald | p99 frame ms | 13.41 | 13.35 | +0.5% |
| emerald | worst frame ms | 140.84 | 118.64 | +15.8% |
| emerald | battle start→menu ms | 5058.30 | 6262.10 | -23.8% |
| emerald | frames over 40 ms (count) | 12.00 | 6.00 | +50.0% |

## Reading the presentation numbers

- Per-frame cost is dominated by software GL under Xvfb, so average and
  percentile frame times barely move. The gain is in hitches: frames over 40 ms
  drop by roughly half and the worst frame is lower, but a one-off ~60 ms slice
  (parsing the animation pack) and some unattributed 50-70 ms frames remain.
- "Battle start to menu" is longer because that run is unthrottled: the sound
  and animation work moved into the intro now costs wall time there. At the
  game's fixed 60 Hz pacing the intro length is frame-counted, so this work is
  absorbed by the intro instead of landing mid-move, but it is extra CPU on
  slow devices during the intro.
- Hitches that are not accounted for here (for example first-use shader
  compilation on a real GPU) are not covered by this benchmark.
