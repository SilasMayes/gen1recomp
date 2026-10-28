# Changelog

## 0.1.0

A fresh start, not a continuation of Hoenn Diorama: none of its code is
used.

- Every drawn point stands at (u, h, v + h) (Emerald 3DS's identity), so the
  45-degree view of the scene is the drawing, whatever the heights. Checked
  by rendering in the GBA's own projection and comparing with the flat
  field: identical on 16 of 19 test views, a handful of pixels off on 3.
- Terrain: mountains counted in whole levels off the General tileset's
  pieces (tops, faces, bands, ends), votes taken greatest first and
  contradictions dropped, the rock settled into square pieces by least
  cost. Ledges as berms along their drawn lip. Rock a town or a cave draws
  in its own tiles as faces and tops.
- The cart first (Dramatic Shapes's order): buildings found from their
  doors, decks from the elevation byte, bridges by behaviour.
- Buildings: an upright facade up to an eave read off the drawing's
  colours, a roof rising from it at 22 degrees, ends dressed by height.
- Trees as crown cards leaning at 50 degrees, cut from the drawing; the
  ground under a crown shaded where the crown hides it. Signs, lamps and
  fences upright; north-south fences on a ridge. Trees in the border too.
- Actors as upright cards at their feet; the door animation on its facade.
- Flash darkness and weather over the 3D view.
- Maps aligned at their seams; the border goes on at the edge's height.
- Terrain counted in a background job and kept in mod.cache.
