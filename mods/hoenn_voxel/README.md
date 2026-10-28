# Hoenn Voxel

The Ruby, Sapphire and Emerald overworld in 3D, built at run time from the
metatiles your own ROM import baked. Nothing ROM-derived ships with the mod.

**VOXEL** is a display mode: OPTION menu, or the **7** key. OFF / 45 / 40 /
34 are camera angles, in degrees down from level. At 45 the scene is the
game's own drawing seen through a lens; lower angles show what the heights
are.

It needs the engine's Gen 3 world render pipeline
(`src/core/game3/world_pipeline.lua`, docs/modding.md "Rendering pipelines,
On Gen 3"), and the `background` permission for counting terrain off the
main thread (without it, the count runs on the frame).

## How it works

The method is two others', mimicked rather than copied.

**The drawing is the truth** (Emerald 3DS). A point the game draws at (u, v)
that stands h pixels high is placed at (x, y, z) = (u, h, v + h). A camera
looking north and down at 45 degrees sees it at (u, v) again, whatever h is.
So every surface is textured with the drawing at (x, z - y): the heights
decide only what the scene does away from 45 degrees, and no choice of
heights can make the 45-degree view wrong. Where two cells' heights differ,
the step between them is closed by a surface the 45-degree view sees edge-on
or not at all (lib/Builder.lua).

**Terrain is counted, not guessed** (Emerald 3DS). The General tileset draws
a mountain with a handful of square pieces, each one level (16 pixels): a
top, a face, a band down a side, a face's end. A column of k rock cells
between two flat cells says the upper one stands k levels over the lower;
every column and row votes, the levels are taken greatest vote first, and a
vote that contradicts what is decided is dropped. Then every rock cell takes
the piece and level that meets its neighbours best (lib/Terrain.lua; the
tile sets, colours and prices are in data/terrain.lua).

**The cart first** (Dramatic Shapes). What the cartridge says outranks the
art: a door's cell is the bottom row of a building; a walkable region the
elevation byte puts above the ground is a deck; a bridge's behaviour says how
high it stands. The art is read where the cart says nothing: what is roof and
what is wall, what is leaves, where a ledge's lip is. One place decides every
cell's height (lib/Analysis.lua).

| file | what it does |
| --- | --- |
| `main.lua` | the pipeline record, the frame |
| `lib/Source.lua` | the ctx, once a frame, in a frame that survives seams |
| `lib/Reader.lua` | reads each map once: cart, art, count, models |
| `lib/Terrain.lua` | counted levels and settled pieces (pure Lua, runs in a job) |
| `lib/Trees.lua`, `lib/Props.lua`, `lib/Buildings.lua`, `lib/Decks.lua` | what stands on the cells |
| `lib/Relief.lua` | a cell's heights: four corners or a profile |
| `lib/Builder.lua` | a cell's drawing on its relief, and the steps between cells |
| `lib/Models.lua` | tree and prop cards, building columns and ends |
| `lib/World.lua` | 8 x 8 blocks of meshes, rebuilt when what they read changes |
| `lib/Actors.lua` | actors drawn into a sheet, stood as cards |
| `lib/Overlay.lua` | Flash darkness and weather over the 3D view |
| `lib/Cache.lua` | counts kept in mod.cache, keyed by what they read |

## Checking a change

```sh
luajit mods/hoenn_voxel/tests/hoenn_voxel_test.lua
python3 tools/modkit.py validate mods/hoenn_voxel
python3 tools/modkit.py lint mods/hoenn_voxel
```

The test loads the mod through the real loader on a Gen 3 boot, checks the
lift identity on every piece and step, counts a small mountain and checks the
camera. Rendering is checked with a local harness over pret-derived fixtures
(never shipped): `Camera.oblique` renders in the GBA's own projection, which
must reproduce the flat field pixel for pixel.

## Credits

- [Emerald 3DS](https://github.com/ZallaxDev/emerald-3ds) (MIT): the method,
  and its readings of the General tileset restated in `data/`.
- [Gen2Recomped Dramatic Shapes](https://github.com/UNDERdecoded/Gen2Recomped-DramaticShapes):
  the cart-first approach. None of its code is used.
- [pret/pokeemerald](https://github.com/pret/pokeemerald): behaviour names.
