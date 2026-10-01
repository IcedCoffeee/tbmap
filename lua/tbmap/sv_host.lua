-- Server: read the .map, build geometry, build collision, stream to clients.

local cfg = TBMap.Config
local World = TBMap.World or {}
TBMap.World = World

-- The host map the loaded world belongs to, on disk because a changelevel throws the whole Lua state
-- away, so nothing in memory survives it. The process boot time is stored beside the map to tell a
-- changelevel from a restart: wall clock minus engine uptime is constant for the life of a process and
-- jumps by the downtime across one, so a marker this process did not write is discarded and a fresh
-- server auto-loads nothing.
local AUTO_FILE = "tbmap/autoload.txt"

local function BootTime()
	return os.time() - SysTime()
end

local function WriteAutoMarker()
	file.CreateDir("tbmap")
	file.Write(AUTO_FILE, util.TableToJSON({ map = game.GetMap(), boot = BootTime() }))
end

local function ClearAutoMarker()
	file.Delete(AUTO_FILE)
end

local function AutoMarkerMatches()
	local text = file.Read(AUTO_FILE, "DATA")
	local marker = text and util.JSONToTable(text)

	if not marker or marker.map ~= game.GetMap() then return false end

	return math.abs((marker.boot or 0) - BootTime()) <= 2
end

-- Everything a loaded map is made of. Reset removes the entities of the world being replaced and
-- empties the table, so a reload ends up where a load does rather than leaving a world behind; the
-- table survives a code reload, which is what lets this find the previous world's entities.
function TBMap.ResetWorld()
	for _, ent in ipairs(World.Entities or {}) do
		if IsValid(ent) then ent:Remove() end
	end

	table.Empty(World)
	World.Entities = {}
end

if World.Payload and World.Payload ~= "" then
	timer.Simple(0, function() TBMap.Load() end)
end

local function OrientationFor(normal)
	if normal.z > cfg.FaceUpThreshold then return "floor" end
	if normal.z < -cfg.FaceUpThreshold then return "ceiling" end
	return "wall"
end

local LIGHT_KINDS = {
	light = "point",
	light_spot = "spot",
	light_environment = "sun",
}

-- Source writes "_light" as "R G B brightness" with the colour out of 255; Quake writes a brightness
-- in "light" and a colour in "_color".
local function ParseColourSpec(spec, props)
	if not spec then return nil end
	spec = tostring(spec)

	local r, g, b, brightness = spec:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$")
	if r then
		r, g, b, brightness = tonumber(r), tonumber(g), tonumber(b), tonumber(brightness)
		if not (r and g and b and brightness) then return nil end

		if r > 1 then r, g, b = r / 255, g / 255, b / 255 end
		return Vector(r, g, b), brightness
	end

	local value = tonumber(spec)
	if not value then return nil end

	local cr, cg, cb = 1, 1, 1
	local colour = props["_color"]
	if colour then
		local a, c, d = tostring(colour):match("^(%S+)%s+(%S+)%s+(%S+)$")
		cr, cg, cb = tonumber(a) or 1, tonumber(c) or 1, tonumber(d) or 1
	end

	return Vector(cr, cg, cb), value
end

local function ParseLightColour(props, kind)
	local colour, brightness = ParseColourSpec(props["_light"] or props["light"], props)
	if not colour then return nil end

	return colour, brightness * (kind == "sun" and cfg.SunLightScale or cfg.PointLightScale)
end

local function ParseAmbient(props)
	local colour, brightness = ParseColourSpec(props["_ambient"], props)
	if not colour then return nil end

	return colour * (brightness * cfg.MapAmbientScale)
end

local function ParseOrigin(props)
	local x, y, z = tostring(props.origin or ""):match("^(%S+)%s+(%S+)%s+(%S+)$")
	if not x then return nil end
	return Vector(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
end

local function ParseAngles(props)
	local spec = props.angles
	if spec then
		local p, y, r = tostring(spec):match("^(%S+)%s+(%S+)%s+(%S+)$")
		if p then return Angle(tonumber(p) or 0, tonumber(y) or 0, tonumber(r) or 0) end
		return Angle(0, tonumber(spec) or 0, 0)
	end

	local yaw = tonumber(props.angle)
	if yaw then return Angle(0, yaw, 0) end

	return nil
end

function TBMap.ParseLights(entities)
	local lights = {}

	for _, entity in ipairs(entities) do
		local props = entity.properties
		local kind = LIGHT_KINDS[props.classname or ""]

		if kind then
			local colour, brightness = ParseLightColour(props, kind)

			if colour then
				local angles = ParseAngles(props)
				local pitch = tonumber(props.pitch)

				-- The entity code writes pitch straight into the pitch of the entity's angles, leaving yaw
				-- and roll alone, so pitch is the elevation and yaw the bearing. Past vertical the usual
				-- angle to vector reflects the azimuth as well, so the elevation is folded into range.
				if kind == "sun" and (pitch or angles) then
					local elevation = math.abs(pitch or angles.pitch)

					if elevation > 90 then elevation = 180 - elevation end

					angles = Angle(-elevation, angles and angles.y or 0, angles and angles.roll or 0)
				end

				if kind == "sun" then
					print(string.format(
						"[tbmap] sun entity: angles %s, pitch %s, angle %s, light %s, ambient %s",
						tostring(props.angles or "-"), tostring(props.pitch or "-"),
						tostring(props.angle or "-"), tostring(props._light or "-"),
						tostring(props._ambient or "-")))
				end

				local dir
				if kind == "sun" then
					-- Pitch describes where the sun is, so Forward() points at it and must not be negated.
					if angles then dir = angles:Forward() end
				elseif kind == "spot" then
					dir = angles and angles:Forward() or Vector(0, 0, -1)
				end

				if kind ~= "sun" or dir then
					table.insert(lights, {
						kind = kind,
						ambient = kind == "sun" and ParseAmbient(props) or nil,
						pos = ParseOrigin(props) or Vector(0, 0, 0),
						dir = dir,
						color = colour,
						brightness = brightness or 1,
						radius = tonumber(props["_distance"]) or cfg.DefaultLightRadius,
						cosOuter = math.cos(math.rad(tonumber(props["_outer_cone"]) or 45)),
						cosInner = math.cos(math.rad(tonumber(props["_inner_cone"]) or 20)),
					})
				end
			end
		end
	end

	return lights
end

local function FallbackSun()
	local pitch, yaw, roll = tostring(cfg.DefaultSunAngles):match("^(%S+)%s+(%S+)%s+(%S+)$")

	-- The host map's own env_sun is not read: it keeps elevation in a pitch keyvalue rather than in its
	-- angles, so those read back as a horizontal sun.
	local dir = Angle(tonumber(pitch) or -60, tonumber(yaw) or 200, tonumber(roll) or 0):Forward()

	local r, g, b = tostring(cfg.SunColor):match("^(%S+)%s+(%S+)%s+(%S+)$")

	return {
		kind = "sun",
		pos = Vector(0, 0, 0),
		dir = dir,
		color = Vector((tonumber(r) or 255) / 255, (tonumber(g) or 255) / 255, (tonumber(b) or 255) / 255),
		brightness = cfg.SunBrightness,
		radius = 0,
		cosOuter = 0,
		cosInner = 1,
	}
end

function TBMap.EnsureSun(lights)
	for _, light in ipairs(lights) do
		if light.kind == "sun" then return lights end
	end

	table.insert(lights, FallbackSun())
	print("[tbmap] no light_environment in the map, using a fallback sun")

	return lights
end

-- Source and Quake spawn names both, since a converted map carries whichever its author used.
local SPAWN_CLASSES = {
	info_player_start = true,
	info_player_deathmatch = true,
	info_player_terrorist = true,
	info_player_counterterrorist = true,
	info_player_combine = true,
	info_player_rebel = true,
}

function TBMap.ParseSpawns(entities)
	local spawns = {}

	for _, entity in ipairs(entities) do
		if SPAWN_CLASSES[entity.properties.classname or ""] then
			local pos = ParseOrigin(entity.properties)
			local angles = ParseAngles(entity.properties)

			if pos then
				table.insert(spawns, { pos = pos, yaw = (angles and angles.y) or 0 })
			end
		end
	end

	return spawns
end

-- A real entity per point, because the spawn hook returns one and the engine reads its position and
-- angles. Flagged like the collision entities so game.CleanUpMap leaves it, and removed with the rest
-- of the world on the next load or unload.
function TBMap.CreateSpawns()
	for _, ent in ipairs(World.SpawnEntities or {}) do
		if IsValid(ent) then ent:Remove() end
	end

	World.SpawnEntities = {}

	for _, spawn in ipairs(World.Spawns or {}) do
		local ent = ents.Create("info_player_start")

		if IsValid(ent) then
			ent:AddEFlags(EFL_KEEP_ON_RECREATE_ENTITIES)
			ent:SetPos(spawn.pos)
			ent:SetAngles(Angle(0, spawn.yaw, 0))
			ent:Spawn()

			table.insert(World.SpawnEntities, ent)
			table.insert(World.Entities, ent)
		end
	end

	if #World.SpawnEntities > 0 then
		print(string.format("[tbmap] %d spawn points from the map", #World.SpawnEntities))
	end
end

-- The map's spawns replace the host map's. Nothing is returned on a transition, so a player arriving
-- through a changelevel keeps the position it put them at.
hook.Add("PlayerSelectSpawn", "tbmap_spawns", function(ply, transition)
	if transition then return end

	local list = World.SpawnEntities
	if not list or #list == 0 then return end

	return list[math.random(#list)]
end)

-- A brush is sky or clip only when every face of it names a tool texture; one real texture anywhere
-- and it is drawn geometry with its tool faces dropped one at a time.
--
-- A brush carrying more than one kind takes the highest priority one, and sky is first because a
-- converted sky ceiling is one tools/toolsskybox face and the rest tools/toolsnodraw, which read as
-- nodraw would make the slab opaque and the map go unlit. The order comes from the flag list.
local function BrushToolKind(brush)
	local kind

	for _, face in ipairs(brush.faces) do
		local tool = TBMap.ToolKind(face.texture)

		if not tool then return nil end

		if not kind or (TBMap.KindRank[tool] or math.huge) < (TBMap.KindRank[kind] or math.huge) then
			kind = tool
		end
	end

	return kind
end

local ORIENTATION_NUMBER = TBMap.Wire.OrientationNumber

-- Everything the map file alone says: the geometry the wire carries, the point sets the collision is
-- built from, and which brushes hide anything. One pass over the entities, and everything after this
-- works from what it returns.
local function ClassifyEntities(entities)
	local materials, materialIndex = {}, {}
	local convexes, faces = {}, {}
	local draws = {}

	local opaque = {}
	local allDrawn = {}
	local convexOfBrush = {}
	local seeThroughBrushes = {}
	local skyConvexes = {}
	local clipConvexes = {}
	local brushCount, skipped = 0, 0
	local skyBrushCount, clipBrushCount, ignoredCount = 0, 0, 0
	local nodrawCount, blocklightCount = 0, 0

	for _, entity in ipairs(entities) do
		for _, brush in ipairs(entity.brushes) do
			TBMap.Probe.Start("geometry.planes")
			local planes = TBMap.PlanesFromBrush(brush)
			TBMap.Probe.Stop("geometry.planes")

			TBMap.Probe.Start("geometry.hull")
			local hullStarted = os.clock()
			local geometry = TBMap.BuildBrush(planes)
			TBMap.Probe.Worst("geometry.hull", os.clock() - hullStarted, #planes .. " planes")
			TBMap.Probe.Stop("geometry.hull")

			if geometry then
				brushCount = brushCount + 1

				local brushIndex = brushCount

				TBMap.Probe.Start("geometry.solid")
				local solid = TBMap.IsSolid(geometry.vertices)
				TBMap.Probe.Stop("geometry.solid")

				local tool = BrushToolKind(brush)

				if tool == "ignore" then
					ignoredCount = ignoredCount + 1
				elseif tool == "sky" then
					skyBrushCount = skyBrushCount + 1
					if solid then table.insert(skyConvexes, geometry.vertices) end
				elseif tool == "clip" then
					clipBrushCount = clipBrushCount + 1
					if solid then table.insert(clipConvexes, geometry.vertices) end
				else
					-- All traced, since their faces go into the wire and the tracer rebuilds its hulls from
					-- those. Only blocklight has no collision: it casts a shadow and nothing else.
					if solid and tool ~= "blocklight" then
						table.insert(convexes, geometry.vertices)
						convexOfBrush[brushIndex] = #convexes
					end

					if tool == "blocklight" then
						blocklightCount = blocklightCount + 1
					elseif tool == "nodraw" then
						nodrawCount = nodrawCount + 1
					end

					-- Filled in after the faces: a brush only covers what is behind it when every one of its
					-- faces is opaque, so a window hides nothing and the geometry behind it survives the clip.
					draws[brushIndex] = false

					TBMap.Probe.Start("geometry.faces")

					local fullyDrawn = true
					local anyOpaque = false
					local seeThrough = false

					for _, face in ipairs(geometry.faces) do
						local source = face.face
						local orientation = OrientationFor(face.normal)

						local name = string.lower(source.texture or "")

						if name == "" or name == "__tb_empty" then name = orientation end

						local tag = name

						local material = materialIndex[tag]
						if not material then
							table.insert(materials, tag)
							material = #materials
							materialIndex[tag] = material
						end

						local uaxis, vaxis = source.uaxis, source.vaxis
						local uoffset, voffset = source.uoffset, source.voffset
						if not uaxis then
							uaxis, vaxis = TBMap.AxesFromNormal(face.normal, source.rotation)
							uoffset, voffset = source.offsetU or 0, source.offsetV or 0
						end

						-- Rounded, because two brushes sharing a surface compute their planes from different
						-- vertices.
						local tool = TBMap.ToolKind(name)
						local alpha = TBMap.AlphaKind(name)

						-- Three answers, not two. A tool face is not drawn, a see-through face is drawn but hides
						-- nothing, and only an opaque face does both.
						if not tool and alpha ~= "opaque" then
							seeThrough = true
							seeThroughBrushes[brushIndex] = true
						end

						if tool or alpha ~= "opaque" then
							fullyDrawn = false
						else
							anyOpaque = true

							local planes = opaque[brushIndex]

							if not planes then
								planes = {}
								opaque[brushIndex] = planes
							end

							planes[TBMap.PlaneKey(face.normal.x, face.normal.y, face.normal.z,
								face.normal:Dot(face.poly[1]))] = true
						end

						table.insert(faces, {
							mat = material,
							ori = ORIENTATION_NUMBER[orientation] or 1,
							brush = brushIndex,
							normal = face.normal,
							poly = face.poly,
							uaxis = uaxis,
							vaxis = vaxis,
							uoffset = uoffset,
							voffset = voffset,
							xscale = source.xscale or 1,
							yscale = source.yscale or 1,
						})
					end

					-- Covering needs one opaque face, because a wall with a nodraw back still hides what is behind
					-- it, and needs no see-through face anywhere, because glass hides nothing and cutting with its
					-- volume would take the surface behind it out of the map. The all over allowance needs every
					-- face opaque, since it claims a ray from anywhere crosses something drawn.
					if fullyDrawn then allDrawn[brushIndex] = true end

					draws[brushIndex] = (tool == nil) and anyOpaque and not seeThrough

					TBMap.Probe.Stop("geometry.faces")
				end
			else
				skipped = skipped + 1
			end
		end
	end

	return {
		materials = materials,
		faces = faces,
		convexes = convexes,
		skyConvexes = skyConvexes,
		clipConvexes = clipConvexes,
		convexOfBrush = convexOfBrush,
		seeThrough = seeThroughBrushes,
		opaque = opaque,
		allDrawn = allDrawn,
		draws = draws,
		brushCount = brushCount,
		skipped = skipped,
		skyBrushCount = skyBrushCount,
		clipBrushCount = clipBrushCount,
		ignoredCount = ignoredCount,
		nodrawCount = nodrawCount,
		blocklightCount = blocklightCount,
	}
end

-- The collision sets, the lights and the spawns.
local function BuildWorldCollision(geometry, entities)
	World.ConvexOfBrush = geometry.convexOfBrush

	TBMap.Probe.Start("prep.chunks")
	World.ConvexChunks, World.ConvexBuckets = TBMap.ChunkConvexes(geometry.convexes, cfg.CollisionChunkSize)
	World.SkyConvexChunks = TBMap.ChunkConvexes(geometry.skyConvexes, cfg.CollisionChunkSize)
	World.ClipConvexChunks = TBMap.ChunkConvexes(geometry.clipConvexes, cfg.CollisionChunkSize)
	TBMap.Probe.Stop("prep.chunks")

	TBMap.Probe.Start("prep.lights")
	World.Lights = TBMap.EnsureSun(TBMap.ParseLights(entities))
	World.Spawns = TBMap.ParseSpawns(entities)
	TBMap.Probe.Stop("prep.lights")
end

-- The brush list, the tracer's grid and the clip, ending in the faces that go on the wire. Returns how
-- many of them there are, and leaves them on the world.
local function BuildRenderFaces(geometry)
	local faces = geometry.faces

	if not faces[1] then return 0 end

	TBMap.Probe.Start("prep.brushes")
	TBMap.Brushes.Build(faces)

	-- On the brush records as well, so the contact rule can leave a see-through brush out of the shapes
	-- that press a crease into whatever it touches.
	for _, box in ipairs(TBMap.Brushes.list) do
		box.seeThrough = geometry.seeThrough[box.brush] == true
	end
	TBMap.Bake.SetLights(World.Lights)
	TBMap.Probe.Stop("prep.brushes")

	TBMap.Probe.Start("prep.trace")
	TBMap.Trace.Build()
	TBMap.Probe.Stop("prep.trace")

	TBMap.Probe.Start("prep.drawn")
	local drawn = {}
	local drawnCount = 0

	for _, face in ipairs(faces) do
		if not TBMap.ToolKind(geometry.materials[face.mat]) then
			drawnCount = drawnCount + 1
			drawn[drawnCount] = face
		end
	end
	TBMap.Probe.Stop("prep.drawn")

	print(string.format("[tbmap] %d of %d faces are drawn geometry, %d are tool faces",
		drawnCount, #faces, #faces - drawnCount))

	-- The clip cuts with the brushes in here and nothing else, so a zero means every face keeps the part
	-- another brush covers, which is what a hole in the map looks like from the inside.
	local coverCount = 0

	for _ in pairs(geometry.draws) do coverCount = coverCount + 1 end

	print(string.format("[tbmap] %d of %d brushes are opaque all over and can cover other faces",
		coverCount, geometry.brushCount))

	-- Numbered before the clip, which stamps every piece with the whole face it came from: the wire sends
	-- a piece as its polygon alone, and the reader completes it from that face.
	for index, face in ipairs(faces) do face.tbWhole = index end

	TBMap.Probe.Start("prep.clip")
	local renderFaces, cutFaces, cutPieces, droppedFaces =
		TBMap.Brushes.ClipFaces(drawn, geometry.draws, geometry.opaque, geometry.allDrawn)

	print(string.format(
		"[tbmap] clipping: %d faces cut into %d pieces, %d coincident faces dropped, %d to draw",
		cutFaces, cutPieces, droppedFaces, #renderFaces))

	-- Culled on the pieces, which is what the client culls: a whole face dropped here while one of its
	-- pieces survives, or kept here while the client drops the piece, leaves a face drawn with no
	-- rectangle, and an unlit face reads as light leaking in along whatever edge it borders.
	local visiblePieces = TBMap.Bake.VisibleFaces(renderFaces, geometry.draws)

	-- Which whole faces a lightmap is composed for: the ones that kept at least one piece that is drawn.
	-- A face under another brush has neither, and a rectangle for it is packed and sent for nothing.
	local baked, bakeFaces = {}, {}

	for _, piece in ipairs(visiblePieces) do
		local whole = piece.tbSource or piece.tbWhole

		if whole and not baked[whole] then
			baked[whole] = true
			bakeFaces[#bakeFaces + 1] = faces[whole]
		end
	end

	TBMap.Probe.Stop("prep.clip")

	World.RenderFaces = visiblePieces
	World.BakeFaces = bakeFaces
	World.Draws = geometry.draws

	return #visiblePieces
end

function TBMap.Build()
	local text = file.Read(cfg.StartupMap, cfg.SearchPath)
	if not text then
		print("[tbmap] could not read " .. tostring(cfg.StartupMap) ..
			" from " .. cfg.SearchPath .. ", see TBMap.Config")
		return nil
	end

	local started = SysTime()
	local afterRead = SysTime()

	TBMap.Probe.Clear()

	local entities, displaced = TBMap.ParseMap(text)
	local afterParse = SysTime()

	if displaced and displaced > 0 then
		print(string.format("[tbmap] %d displacement sides loaded as their flat base faces",
			displaced))
	end

	local geometry = ClassifyEntities(entities)
	local afterGeometry = SysTime()

	BuildWorldCollision(geometry, entities)

	local renderCount = BuildRenderFaces(geometry)
	local afterPrep = SysTime()

	TBMap.Probe.Start("encode")
	World.Payload = TBMap.WireEncode(geometry.materials, World.RenderFaces, geometry.faces, World.Lights,
		geometry.skyConvexes, geometry.clipConvexes, geometry.seeThrough)
	TBMap.Probe.Stop("encode")

	print(string.format(
		"[tbmap] %d brushes: %d sky, %d clip, %d nodraw, %d blocklight, %d ignored",
		geometry.brushCount, geometry.skyBrushCount, geometry.clipBrushCount, geometry.nodrawCount,
		geometry.blocklightCount, geometry.ignoredCount))

	-- The bearing is there to compare against the map's own yaw.
	for _, light in ipairs(World.Lights) do
		if light.kind == "sun" then
			local elevation = math.deg(math.asin(math.Clamp(light.dir.z, -1, 1)))
			local bearing = math.deg(math.atan2(light.dir.y, light.dir.x))

			print(string.format(
				"[tbmap] sun direction (%.2f %.2f %.2f), elevation %.0f degrees, bearing %.0f",
				light.dir.x, light.dir.y, light.dir.z, elevation, bearing))
		end
	end
	World.Faces = geometry.faces

	print(string.format(
		"[tbmap] %d brushes (%d skipped), %d faces to draw out of %d, %d lights, payload %.1f KB, built in %.0f ms",
		geometry.brushCount, geometry.skipped, renderCount, #geometry.faces, #World.Lights,
		#World.Payload / 1024, (SysTime() - started) * 1000))

	print(string.format(
		"[tbmap] build phases: read %.0f, parse %.0f, geometry %.0f, prep %.0f, encode %.0f ms; near %d calls, %d candidates",
		(afterRead - started) * 1000,
		(afterParse - afterRead) * 1000,
		(afterGeometry - afterParse) * 1000,
		(afterPrep - afterGeometry) * 1000,
		(SysTime() - afterPrep) * 1000,
		TBMap.NearCalls or 0, TBMap.NearCandidates or 0))

	TBMap.Probe.Report()

	return true
end

-- One entity per collision cell, each carrying the convexes of that cell. soup is the fallback if the
-- convex path is rejected, keyed the same way, and only the solid brushes have faces to build one from.
function TBMap.CreateCollision(chunks, class, label, soup)
	if not chunks or #chunks == 0 then return end

	local started = SysTime()
	local convexCount, rejected = 0, 0

	for index = 1, #chunks do
		local convexes = chunks[index]
		convexCount = convexCount + #convexes

		local ent = ents.Create(class)
		if not IsValid(ent) then
			print("[tbmap] could not create " .. class)
			return
		end

		ent:SetPos(vector_origin)
		ent:Spawn()
		ent:SetChunkIndex(index)

		ent:SetMoveType(MOVETYPE_NONE)
		ent:SetSolid(SOLID_VPHYSICS)

		if not ent:PhysicsInitMultiConvex(convexes, cfg.SurfaceProp) then
			rejected = rejected + 1
			print(string.format("[tbmap] %s cell %d: PhysicsInitMultiConvex rejected %d convexes",
				label, index, #convexes))

			if soup and soup[index] then
				ent:PhysicsFromMesh(soup[index], cfg.SurfaceProp)
			end
		end

		ent:EnableCustomCollisions(true)

		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableMotion(false)
			phys:SetMass(50000)
		end

		table.insert(World.Entities, ent)
	end

	print(string.format("[tbmap] %s: %d convexes over %d cells of %g units%s in %.0f ms",
		label, convexCount, #chunks, cfg.CollisionChunkSize,
		rejected > 0 and (", " .. rejected .. " rejected") or "", (SysTime() - started) * 1000))
end

-- Bakes the sun's visibility and sends it. Nothing is kept on disk between runs: the bake is served to
-- everyone at once, and what a record says about the geometry is in its key already.
function TBMap.BakeLighting()
	if not World.BakeFaces or not World.BakeFaces[1] then return end

	local started = SysTime()
	local hadOne = hook.GetTable().Think and hook.GetTable().Think.tbmap_light_bake
	if hadOne then hook.Remove("Think", "tbmap_light_bake") end

	local co = coroutine.create(function()
		local blocks = TBMap.Bake.ComposeBlocks(World.BakeFaces, cfg.LightmapTexelSize,
			math.max(cfg.AtlasPadding, 1), cfg.AtlasSize, World.RenderFaces)

		TBMap.Probe.Start("bake.encode")
		local buffer = TBMap.LightEncodeBlocks(blocks)
		TBMap.Probe.Stop("bake.encode")

		return buffer
	end)

	-- The build's own report has already run; these are the bake's phases.
	TBMap.Probe.Clear()

	hook.Add("Think", "tbmap_light_bake", function()
		TBMap.Bake.sliceDeadline = SysTime() + TBMap.Bake.NextSlice()

		local ok, buffer = coroutine.resume(co)

		if not ok then
			hook.Remove("Think", "tbmap_light_bake")
			print("[tbmap] server lighting bake failed: " .. tostring(buffer))
			return
		end

		if coroutine.status(co) ~= "dead" then return end

		hook.Remove("Think", "tbmap_light_bake")
		World.LightBuffer = buffer

		print(string.format(
			"[tbmap] composed and packed the lighting on the server in %.1f s, %.1f KB",
			SysTime() - started, #buffer / 1024))

		TBMap.Probe.Report()

		for _, ply in ipairs(player.GetAll()) do
			TBMap.SendPayload(ply)
		end
	end)
end

-- Runs the lighting bake over and over, unsliced and without sending anything, with a collection
-- between runs: a bench wants the work itself rather than the scheduling around it, and comparing two
-- versions in one session needs no changelevel.
concommand.Add("tbmap_bench", function(ply, _, args)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end

	if not World.BakeFaces or not World.BakeFaces[1] then
		print("[tbmap] nothing to bake")
		return
	end

	local runs = math.max(math.floor(tonumber(args[1]) or 1), 1)
	local bake = TBMap.Bake

	for run = 1, runs do
		collectgarbage("collect")
	TBMap.Probe.Clear()
	TBMap.NearCalls, TBMap.NearCandidates = 0, 0

		local co = coroutine.create(function()
			local blocks = bake.ComposeBlocks(World.BakeFaces, cfg.LightmapTexelSize,
				math.max(cfg.AtlasPadding, 1), cfg.AtlasSize, World.RenderFaces)

			TBMap.Probe.Start("bake.encode")
			local buffer = TBMap.LightEncodeBlocks(blocks)
			TBMap.Probe.Stop("bake.encode")

			return buffer
		end)

		-- Far enough that nothing yields: the whole bake in one resume.
		bake.sliceDeadline = math.huge

		local started = SysTime()
		local ok, err = coroutine.resume(co)

		if not ok or coroutine.status(co) ~= "dead" then
			print("[tbmap] bench failed: " .. tostring(err))
			return
		end

		print(string.format("[tbmap] bench run %d of %d: %.2f s", run, runs, SysTime() - started))
		TBMap.Probe.Report()
	end
end)

-- One stream, with the payload's length in a prefix: two streams have no ordering between them, and
-- the client would act on the map before the lighting arrived.
function TBMap.SendPayload(ply)	local payload = World.Payload

	if not payload or payload == "" then return end

	TBMap.Stream.Send("tbmap_stream", ply, nil, TBMap.Wire.Pack(payload, World.LightBuffer),
		function(who)
			print("[tbmap] " .. tostring(who) .. " finished downloading the map")
		end)
end

function TBMap.Load()
	TBMap.ResetWorld()

	if not TBMap.Build() then return end

	-- From here the world belongs to this host map, so a changelevel back into it auto-loads and a jump
	-- to any other does not.
	WriteAutoMarker()

	-- Keyed by cell, because a cell that falls back to a mesh would otherwise claim the whole map on
	-- its own.
	local soup = {}
	local buckets = World.ConvexBuckets or {}
	local convexOfBrush = World.ConvexOfBrush or {}

	for _, face in ipairs(World.Faces or {}) do
		local bucket = buckets[convexOfBrush[face.brush] or 0]

		if bucket then
			local list = soup[bucket]

			if not list then
				list = {}
				soup[bucket] = list
			end

			local poly = face.poly

			for k = 2, #poly - 1 do
				table.insert(list, { pos = poly[1] })
				table.insert(list, { pos = poly[k] })
				table.insert(list, { pos = poly[k + 1] })
			end
		end
	end

	TBMap.CreateCollision(World.ConvexChunks, "tbmap_world", "world", soup)
	TBMap.CreateCollision(World.SkyConvexChunks, "tbmap_sky", "sky", nil)
	TBMap.CreateCollision(World.ClipConvexChunks, "tbmap_clip", "clip", nil)
	TBMap.CreateSpawns()

	TBMap.BakeLighting()

	-- Only once the lighting exists, so a client rebuilds once rather than twice.
	if World.LightBuffer then
		for _, ply in ipairs(player.GetAll()) do
			TBMap.SendPayload(ply)
		end
	end
end

-- Auto-load only where the world already belongs to the host map being entered: a changelevel to a
-- different map clears the marker and loads nothing, and a marker written by another process (a
-- restart) is refused too, so after one the world is loaded on demand rather than restored.
hook.Add("InitPostEntity", "tbmap_load", function()
	if not AutoMarkerMatches() then
		ClearAutoMarker()
		return
	end

	TBMap.Load()
end)

local function FileStamp()
	return tostring(file.Time(cfg.StartupMap, cfg.SearchPath)) .. ":" ..
		tostring(file.Size(cfg.StartupMap, cfg.SearchPath))
end

local lastStamp
local forced

-- A rewrite of the same size inside the same second looks identical to the stamp.
function TBMap.NoticeFileChanged()
	forced = true
end

timer.Create("tbmap_watch", 1, 0, function()
	if not cfg.ReloadOnFileChange then return end

	local stamp = FileStamp()
	local previous = lastStamp
	lastStamp = stamp

	local changed = forced
	forced = false

	if not changed and (previous == nil or previous == stamp) then return end

	print("[tbmap] " .. cfg.StartupMap .. " changed on disk, reloading")

	timer.Simple(0.3, function() TBMap.Load() end)
end)

hook.Add("PlayerInitialSpawn", "tbmap_send_on_join", function(ply)
	timer.Simple(1, function()
		if not IsValid(ply) then return end

		-- While a bake is running the payload is held back: its completion sends to everyone.
		local thinking = hook.GetTable().Think and hook.GetTable().Think.tbmap_light_bake

		if World.LightBuffer or not thinking then
			TBMap.SendPayload(ply)
		end
	end)
end)

concommand.Add("tbmap_reload", function(ply, _, args)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end

	TBMap.Load()
end)

util.AddNetworkString("tbmap_unload")

-- Removes the world from the server and tells every client to drop what it drew of it, and stops it
-- following the host map: a later changelevel into this map will not bring it back.
concommand.Add("tbmap_unload", function(ply)
	if IsValid(ply) and not ply:IsSuperAdmin() then return end

	ClearAutoMarker()
	TBMap.ResetWorld()

	net.Start("tbmap_unload")
	net.Broadcast()

	print("[tbmap] unloaded")
end)
