-- The client's sheets. The server plans every rectangle and numbers the sheets; this side makes a
-- target per number it is told about and fills it with the texels it is sent.

local cfg = TBMap.Config

TBMap = TBMap or {}
TBMap.Atlas = TBMap.Atlas or {}

TBMap.Atlas.atlases = TBMap.Atlas.atlases or {}

local atlases = TBMap.Atlas.atlases

local function NewAtlas(index)
	local size = cfg.AtlasSize
	local rt = GetRenderTarget("tbmap_atlas_" .. index, size, size)

	local atlas = {
		rt = rt,
		index = index,
		-- Asks for the clear, which happens on the first draw, where the push is safe.
		dirty = true,
	}

	table.insert(atlases, atlas)
	return atlas
end

function TBMap.Atlas.Count()
	return #atlases
end

-- The sheet the server numbered, made if this client has not made it yet. The client fills what it is
-- told and never plans a layout of its own, so the sheet count on both sides comes from one planner.
function TBMap.Atlas.Target(index)
	index = math.max(math.floor(index or 1), 1)

	while #atlases < index do
		if #atlases >= cfg.MaxAtlases then return nil end

		NewAtlas(#atlases + 1)
	end

	return atlases[index]
end

-- Marks every sheet to be cleared on the next drain, which is what a rebuild means now that the server
-- plans the rectangles and this side only fills them.
function TBMap.Atlas.Reset()
	for _, atlas in ipairs(atlases) do
		atlas.dirty = true
	end
end

-- CreateMaterial returns an existing material for a name it has seen, so the name carries the map and
-- the load: a material from before this load is bound to a render target this load never made.
function TBMap.Atlas.NameKey()
	return (game.GetMap() or "map"):gsub("[^%w_]", "") .. "_" .. (TBMap.Bake.LoadID:gsub("[^%w]", ""))
end


