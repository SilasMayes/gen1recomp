# Hoenn Diorama

The Ruby, Sapphire and Emerald overworld as a 3D diorama. No new art: the
diorama is folded out of the 16x16 metatiles your own ROM import already
baked, so it shows exactly the tiles, palettes and tile animations the 2D
field does.

It is a render pipeline (see `docs/modding.md`, "Rendering pipelines"), so the
engine handles the options row, the hotkey, saving your choice, and falling
back to the normal 2D field if anything goes wrong.

## Requirements

- An engine with the **Gen 3 world render pipeline**
  (`src/core/game3/world_pipeline.lua`). This mod was built alongside that
  engine change. On an engine without it, the mod loads but does nothing on
  Gen 3: no OPTION row, no hotkey.
- Ruby, Sapphire or Emerald, imported from your ROM.
- A GPU that supports shaders and depth-buffered canvases (every desktop, and
  the phones and handhelds LÖVE 11 runs on). Without one, the mode stays
  unavailable and the 2D field is used.

## Install

1. Run an engine build that has the Gen 3 world render pipeline.
2. **MODS → Import mod .zip** and choose `hoenn_diorama-1.7.0.zip`, or unzip
   it into the `mods/` folder.
3. Enable **Hoenn Diorama** and start your Hoenn save.

## Use

| control | does |
| --- | --- |
| **OPTION → DIORAMA** | OFF / 45 / 35 / 25: camera pitch in degrees |
| `6` | cycles the same ladder (free roam only) |

**45** keeps the 2D field's proportions, adding depth and parallax. **35** and
**25** lower the camera, so you see further north and the scene looks
more three-dimensional.

Mod options (MODS → Hoenn Diorama):

| option | values | effect |
| --- | --- | --- |
| STRUCTURE HEIGHT | LOW / NORMAL / TALL | how many rows of a cliff's, hedge's or forest's front stand up (1, 2 or 3); a building reads its walls' height off its own front |
| GRASS TUFTS | ON / OFF | a short tuft on the front edge of tall grass |
| SHADOWS | ON / OFF | sun shadows (turn off on slow GPUs) |
| TERRAIN HEIGHT | ON / OFF | mountains, terraces and beaches at their real levels; OFF lays all ground flat |
| BUILDING PROFILE | ON / OFF | buildings listed in `data/buildings.lua` are built from their written reading; OFF reads every building off its pixels, as 1.6.0 did |

Turning DIORAMA on turns TILT off; they are two answers to the same question.

## How it works

Hoenn's art is drawn in three-quarter view: a building's facade is painted
as seen from the front, and its roof fills the screen rows above it. The
diorama refolds that art instead of inventing shapes.

- A column of blocked cells on the structure layer (elevation 0) is a
  structure, and the columns beside it with the same rows are one block.
  The art is an oblique projection: a point (x, y, z) lands on the drawing
  at (x, z - y), which is what a camera at 45 degrees sees. So a face can be
  textured with the drawing *projected* onto it, and it shows the drawing
  exactly at 45 degrees whatever its shape (`lib/Hip.lua`):
  - **A building** (a block with a door along its front) is a solid. Its
    walls go round its whole collision footprint, as high as its front's
    eaves (read off the facade's colours). The roof is hipped on all four
    sides with its ridge over the middle, at the slope that lays the drawn
    roof over the front half exactly. Past the drawing's top row, the
    camera sees the back of the roof, which takes the front's texels
    mirrored about the ridge. The roof's two layers become one opaque copy,
    so a roof drawn on the overhead layer over grass has no grass or holes;
    a walkable top row takes its overhead art alone.
  - Where that slope would be flatter than 0.45 (a roof drawn short for a
    deep footprint, every row of it collision), the solid stands only as
    deep as the drawing makes it at 0.45, its walls as drawn, and the
    collision behind it is open ground.
  - **A two-storey house** (a band of upper wall drawn between two roofs, as
    on Littleroot's houses) gets its upper storey: the lower roof is a skirt
    round the house, and the upper storey stands back from the eaves with
    walls as high as the drawn band and its own hipped roof. The band's
    height, the skirt's depth and how far the storey stands back are read
    off the facade's colours.
  - A tree from the wood behind that is drawn over a building's top corner
    stands over the building; the building keeps its whole roof.
  - **Anything else that stands** (a cliff, a rock, a hedge, a fence) is a
    block with a flat top at the facade's height, and a back plane at
    exactly 45 degrees behind it, edge-on to the 45 degree camera.
  - The side walls repeat a plain stretch of the facade: its commonest
    colours, away from the corners, with each height taking the facade's
    row at that height. They never smear one column along the wall.
  - At 45 degrees, the field looks as it does in 2D. Lower the camera and you
    see the walls and the hipped roofs, and a building hides what stands
    behind it.
- The ground has levels (`lib/Relief.lua`). Hoenn's General tileset draws a
  mountain with a handful of pieces, and each spans exactly one level (16
  pixels): a **face** (a cliff's south wall) is one level down per tile, a
  **band** (a west or east side) one level across, a **top** is flat. So the
  levels are counted, not guessed. The walkable ground, the tops and the
  water are cut into regions, every column of faces and row of bands
  between two regions is a vote for how far apart they are, and the votes
  most agreed on win. A wood or a row of houses counts too: the faces under
  it say how high it stands. The largest ground is level 0. Each cell is
  lifted by its height and moved as far south, so at 45 degrees the field is
  still exactly the 2D drawing; a face is a vertical wall, a band a 45 degree
  slope, and lower the camera to see the terraces. Rocks in the sea rise as
  small crests, the sea stays one level, and the map border lies at the
  level of the map's edge. People stand on the ground under them, and the
  camera follows the ground's height, gliding up stairs.
- Sun shadows: everything standing is drawn once more from the sun into a
  depth map, and the ground, the buildings and the people sample it. Rooms
  get a softer shadow than the sun outside.
- Forests are recognised by their art (tree metatiles are partly the grass
  they were painted on, and repeat every two rows) and stand as one card per
  tree: trunk, canopy, and the top of the canopy that pokes into the row
  behind. Trees directly behind a hedge or a building are split off from it.
  A wood drawn on the overhead layer (Dewford's hill) is told by the art
  that shows, and rocks standing in the sea stand on the water.
- Standing art is cut out against the ground it was painted on: the colours
  of the map's usual ground metatile (or the water, for a rock in the sea),
  plus the darker shade of that ground around a tree, become transparent on
  trees, signs and posts. Buildings and hedges stay solid: stray ground at
  their edges is painted over with the art next to it. Room furniture is
  trimmed instead: the floor's colours go only where they reach an edge that
  faces the floor, so a crate keeps its grey sides and a table on a rug shows
  the rug between its legs. These copies are made
  on the CPU from the atlas the engine already decoded, a few 512x512 pages
  per area.
- Walkable cells whose overhead layer covers actors (tree canopies, roof
  ridges) are the top of the structure below them. The overhead art goes up
  with the structure, and the ground under it stays where you walk.
- A blocked cell on the walking layer (signs, mailboxes, posts) is a 16px card.
  The same goes for a cell that sticks out one row under a wider building.
- Rooms: nothing is drawn outside the room. The back wall stands as tall as
  the room's walls usually are. Furniture the game tags for reading (shelves,
  TVs, PCs, bins, machines) stands at full height. Anything else
  free-standing (a table, bed, counter or crate) is a low block, with its
  front row standing, the rest as its top, and the floor running under it.
- The border past a map's edge stays out of the structures at the edge:
  border trees stand as trees, the rest lies flat.
- Water sits 4px below its banks, ledges are a low step, and tall grass gets a
  tuft.
- Actors are drawn into a sprite sheet by the engine's own draw path every
  frame, then stood up as cards with a blob shadow. That covers the player,
  NPCs, the follower, field effects and other mods' actors. Door animations,
  Flash darkness and weather sprites draw over the scene the same way.

Geometry is built in 16x16-cell chunks, nearest first and a row at a time,
inside a per-frame time budget, so a slow device spreads the work across
frames instead of stuttering. Chunks survive walking across a map seam. A
metatile change (Cut, Rock Smash, puzzles) rebuilds the affected chunks while
the old ones keep drawing.

## The building profile

`data/buildings.lua` lists building drawings a person has read: each one's
metatile grid, and what each pixel row of the drawing shows (back slope,
ridge, front slope, flat roof, fascia, eave line, wall, base), with the
ridge's row where the drawing shows one. `lib/Buildings.lua` finds a listed
drawing wherever its grid stands (a primary-only grid in any town of that
primary, one with secondary ids only with that secondary) and works out the
numbers Hip.lua builds with: the front wall's height, an upper storey's
band, the drawn ridge, a flat roof, a front standing half a row out.

Only what needs a person is written down; heights, slopes and depths are
measured from those rows. Nothing in the file comes from the cartridge:
metatile ids, row numbers and names. `inset` and `chamfer` are read and
checked but not built yet.

To add a drawing: find a copy on a map, write its grid (`false` for a cell
each town paints its own way), read its rows top-down, and run the tests,
which check every entry and that each drawn ridge stands.

## Known limitations

- Only the General tileset's mountains are counted. Mountains drawn with a
  town's own rock (Route 112's red, Route 115's beige, Mt Chimney, Jagged
  Pass, Fallarbor, Route 126's white) leave their map flat, their cliffs
  standing as blocks as before.
- Where trees or houses stand between two levels with no cliff drawn, the
  step between them is a plain earth wall.
- A ledge is a low step, not a drop: the ground on both sides is one level.
- Battle transitions, the barn-door wipe and BG mosaic play on the flat field
  (the same rule TILT follows).
- Water reflections, the Poké Center heal machine animation and the weather
  colour grading (drought, fog tint) are not drawn in 3D. Weather sprites are.
- Ground effects such as footprints and ripples stand up as small cards
  instead of lying flat.
- Cut-outs are copies made when a chunk is built, so a standing tile the ROM
  animates keeps the frame it had then. Flowers and water lie flat and keep
  animating.
- A structure painted on a different ground than the map's usual one (a
  house on a sand lot in a grassy town) keeps that ground's colours at its
  edges.
- A building's roof is hipped, with an upper storey only where the front
  draws one as a band of wall, or flat where the profile says it is drawn
  from above. A dome, a chimney, a vent or the machine on Birch's lab is
  painted on the roof, not modelled.
- Petalburg's Mart shows a few leaves of the tree drawn over its roof's
  corner on the roof; the pixel reading moved them onto the tree, the
  profile does not yet.
- A listed building is built from whole cells across: a porch narrower than
  its cells (the Gym's) stands as wide as them, and walls set in from the
  roof's edges, or front corners cut at 45 degrees (the Center, the Mart),
  are read but not built.
- Furniture the game does not tag is a low block whatever its real height:
  a wardrobe the game doesn't mark as a shelf comes out knee-high.
- People cast a blob shadow, not a sun shadow. Sun shadows are cast by
  the map itself.
- Woods drawn with a town's own trees (Fortree's, Mossdeep's) stand as
  blocks, not as trees.
- A walk-in doorway (Slateport's shipyard) splits the building's front
  around it.
- Built and tuned against Littleroot, Oldale, Petalburg, Petalburg Woods,
  Rustboro, Dewford, Routes 101–104, 106, 107, 110–112, 115 and 116, and the
  Littleroot, Petalburg and Pokémon Center interiors; Slateport, Mauville,
  Verdanturf, Fallarbor, Lavaridge, Fortree, Lilycove, Mossdeep, Sootopolis,
  Pacifidlog and Ever Grande have been looked at once. Other areas use the
  same rules, but caves have not been looked at yet.

## Credits

The buildings, rooms, map border and terrain follow what the Emerald 3DS
port learned building its voxel overworld (github.com/ZallaxDev/emerald-3ds,
MIT):

- The drawing as an oblique projection, with projected faces wherever the 45
  degree view looks.
- Buildings at their real footprint depth, with hipped roofs.
- Side walls dressed from a plain stretch of the facade.
- In a room, the back wall and what the game tags stand, and nothing is
  drawn outside the room.
- The border stays out of the structures at the map's edge.
- The terrain's levels counted off the General tileset's mountain pieces,
  each a level: which pieces are faces and which are sides follows its
  tables (`voxel_terraces.py`, `gen_voxel_relief.py`).

Its models are written by hand for each building, and its relief is solved
offline. This mod reads every building and mountain the same way, at run
time, from your ROM's own tiles, except the drawings its own profile lists
(`data/buildings.lua`, read for this mod, the way Dramatic Shape pins its
tiles and Emerald 3DS writes its specs). No code is copied from it; the tile roles
above are the only data taken, with this credit.

## Checking a change

From the engine root, with this mod in `mods/hoenn_diorama`:

```
luajit mods/hoenn_diorama/tests/hoenn_diorama_test.lua
python3 tools/modkit.py validate mods/hoenn_diorama
python3 tools/modkit.py gen3check mods/hoenn_diorama
```

The test suite covers the shape rules (boxes, roofs and back slopes,
forests, furniture, cut-out choices, banks), the building profile (every
entry checked, matching, the numbers, drawn ridges, flat roofs, a foot in
the row below), the relief (levels counted on
small maps, steps, lifted cells), the cut-out pixels, the mesher, the
camera's framing and the chunk cache headless. It also loads the mod through the real loader on a
Gen 3 dataset. Rendering itself needs a GPU, so check it in game, or with a
small LÖVE harness that hands `Scene:draw` a ctx.
