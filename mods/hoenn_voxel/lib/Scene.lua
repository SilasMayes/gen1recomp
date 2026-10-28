-- What the builder reads, wired in one place: cells from the game, reliefs
-- and models from the analysis.  Each frame it also lets the readers catch
-- up with maps that came into view.
local lib = ...
local Source = lib("Source")
local Analysis = lib("Analysis")
local World = lib("World")
local Reader = lib("Reader")
local Models = lib("Models")

local Scene = {}

local function overLaid(ax, ay, c)
  local view = Source.atlas(c.pair)
  return view ~= nil and (view.coverage(c.mid) or 0) > 0
end

World.configure({
  cell = Source.cell,
  relief = Analysis.relief,
  atlas = Source.atlas,
  over = overLaid,
  version = Analysis.version,
  ground = Models.ground,
  stamp = function() return Analysis.stamp end,
  models = Models.build,
})

function Scene.frame(ctx, change)
  if change == "warp" then
    Analysis.forget()
    Reader.forget()
  end
  -- read every map that came into view
  Reader.update()
end

--- Whether the map the player is on has been read (before it is, the
-- pipeline lets the flat field show rather than a world without relief).
function Scene.ready(ctx)
  return ctx.mapId == nil or Reader.done(ctx.mapId)
end

return Scene
