-- Shared configuration and material helpers.

TBMap = TBMap or {}

TBMap.Config = {
	-- What to load, and where from.
	StartupMap = "tbmap/test.map",
	-- "DATA" reads garrysmod/data/, "GAME" reads the game or addon folder.
	SearchPath = "DATA",
	-- Reload when the file changes on disk, so saving in TrenchBroom is the whole loop.
	ReloadOnFileChange = true,

	-- Who may push a map to the server, by SteamID64. Empty means superadmins only.
	AllowedEditors = {},
	-- An upload larger than this is refused. netstream's own ceiling is 64 MB.
	MaxUploadKB = 16384,

	-- Geometry. A face steeper than FaceUpThreshold counts as a wall; flatter ones are floors or
	-- ceilings by the sign of their normal.
	GeometryTolerance = 0.01,
	FaceUpThreshold = 0.7,
	-- Matching collision on the client, so movement prediction lines up with the server.
	ClientSideCollision = true,
	-- Collision is built in cubes of this many units, one physics object each, rather than one object
	-- per realm: a map-wide object is where the solver and 32 bit clients fall over.
	CollisionChunkSize = 1024,
	SurfaceProp = "concrete",

	-- What to texture a face with when the name it carries is not a material on this client. Tried
	-- in order, by the direction the face points.
	FallbackMaterials = {
		floor   = { "gm_construct/construct_concrete_ground", "concrete/concretefloor012a" },
		wall    = { "plaster/plasterwall022c", "plaster/plasterwall017a", "concrete/concretewall014a" },
		ceiling = { "concrete/concreteceiling001a", "concrete/concretefloor012a" },
	},
	-- The checkerboard drawn when that fails too, coloured by the direction the face points.
	MissingTextureColor = {
		floor   = Color(120, 120, 130),
		ceiling = Color(90, 90, 100),
		wall    = Color(150, 150, 140),
	},
	-- Texel size assumed for that checkerboard. Affects UVs only.
	MissingTextureSize = 64,

	-- What each tool texture means to the loader, by its lowered name. A brush is a sky or a clip
	-- brush only when every face of it names one; anything else is drawn geometry with its tool
	-- faces dropped one at a time.
	--
	--   sky        invisible and solid, light passes through
	--   clip       invisible and solid, light passes through
	--   nodraw     not drawn, solid, blocks light
	--   blocklight casts a shadow and nothing else: no collision
	--   ignore     triggers, hints, skips, portals: neither drawn nor solid
	ToolTextures = {
		["tools/toolsskybox"] = "sky",
		["tools/toolsskybox2d"] = "sky",
		["tools/toolsclip"] = "clip",
		["tools/toolsplayerclip"] = "clip",
		["tools/toolsnpcclip"] = "clip",
		["tools/toolsinvisible"] = "clip",
		["tools/toolsinvisibleladder"] = "clip",
		["tools/invisimetal"] = "clip",
		["tools/toolsnodraw"] = "nodraw",
		["tools/toolsnodraw_roof"] = "nodraw",
		["tools/toolsnodraw_wood"] = "nodraw",
		["tools/toolsnodraw_metal"] = "nodraw",
		["tools/toolsnodraw_portal"] = "nodraw",
		["tools/toolsnodrawtriggers"] = "nodraw",
		["tools/toolsblocklight"] = "blocklight",
		["tools/toolstrigger"] = "ignore",
		["tools/toolsarea"] = "ignore",
		["tools/toolsareaportal"] = "ignore",
		["tools/toolshint"] = "ignore",
		["tools/toolsskip"] = "ignore",
		["tools/toolsoccluder"] = "ignore",
		["tools/toolsblock_los"] = "ignore",
		["tools/toolsfog"] = "ignore",
		["tools/toolsfogvolume"] = "ignore",
	},

	-- The material's own compile flags, in priority order. A brush carrying more than one takes
	-- the first of these, which is why sky comes before the rest: a converted sky ceiling is one
	-- toolsskybox face and the remainder toolsnodraw, and read as nodraw it seals the roof and the
	-- map goes unlit.
	CompileFlagKinds = {
		{ "%compilesky", "sky" },
		{ "%compile2dsky", "sky" },
		{ "%compileclip", "clip" },
		{ "%playerclip", "clip" },
		{ "%compilenpcclip", "clip" },
		{ "%compileinvisible", "clip" },
		{ "%compilepassbullets", "clip" },
		{ "%compileladder", "clip" },
		{ "%compileblocklight", "blocklight" },
		{ "%compilenonsolid", "blocklight" },
		{ "%compilenodraw", "nodraw" },
		{ "%compiletrigger", "ignore" },
		{ "%compilehint", "ignore" },
		{ "%compileskip", "ignore" },
		{ "%compileblocklos", "ignore" },
	},

	-- The bake. One rectangle per face in a shared atlas, at this many world units per texel. This
	-- is the resolution of everything: a shadow edge is as crisp as this, and halving it quadruples
	-- the work. Sixteen is roughly what Quake used.
	LightmapTexelSize = 16,
	AtlasSize = 1024,
	-- A map needing more than this has its later faces drawn flat, with a warning.
	MaxAtlases = 8,
	-- Texels of gap around each face, so filtering cannot reach the one beside it.
	AtlasPadding = 1,
	-- Milliseconds of bake work per client frame. Ten drops a sixty frame client to about fifty
	-- while a build runs.
	ClientBakeBudgetMs = 10,
	-- The server's bake sizes itself against this tick rate: a late tick halves its allowance and
	-- an on time one grows it, up to MaxBakeSliceMs or MaxTickUsage of the tick interval. At 48, a
	-- tick may take 20.8 ms before the bake gives budget back.
	MinServerTickRate = 48,
	MaxTickUsage = 0.8,
	MaxBakeSliceMs = 12,
	MinBakeSliceMs = 1,

	-- The lighting terms. Both switches zero their term everywhere, on both sides, for telling one
	-- artefact from another; both are in the cache key, so a toggle re-bakes on the next reload.
	EnableSun = true,
	EnableContactShadows = true,
	-- The base light every surface starts from, as a fraction of white. A map carrying a
	-- light_environment overrides it with that entity's own ambient.
	AmbientLight = 0.35,
	-- Converts a map's _ambient into that base. Source writes it at direct light strength, which
	-- would saturate a whole interior white.
	MapAmbientScale = 0.001,
	-- How far the darkening at a surface join reaches, in world units, and how dark it is at the
	-- join itself. The two are one look: a strong crease on a narrow width is a hard line, and the
	-- same strength spread wider is a shadow.
	CreaseWidth = 48,
	CreaseStrength = 0.2,
	-- How far in front of a surface a brush may sit and still count as touching it. Deliberately
	-- small: a ceiling or a beam in mid air is not resting on anything.
	CreaseDepth = 2,

	-- The sun. Its angles come from the map's light_environment when it has one, so these are only
	-- the fallback. Pitch is where the sun is, not where the light goes: -60 is sixty degrees up.
	DefaultSunAngles = "-60 200 0",
	SunColor = "255 245 225",
	SunBrightness = 1.6,
	-- Converts a map's own _light, and is separate from the point light scale because a sun reaches
	-- the whole map with no falloff, so the same number lands far harder.
	SunLightScale = 0.002,
	-- Softness of the shadow edge in texels, a box blur applied after tracing. Zero leaves it hard.
	ShadowSoftness = 2,
	-- How far a shadow ray reaches: long enough to leave the map and find sky.
	ShadowRayLength = 8192,
	-- How close the cover's centre ray may hit before the hit stops counting as proof the grid is not
	-- lit. The sample traces need no tolerance: each starts offset along its surface's normal and facing
	-- outward, so its own surface is behind it and nothing met has to be excused.
	ShadowBias = 2,

	-- Falloff radius for a lamp that does not specify one, and the scale that brings Source's
	-- hundreds-of-units brightness near 1.
	DefaultLightRadius = 512,
	PointLightScale = 0.005,
	-- Texels between lamp shadow samples, interpolated between. A lamp's pool is sharper than the sun's
	-- edge so this wants to stay small, and per texel tracing re-asks the same question across a whole
	-- face; at 1 it is a trace per texel and exact.
	LampSampleSpacing = 2,

	-- Tracing. Walks the brushes in Lua instead of asking the engine per ray, since the engine's
	-- cost is per call and the bake makes about two rays per texel. Set false to use the engine.
	UseFastTracer = true,
	-- Cells along the grid's longest axis. Coarser crosses fewer cells per ray and tests more
	-- brushes in each. The queries pay for the coarseness harder than the rays do: a face's query
	-- pulls in every brush within a cell of it, and a build on a map this size averages a hundred.
	TracerGridSize = 128,
	-- How far off the surface a sample starts. Too small and a trace at a corner begins inside the
	-- neighbouring brush, which leaks light through joints.
	TraceStartOffset = 1,

}

-- The kinds in priority order, derived from the flags above rather than written out a second time.
local ranks = {}
local ranked = 0

for _, entry in ipairs(TBMap.Config.CompileFlagKinds) do
	if not ranks[entry[2]] then
		ranked = ranked + 1
		ranks[entry[2]] = ranked
	end
end

TBMap.KindRank = ranks

-- What a face's texture name means: "sky", "clip", "blocklight", "nodraw", "ignore", or nil for an
-- ordinary texture. The compile flags in the material's file decide it, so a tool texture under any name
-- in any folder reads correctly; the table below is the fallback for a material with no file, and
-- anything else under tools/ is solid and not drawn.
local toolCache = {}

function TBMap.ToolKind(name)
	if not name or name == "" then return nil end

	local lower = string.lower(name)
	local cached = toolCache[lower]

	if cached ~= nil then return cached end

	local kind

	-- The material's file, because the compile flags are `%` keys in it and the shader's parameter table does
	-- not carry them: reading that is why only the stock names in the table below ever matched.
	local text = file.Read("materials/" .. lower .. ".vmt", "GAME")

	if text then
		text = string.lower(text)

		for i = 1, #TBMap.Config.CompileFlagKinds do
			local entry = TBMap.Config.CompileFlagKinds[i]

			if text:find(entry[1], 1, true) then
				kind = entry[2]
				break
			end
		end
	end

	if not kind then kind = TBMap.Config.ToolTextures[lower] end
	if not kind and lower:sub(1, 6) == "tools/" then kind = "nodraw" end

	toolCache[lower] = kind or false

	return kind
end

-- Whether a texture is see through, and how. "alphatest" is a cutout, which writes depth and sorts with
-- the opaque geometry; "translucent" and "additive" write no depth and are drawn after everything else.
-- All three mean the surface hides nothing, which is what the clip, the cull, the tracer and the contact
-- rule all ask about.
--
-- The material's file is the only thing that states it: these are material flags rather than shader
-- parameters, so the parameter table never carries them and no key or texture flag is readable from Lua.
local alphaCache = {}

function TBMap.AlphaKind(name)
	if not name or name == "" then return "opaque" end

	local lower = string.lower(name)
	local cached = alphaCache[lower]

	if cached then return cached end

	-- The material's file first, because it states this outright and does not need the texture to resolve.
	-- On a server it usually does not resolve, and reading that as opaque is what let a glass brush count as
	-- covering and cut the floor under it.
	local declared = file.Read("materials/" .. lower .. ".vmt", "GAME")

	if declared then
		local lines = {}

		for line in string.gmatch(string.lower(declared), "[^\r\n]+") do
			lines[#lines + 1] = string.gsub(line, "//.*$", "")
		end

		declared = table.concat(lines, "\n")

		local found

		if declared:find("%$additive\"?%s+[\"']?1") then
			found = "additive"
		elseif declared:find("%$translucent\"?%s+[\"']?1") then
			found = "translucent"
		elseif declared:find("%$alphatest\"?%s+[\"']?1") then
			found = "alphatest"
		end

		if found then
			alphaCache[lower] = found
			return found
		end
	end

	alphaCache[lower] = "opaque"
	return "opaque"
end

-- An IMaterial, but only if it resolved to a real texture.
function TBMap.TryMaterial(name)
	if not name or name == "" then return nil end

	local mat = Material(name)
	if not mat then return nil end

	local ok, tex = pcall(function() return mat:GetTexture("$basetexture") end)
	if not ok or not tex then return nil end

	local ok2, isError = pcall(function() return tex:IsErrorTexture() end)
	if ok2 and isError then return nil end

	return mat
end

-- Pixel dimensions of a material's base texture, which UVs are normalised against.
function TBMap.TexSize(mat)
	local w, h = TBMap.Config.MissingTextureSize, TBMap.Config.MissingTextureSize
	if not mat then return w, h end

	local ok, tex = pcall(function() return mat:GetTexture("$basetexture") end)
	if not ok or not tex then return w, h end

	local okW, iw = pcall(function() return tex:Width() end)
	local okH, ih = pcall(function() return tex:Height() end)
	if okW and iw and iw > 0 then w = iw end
	if okH and ih and ih > 0 then h = ih end

	return w, h
end
