# Changelog

Format: [keep a changelog](https://keepachangelog.com/en/1.1.0/).
Version headings match `manifest.json`'s `version`.

## 1.7.0

### Added

- **A building profile** (`data/buildings.lua`). For a building drawing
  listed there, a person has read once which rows are roof, ridge, fascia
  and wall; that reading is used wherever the drawing stands, instead of
  the guess off its pixels. A drawing that is not listed keeps the 1.6.0
  reading. Listed: Petalburg's two house drawings, Oldale's houses,
  Littleroot's two houses and Birch's lab, the Pokémon Center, the Poké
  Mart, the Gym, Route 104's flower shop and Mr. Briney's cottage: 11
  drawings, 42 placements across Hoenn.
- **BUILDING PROFILE** mod option (ON by default). OFF draws exactly as
  1.6.0 did.

### Changed

- A listed drawing stands as one solid along its front. Route 104's flower
  shop is one roof instead of four humps, and the wood behind it stands as
  trees instead of being painted onto that roof.
- What stands behind a listed building (a wood, a cliff, a tree drawn over a
  Mart's corner) is a structure of its own, never part of the building.
- A house whose drawing shows its ridge and back slope (Petalburg's,
  Oldale's, Mr. Briney's) stands on that ridge: the ridge cap is on the
  ridge, the back slope shows the drawing's own back slope instead of the
  front mirrored, and the house is as deep as its drawing, with the
  collision behind it left as open ground.
- A roof drawn from straight above (the Gym, Birch's lab) is flat at the
  eaves' height, as deep as drawn, instead of hipped.
- The Gym is one building: its wings stand as buildings although their
  front has no door, and their front wall stands where it is drawn, half a
  row into the walkable row under the collision, so the wings and the
  porch share one roof height.
- The eave line and fascia of a listed building stand as part of its front
  wall.

## 1.6.0

### Changed

- A building whose roof is drawn too short for its collision's depth (all
  its rows collision, as on Verdanturf's contest hall, a shop at a map's top
  edge, and most houses with a single row of roof under the ridge) stands
  only as deep as its drawing makes it at a roof slope of 0.45, its walls as
  high as drawn, with the collision behind it left as open ground. Before,
  its roof came out nearly flat or its walls were cut down.

### Fixed

- Trees whose canopy is drawn whole on the overhead layer (General's narrow
  trees: Routes 111, 112 and 116, behind Mauville's Pokémon Center) stand as
  trees. They no longer stand as boxes with walls of grass, or get painted
  onto the roof in front of them.
- A sign standing one row out under two houses side by side (Lavaridge) is
  its own card. It no longer pulls a column of the houses down to it.
- Route 110's rock right under the fence stands in the sea on its own; it
  no longer joins the fence into a box of water. A rock or a card in the
  sea takes the sea under it, not the grass on the far side of a fence.
- A cliff's edge drawn in the ground's colours, one tile down every row
  (Sootopolis's white rock), is no longer taken for a wood and cut full of
  holes; a wood is a two-row tiling.
- Cut-outs keep the ground's colours the art encloses (a highlight inside a
  rock or a canopy); only the ground reaching a cell's edge goes.

## 1.5.0

### Added

- **Two-storey houses.** Where a house's front draws a band of upper wall
  between two roofs (Littleroot's houses), the lower roof is a skirt round
  the house and the upper storey stands back from the eaves, with walls as
  high as the band and its own hipped roof. The band, the skirt and the
  set-back are read off the facade's colours; a house drawn with one roof
  keeps one.

### Fixed

- Petalburg's and Oldale's Poké Marts: a tree from the wood behind, drawn
  over the roof's top corner, no longer cuts a column off the building. The
  building keeps its whole roof, and its walls stand as high as the drawn
  front (the eaves are no longer read at the shop's sign under its awning).
- Dewford's hill wood, drawn on the overhead layer, stands as trees instead
  of a box of ground.
- Route 110's rocks standing in the sea stand on the water instead of rising
  as columns of sea, with no grass banks between them.
- Oldale's south-east house: the tops of the trees in front of it, drawn
  under its front row, no longer join its east half to the wood, which cut
  the house in two and stood half of it as trees. Tree tops under a blocked
  row now always start a structure of their own.
- A walkable roof row (the top of a roof drawn on the overhead layer) takes
  only its overhead art: grass of another shade than the map's usual ground
  beside it (Oldale's Pokémon Center) no longer shows on the roof's slope.

## 1.4.0

### Added

- **The ground has levels.** Mountains, terraces, cliffs and beaches stand
  at their real heights, counted off the General tileset's mountain pieces:
  a cliff's face is one level (16 pixels) down per tile, a side one level
  across, a top is flat. Each cell is lifted by its height and moved as far
  south, so at 45 degrees the field is still the 2D drawing; lower the
  camera and the terraces stand up. Route 116's mountain, Dewford's hill,
  Route 104's beach under its cliff and Rustboro's rocks have their steps.
- Rocks in the sea rise as small crests instead of standing as boxes of
  water.
- People stand on the ground under them, and the camera follows its height,
  gliding up a flight of stairs instead of jumping.
- New option **TERRAIN HEIGHT** (ON / OFF): OFF lays all ground flat, as in
  1.3.0.

### Changed

- Where raised ground meets water, its edge runs straight down to the water
  line; where it meets lower ground, a wall dressed with its own art closes
  the step.
- The sun's shadow frame follows how high and low the drawn scene reaches.

### Fixed

- The overhead layer of a wall or a flat top was lifted twice on raised
  ground and drew in the wrong place.

## 1.3.0

### Changed

- **Buildings are solids.** A building (a block with a door along its front)
  has walls round its whole collision footprint and a roof hipped on all four
  sides. Its ridge is over the middle, at the slope that lays the drawn roof
  over the front half exactly. Every face the 45 degree camera sees takes the
  drawing projected onto it, so at 45 the field is still the 2D drawing. Past
  the drawing's top, the camera sees the back of the roof, which takes the
  front's texels mirrored about the ridge. This replaces 1.2.0's gable ends
  and hidden back slope.
- The walls are as high as the front's eaves, read off the facade's colours,
  not a fixed two rows. Littleroot's houses get their 28-pixel walls.
- A roof's overhead and ground layers are one opaque copy. A roof drawn on
  the overhead layer over grass no longer shows grass or holes at its
  corners.
- Side walls repeat a plain stretch of the facade (its commonest colours,
  away from the corners), each height taking the facade's row at that
  height, instead of one edge column smeared along the wall.
- Cliffs, rocks, hedges and fences (blocks without a door) have a flat top
  and a back edge-on to the 45 degree camera, with no roof pitch. The tan
  and grey triangles at their ends are gone.
- An overhang row that runs on past a building (a hedge's top passing behind
  a house) is no longer taken for the building's ridge.

## 1.2.0

### Added

- Buildings have real depth. A building now reaches back over its whole
  footprint, with its roof rising toward the ridge, side walls and gable ends,
  and a hidden back slope down to the ground behind. At the 45 camera, every
  pixel still lands where the 2D field drew it. At 35 and 25 you see the
  sides, and a building hides what stands behind it.
- Sun shadows: buildings, trees, signs and furniture cast shadows on the
  ground, on each other and on the people walking past. The new `SHADOWS`
  option (ON / OFF) turns them off for slower machines.

### Changed

- Room furniture stands up again. What the game tags as a shelf, TV, PC
  or machine keeps its full height. Anything else free-standing (a table,
  bed, counter or crate) is a low block with a front, a top and sides, and
  the floor runs under it.
- Room furniture is trimmed, not cut. The floor colours around a piece
  are removed only where they reach an edge that faces the floor, so floor
  colours inside a piece's outline (a crate's grey sides, a TV's casing)
  stay. A table on a rug shows the rug between its legs.
- A piece on the edge of a rug is cut out against the rug beside it, not the
  floorboards behind it.
- The floor no longer darkens in front of room furniture, which now casts its
  own shadow instead.

### Fixed

- Trees beside a sand path (Littleroot's north exit) stood as solid green
  boxes.
- Holes in crates and other furniture where their art uses the floor's
  colours.

## 1.1.0

### Changed

- Rooms follow the game's own tags: the back wall stands, shelves, TVs,
  PCs and other furniture the game marks for reading stand up, a counter is
  a low block, and everything else (beds, tables, rugs, crates) lies flat
  where it was drawn. Nothing is drawn outside a room, and the black filler
  between a gym's rooms stays black.
- A room's back wall is as tall as the room's walls usually are; a counter
  or shelf built against it is furniture of its own.
- The border past a map's edge no longer joins the buildings and forests at
  the edge. Border trees stand as trees; other border tiles lie flat.
- Cut-out signs and furniture keep their own shading; only outdoor cards
  (trees, signs on grass) also lose the ground's darker shade around them.
- A structure on a rug or a sand lot is cut out against that ground when it
  is a plain one.

### Fixed

- Stripes of wall tiles across the screen outside rooms.
- Trees along a map's edge split by a band of grass.
- Spikes above some rooms' back walls.
- Notches in a back wall where a counter stands in front of it.

## 1.0.0

### Added

- The DIORAMA render pipeline for Ruby, Sapphire and Emerald: OFF / 45 / 35 / 25
  camera pitch, on the OPTION menu and the `6` key.
- Structures stand up from the map's own collision, elevation and overhead
  layer: facades, roofs, signs, ledges, sunken water with banks, tall-grass
  tufts.
- Cut-outs: each standing card has its ground colours taken out of the ROM
  art, so trees, signs and posts get their own outline, and rocks in the sea
  are cut out against the water. Buildings and hedges stay solid; stray
  lawn at their edges is painted over with the wall beside it, and their
  side walls take the facade's own edge colour.
- Forests stand as individual trees: each tree is one card (trunk, canopy and
  the top that pokes into the row behind), with ground under every tree.
  Trees directly behind a hedge or a building are split off from it.
- Actors (player, NPCs, follower, field effects, other mods' actors) and the
  door animation are drawn through the engine's own draw path as upright cards
  with blob shadows.
- Flash darkness and weather sprites over the 3D scene.
- `STRUCTURE HEIGHT` (LOW / NORMAL / TALL) and `GRASS TUFTS` mod options.
