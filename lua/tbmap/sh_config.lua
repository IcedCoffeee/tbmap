-- Shared configuration and material helpers.

TBMap = TBMap or {}

TBMap.Config = {
	-- The map file to load on startup, relative to SearchPath.
	StartupMap = "tbmap/test.map",
	-- "DATA" reads garrysmod/data/, "GAME" reads the game or addon folder.
	SearchPath = "DATA",
	-- Reload when the file changes on disk, so saving in TrenchBroom reloads the map.
	ReloadOnFileChange = true,

	-- Who may push a map to the server, by SteamID64. Empty means superadmins only.
	AllowedEditors = {},
	-- Refuse an upload larger than this, in KB.
	MaxUploadKB = 16384,

	-- How close two points must be, in world units, to count as one. Raising it welds geometry that
	-- should be separate; lowering it leaves hairline cracks.
	GeometryTolerance = 0.01,
	-- A face whose normal rises more steeply than this counts as a floor or ceiling; the rest are walls.
	FaceUpThreshold = 0.7,
	-- Build the same collision on the client so movement prediction matches the server.
	ClientSideCollision = true,
	-- Collision is one physics object per cube this many units across. Smaller cubes keep each object
	-- under 32 bit VPhysics's vertex cap, at the cost of more objects.
	CollisionChunkSize = 1024,
	-- The material the world's collision reports, for footstep and impact sounds.
	SurfaceProp = "concrete",

	-- The texture a face falls back to when its own name is not a material on this client, by the
	-- direction the face points. Each list is tried in order.
	FallbackMaterials = {
		floor   = { "gm_construct/construct_concrete_ground", "concrete/concretefloor012a" },
		wall    = { "plaster/plasterwall022c", "plaster/plasterwall017a", "concrete/concretewall014a" },
		ceiling = { "concrete/concreteceiling001a", "concrete/concretefloor012a" },
	},
	-- The checkerboard drawn when none of those resolve, coloured by the direction the face points.
	MissingTextureColor = {
		floor   = Color(120, 120, 130),
		ceiling = Color(90, 90, 100),
		wall    = Color(150, 150, 140),
	},
	-- Texel size assumed for that checkerboard; affects only how its UVs scale.
	MissingTextureSize = 64,

	-- What each tool texture does, by its lowered name:
	--
	--   sky        invisible and solid, light passes through
	--   clip       invisible and solid, light passes through
	--   nodraw     not drawn, solid, blocks light
	--   blocklight casts a shadow and nothing else: no collision
	--   ignore     triggers, hints, skips, portals: neither drawn nor solid
	--
	-- A brush is sky or clip only when every face of it is; anything else is drawn, with its tool faces
	-- dropped one at a time.
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

	-- Compile flags to look for in the material file, in priority order: the first that matches decides
	-- the kind. Order matters, because a converted sky ceiling is one sky face and the rest nodraw, and
	-- read as nodraw it seals the roof and leaves the map unlit.
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

	-- World units per lightmap texel. This is the resolution of all baked light: smaller gives sharper
	-- shadows and a heavier bake, and halving it quadruples the work.
	LightmapTexelSize = 16,
	-- Side of one lightmap sheet, in texels.
	AtlasSize = 1024,
	-- A map needing more sheets than this has its later faces drawn flat, with a warning.
	MaxAtlases = 8,
	-- Texels of gap around each face, so filtering cannot sample the face beside it.
	AtlasPadding = 1,
	-- Bake work per client frame, in milliseconds. Ten drops a 60 fps client to about 50 while a build
	-- runs.
	ClientBakeBudgetMs = 10,
	-- The server's bake takes a slice of each tick, sized to stay on time at this tick rate and bounded
	-- by these. At 48, a tick may take 20.8 ms before the bake gives budget back.
	MinServerTickRate = 48,
	MaxTickUsage = 0.8,
	MaxBakeSliceMs = 12,
	MinBakeSliceMs = 1,

	-- Turn either term off to see what the other contributes; a toggle re-bakes on the next reload.
	EnableSun = true,
	EnableContactShadows = true,
	-- The base light every surface starts from, as a fraction of white. A map with a light_environment
	-- overrides it with that entity's own ambient.
	AmbientLight = 0.35,
	-- Scale applied to the map's own _ambient before it becomes that base light.
	MapAmbientScale = 0.001,
	-- How far the contact darkening reaches from a surface join, in world units, and how dark it gets
	-- there. Narrow and strong reads as a hard line; wider and weaker as a shadow.
	CreaseWidth = 48,
	CreaseStrength = 0.2,
	-- How far in front of a surface a brush may be and still count as touching it. Keep small: a beam in
	-- mid air touches nothing.
	CreaseDepth = 2,

	-- Used when the map has no light_environment. Pitch is the sun's elevation: -60 is sixty degrees up.
	DefaultSunAngles = "-60 200 0",
	-- Colour and strength of that fallback sun.
	SunColor = "255 245 225",
	SunBrightness = 1.6,
	-- Scale applied to a map's own _light. A sun reaches the whole map with no falloff, so the same
	-- number lands far harder than a lamp's.
	SunLightScale = 0.002,
	-- Softness of the sun's shadow edge, in texels. Zero leaves it hard.
	ShadowSoftness = 2,
	-- How far a shadow ray reaches before giving up; longer than the map's diagonal.
	ShadowRayLength = 8192,
	-- Tolerance for classifying a whole face as lit or dark without tracing it: a hit closer than this
	-- does not count as covering the face.
	ShadowBias = 2,

	-- Falloff radius of a lamp that does not set its own, and the scale applied to its brightness so a
	-- Source light of a few hundred lands near 1.
	DefaultLightRadius = 512,
	PointLightScale = 0.005,
	-- Texels between lamp shadow samples, with the gap interpolated. Smaller is sharper and slower; 1
	-- samples every texel.
	LampSampleSpacing = 2,

	-- Trace shadows in Lua rather than through the engine. Much faster; off only to compare.
	UseFastTracer = true,
	-- Cells along the tracer grid's longest axis. The grid only traces rays now that box queries use the
	-- brush tree, and a ray crosses fewer cells the coarser it is, so this is coarse; past about half
	-- this the brushes per cell start to cost more than the cells saved.
	TracerGridSize = 64,
	-- How far off the surface a shadow ray starts. Too small and a corner sample starts inside the
	-- neighbouring brush, leaking light at joints.
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
