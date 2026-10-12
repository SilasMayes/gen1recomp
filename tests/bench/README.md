# Gen 3 battle benchmarks

Both benchmarks need an imported Ruby, Sapphire or Emerald cache (import once
with `POKEPORT_IDENTITY=<id> POKEPORT_VERSION=<game> POKEPORT_IMPORT_ONLY=1
POKEPORT_IMPORT_ROM=<rom> love .`). No ROM data is stored in the repository.

## Logic (`game3_battle_logic_bench.lua`)

```
POKEPORT_GBA_CACHE=<save dir>/<id>/<game>/data/generated/gba GAME=<game> \
  luajit tests/bench/game3_battle_logic_bench.lua [iterations]
```

Times AI move choice, damage calculation and move lookups on a fixed,
deterministic roster. `CHECKSUM` covers every decision and damage value, so it
must be identical before and after an optimisation.

## Presentation (`game3_battle_present_bench.lua`)

```
POKEPORT_IDENTITY=<id> POKEPORT_VERSION=<game> \
  POKEPORT_DRIVER=tests/bench/game3_battle_present_bench.lua xvfb-run -a love .
```

Plays a wild battle through the mon's four moves three times and prints
`PBENCH` lines: frame-time percentiles, the frames over 40 ms with the battle
step they landed on, and when the animation pack loaded. `PBENCH_WRAP=1` also
times the animation modules and slow warm-job slices to attribute hitches.
The run is unthrottled and software-rendered, so compare builds on the same
machine rather than reading the absolute numbers.
