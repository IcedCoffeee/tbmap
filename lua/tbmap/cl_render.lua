-- Client: receive the streamed faces and their composed lighting, fill the atlas, draw them.
--
-- Appearance and light are two passes over the same geometry in one draw: the surface mesh with world
-- projected UVs and an unlit material, then a second mesh carrying the atlas with per face UVs,
-- multiplied over it. A see-through face cannot be multiplied that way, because the atlas has no alpha
-- to mask the multiply to the face and it would darken what shows through: it takes the lightmapped
-- shader instead, with the atlas bound as the lightmap and the vertex's second UV reading it, so the
-- surface's own alpha carries into the multiply.

local cfg = TBMap.Config
local World = TBMap.World or {}
TBMap.World = World

-- What the server last sent: the convexes and chunks the collision is built from, and the bounds the
-- render entities use. A rebuild replaces it outright, so nothing from the map before it is attached to
-- the one after.
function TBMap.ResetWorld()
	table.Empty(World)
end

-- The wire carries the orientation as an index into the list both realms share.
local ORIENTATIONS = TBMap.Wire.Orientations

-- IMesh hard caps at 65535 vertices, so batches are split. 20000 triangles is
-- 60000 vertices.
local MAX_TRIS_PER_MESH = 20000

local client = TBMap.Client or {}
TBMap.Client = client

local batches = client.batches or {}
local renderEnts = client.renderEnts or {}

client.batches = batches
client.renderEnts = renderEnts

-- Emptied in place: reassigning one leaves the reloaded file holding meshes the swap has already
-- destroyed, and destroying them twice reports as a NULL LuaMesh.
local function Clear(list)
	for i = #list, 1, -1 do list[i] = nil end
end

-- Where this build's batches start, so the previous build's can be disposed of after the swap.
local emittedFrom = 1
local sourceMaterials = {}

local atlasMaterials = {}
local checkerTargets = {}

-- Checkerboard used when no configured material resolves, so a missing texture is
-- still visible and its UV scale is obvious.
local function CheckerTexture(tag, orientation)
	local cached = checkerTargets[tag]
	if cached then return cached end

	-- Coloured by the direction the face points, which is all that is known about it.
	local colour = cfg.MissingTextureColor[orientation or "wall"] or Color(150, 150, 150)
	local size, cell = 64, 16
	local rt = GetRenderTarget("tbmap_checker_" .. tag, size, size)

	render.PushRenderTarget(rt)
	cam.Start2D()

	local ok, err = pcall(function()
		surface.SetDrawColor(colour.r, colour.g, colour.b, 255)
		surface.DrawRect(0, 0, size, size)

		surface.SetDrawColor(colour.r * 0.65, colour.g * 0.65, colour.b * 0.65, 255)
		for y = 0, size / cell - 1 do
			for x = 0, size / cell - 1 do
				if (x + y) % 2 == 0 then
					surface.DrawRect(x * cell, y * cell, cell, cell)
				end
			end
		end
	end)

	cam.End2D()
	render.PopRenderTarget()

	if not ok then
		print("[tbmap] could not draw the fallback checkerboard for " .. tag .. ": " .. tostring(err))
	end

	checkerTargets[tag] = rt
	return rt
end

-- A face's own texture name, or the configured list for the direction it points if this client does
-- not have that name.
local function ResolveSource(name, orientation)
	local mat = TBMap.TryMaterial(name)
	if mat then return mat, name end

	for _, candidate in ipairs(cfg.FallbackMaterials[orientation or "wall"] or {}) do
		local mat2 = TBMap.TryMaterial(candidate)
		if mat2 then return mat2, candidate end
	end

	return nil
end

-- The material a face draws with when its own name does not resolve here. shader is UnlitGeneric for the
-- two pass multiply and LightmappedGeneric for a see-through face, which reads the lightmap the vertex
-- carries; the name says which, since the two are different materials under one tag.
local function SourceMaterial(tag, source, orientation, kind, shader)
	shader = shader or "UnlitGeneric"

	-- Flattened, because a material name cannot carry a slash and the name is otherwise the face's own. The
	-- kind is in the name, so a material built under one set of flags is never handed back under another.
	local name = "tbmap_source_" .. tostring(tag):gsub("[^%w_]", "_") .. "_" .. tostring(kind or "opaque")
		.. "_" .. shader
	local cached = sourceMaterials[name]

	if cached then return cached end

	-- Both places, because each of the three has answered to one of them and not the other: $additive was
	-- only honoured in the definition, and $translucent only when set on the material afterwards.
	local flag = (kind == "alphatest" or kind == "translucent" or kind == "additive")
		and ("$" .. kind) or nil
	local flags = {}

	if flag then flags[flag] = 1 end

	local clone = CreateMaterial(name, shader, flags)

	local ok, tex = pcall(function() return source and source:GetTexture("$basetexture") end)
	clone:SetTexture("$basetexture", ok and tex or CheckerTexture(tag, orientation))

	if flag then
		pcall(function() clone:SetFloat(flag, 1) end)
	end

	sourceMaterials[name] = clone
	return clone
end

-- The material the light pass draws with, which is the atlas itself.
local function AtlasMaterial(atlas)
	local cached = atlasMaterials[atlas.index]
	if cached then return cached end

	-- Both the name and the texture object: the name is what a material normally carries and the
	-- object is what SetTexture takes.
	local okName, name = pcall(function() return atlas.rt:GetName() end)

	local clone = CreateMaterial(
		string.format("tbmap_atlas_mat_%s_%d", TBMap.Atlas.NameKey(), atlas.index),
		"UnlitGeneric", {
			["$basetexture"] = okName and name or ("tbmap_atlas_" .. atlas.index),
		})
	clone:SetTexture("$basetexture", atlas.rt)

	atlasMaterials[atlas.index] = clone
	return clone
end

-- Each cell is built on the entity the server made for it, matched by the index both realms bucket
-- by. Returns false only when an entity for a cell has not arrived yet. An empty group counts as done.
function TBMap.BuildPhysics(class, chunks, label)
	if not cfg.ClientSideCollision then return true end
	if not chunks or #chunks == 0 then return true end

	-- Indexed once, so a cell is found by its own key rather than by scanning every entity for every
	-- cell.
	local byIndex = {}

	for _, candidate in ipairs(ents.FindByClass(class)) do
		-- A live refresh can land between the server sending these entities and this file registering
		-- the class, and an entity that arrived before its class table did has none of the methods. It
		-- is skipped, and the retry pass picks the cell up.
		if IsValid(candidate) and candidate.GetChunkIndex then
			byIndex[candidate:GetChunkIndex()] = candidate
		end
	end

	local built, pending = 0, false

	for index = 1, #chunks do
		local convexes = chunks[index]
		local ent = byIndex[index]

		if not IsValid(ent) then
			pending = true
		elseif not ent.tbPhysicsBuilt or ent.tbConvexes ~= convexes
			or not IsValid(ent:GetPhysicsObject()) then
			if jit and jit.arch == "x86" then
				print("[tbmap] 32 bit client, skipping client collision. " ..
					"Building large physics objects crashes 32 bit clients.")
				return true
			end

			ent:SetSolid(SOLID_VPHYSICS)

			if ent:PhysicsInitMultiConvex(convexes, cfg.SurfaceProp) then
				ent.tbPhysicsBuilt = true
				ent.tbConvexes = convexes
				ent:EnableCustomCollisions(true)

				local phys = ent:GetPhysicsObject()
				if IsValid(phys) then
					phys:EnableMotion(false)
					phys:SetMass(50000)
				end

				built = built + 1
			else
				print(string.format("[tbmap] %s cell %d: client collision rejected %d convexes",
					label, index, #convexes))
			end
		end
	end

	if built > 0 then
		print(string.format("[tbmap] %s: client collision on %d cells", label, built))
	end

	return not pending
end

function TBMap.BuildClientPhysics()
	TBMap.Probe.Start("client.physics")
	local done = TBMap.BuildPhysics("tbmap_world", World.ConvexChunks, "world") and
		TBMap.BuildPhysics("tbmap_sky", World.SkyConvexChunks, "sky") and
		TBMap.BuildPhysics("tbmap_clip", World.ClipConvexChunks, "clip")
	TBMap.Probe.Stop("client.physics")

	return done
end

local placements = {}
local texelsBaked = 0

local lightBuffer, lightBlocks, lightFirstTag = nil, nil, nil
local lastBuildKey

-- By tag, so a face is matched to the block composed for it by name rather than by position.
local function ParseLightBlocks()
	lightBlocks = nil
	lightFirstTag = nil
	if not lightBuffer then return end

	local blocks, byTag = TBMap.LightDecodeBlocks(lightBuffer)

	if not blocks then
		print("[tbmap] the lighting from the server is not the format this client expects: reload both realms")
		return
	end

	lightBlocks = byTag
	lightFirstTag = blocks[1] and blocks[1].tag
end

local function LayoutFaces(decoded)
	local layout = {}
	local unplaced = {}

	-- Which brushes can bury a face, from the set the server decided rather than from material names read
	-- again here: a brush that hides nothing is not one, so a detail brush inside a glass pane is not inside
	-- anything, which is what a func_detail gets for being outside the world.
	local draws = {}

	for _, face in ipairs(decoded.faces) do
		local brush = face.brush or 0

		if not decoded.seeThrough[brush] then draws[brush] = true end
	end

	local cullStart = SysTime()
	local visible = TBMap.Bake.VisibleFaces(decoded.faces, draws, true)
	local cullDone = SysTime()
	local missing = 0

	print(string.format("[tbmap] %d of %d faces are inside another brush (%.0f ms)",
		#decoded.faces - #visible, #decoded.faces, (cullDone - cullStart) * 1000))

	local drawable = {}

	for _, face in ipairs(visible) do
		if not TBMap.ToolKind(decoded.materials[face.mat]) then
			drawable[#drawable + 1] = face
		end
	end

	visible = drawable

	for _, face in ipairs(visible) do
		TBMap.Bake.Slice()

		local tag = decoded.materials[face.mat] or "wall"
		local orientation = ORIENTATIONS[(face.ori or 1) + 1] or "wall"

		-- The rectangle belongs to the whole face the piece was cut from: one lightmap serves every piece
		-- of it, and the piece brings its corners' texel coordinates on that rectangle, which only become
		-- texture coordinates once the rectangle's place in the atlas is known.
		local source = decoded.collisionFaces[face.tbSourceIndex or 0]
		local key = (source and source.tbWireTag) or TBMap.Bake.FaceTag(face)
		local block = lightBlocks and lightBlocks[key]
		local uvs = face.tbUvs

		if block and uvs then
			local scale = 1 / cfg.AtlasSize
			local mapped = {}

			for i = 1, #uvs do
				mapped[i] = { (block.x + uvs[i][1]) * scale, (block.y + uvs[i][2]) * scale }
			end

			uvs = mapped
		else
			uvs = nil
		end

		-- The rectangle is the server's, so one planner decides where a lightmap lives and this side only
		-- fills what it is told. A face past the sheet cap has no rectangle and is drawn flat.
		local atlas = block and uvs and TBMap.Atlas.Target(block.sheet)

		if not atlas then
			if not block then
				if missing == 0 then
					print(string.format("[tbmap] no lighting for face %d: wanted tag %d, first record is %d",
						#layout + 1, key, lightFirstTag or -1))
				end

				missing = missing + 1
			end

			unplaced[#unplaced + 1] = { face = face, tag = tag, orientation = orientation }

			continue
		end

		table.insert(layout, {
			face = face,
			atlas = atlas,
			x = block.x,
			y = block.y,
			block = block,
			width = block.width,
			height = block.height,
			uvs = uvs,
			done = false,
			tag = tag,
			orientation = orientation,
		})
	end

	if lightBlocks and missing > 0 then
		print(string.format(
			"[tbmap] %d faces had no rectangle and are drawn unlit, which reads as light leaking", missing))
	end

	print(string.format("[tbmap] layout %.0f ms, of which culling %.0f ms; %d faces over %d sheets",
		(SysTime() - cullStart) * 1000, (cullDone - cullStart) * 1000, #layout, TBMap.Atlas.Count()))

	return layout, unplaced
end

-- Drawing into a render target takes effect only while the engine is rendering, so the colours are
-- computed here and drawn from the render hook below.
local drawQueue = {}
local drainAt = 1

-- Expands what arrived into the packed order the drain reads, once per face rather than per drawn
-- rectangle: a colour for every texel, from the blend or the bytes the server sent.
local function FinishFace(place)
	place.batch = place.batch or { atlas = place.atlas }
	place.colours = place.colours or {}

	local block = place.block
	local colours = place.colours
	local count = place.width * place.height
	local form = block.form or 2
	local texels = block.texels

	if form == 2 then
		local at = 1

		for i = 1, count do
			local r, g, b = string.byte(texels, at, at + 2)

			colours[i] = r * 65536 + g * 256 + b
			at = at + 3
		end
	elseif form == 1 or form == 3 then
		-- The blend of the two colours the server composed with, then the crease shade over it for form 3,
		-- which is the second plane. Same clamp and same rounding as the compose: TBMap.Bake.Colour is that
		-- rule.
		local mix = block.mix
		local ambR, ambG, ambB = mix[1], mix[2], mix[3]
		local sunR, sunG, sunB = mix[4], mix[5], mix[6]
		local shadeAt = form == 3 and count or 0

		for i = 1, count do
			local v = string.byte(texels, i) / 255
			local shade = shadeAt > 0 and (string.byte(texels, shadeAt + i) / 255) or 1

			colours[i] = TBMap.Bake.Colour((ambR + sunR * v) * shade, (ambG + sunG * v) * shade,
				(ambB + sunB * v) * shade)
		end
	else
		local packed = string.byte(texels, 1) * 65536 + string.byte(texels, 2) * 256
			+ string.byte(texels, 3)

		for i = 1, count do colours[i] = packed end
	end

	place.done = true
	texelsBaked = texelsBaked + count

	place.batch.place = place

	table.insert(drawQueue, place.batch)
	return true
end

local function DrainQueue()
	if drainAt > #drawQueue then return end

	local started = os.clock()
	local first = drainAt
	local deadline = SysTime() + cfg.ClientBakeBudgetMs / 1000

	TBMap.Probe.Start("client.drain")

	-- A slice of the queue per frame rather than all of it: a whole map's rectangles in one frame is most
	-- of a second, and the queue is hundreds of small batches rather than a few large ones.
	while drainAt <= #drawQueue do
		local batch = drawQueue[drainAt]
		drainAt = drainAt + 1

		-- Cleared here rather than at creation: a build happens at any time, including around a map
		-- load, and pushing a render target from outside a frame crashes the engine.
		if batch.atlas.dirty then
			batch.atlas.dirty = nil

			render.PushRenderTarget(batch.atlas.rt)
			render.Clear(0, 0, 0, 255)
			render.PopRenderTarget()
		end

		local place = batch.place

		render.PushRenderTarget(batch.atlas.rt)
		cam.Start2D()

		-- Contiguous runs of equal colour rather than one rectangle per texel, so this is one draw state
		-- change per run. A run never leaves its row, which is what makes the rectangle enough.
		local colours = place.colours
		local width, height = place.width, place.height
		local baseX, baseY = place.x, place.y
		local at = 0

		for row = 0, height - 1 do
			local y = baseY + row
			local col = 0

			while col < width do
				local packed = colours[at + col + 1]
				local run = 1

				while col + run < width and colours[at + col + run + 1] == packed do
					run = run + 1
				end

				surface.SetDrawColor(
					math.floor(packed / 65536),
					math.floor(packed / 256) % 256,
					packed % 256,
					255)
				surface.DrawRect(baseX + col, y, run, 1)

				TBMap.FillRuns = (TBMap.FillRuns or 0) + 1
				TBMap.FillRects = (TBMap.FillRects or 0) + run

				col = col + run
			end

			at = at + width
		end

		cam.End2D()
		render.PopRenderTarget()

		-- The fill is drawn, and these are the largest things a build allocates: a packed colour and a
		-- visibility per texel. Nothing reads them again, and holding them until the next build is what
		-- made the next decode pay to collect them while parsing.
		place.colours = nil
		place.sun = nil
		place.shade = nil
		place.blurTarget = nil

		if SysTime() > deadline then break end
	end

	TBMap.Probe.Stop("client.drain")
	TBMap.Probe.Worst("client.drain", os.clock() - started, (drainAt - first) .. " batches")

	TBMap.DrainClock = (TBMap.DrainClock or 0) + (os.clock() - started)

	if drainAt > #drawQueue then
		drawQueue = {}
		drainAt = 1
	end
end

hook.Add("PreDrawHUD", "tbmap_atlas_drain", DrainQueue)

-- Fast enough to run straight through, and no longer doing any of the lighting: expanding a rectangle
-- is all that is left of a build on this side. Sliced like the layout, since a whole map of rectangles
-- in one frame is a second of frozen client.
local function Bake(layout)
	for _, place in ipairs(layout) do
		if not place.done then
			-- One rectangle can serve several pieces, and expanding it and drawing it into the atlas is
			-- the costly half: the first piece to reach it does that, the rest only need it to exist so
			-- their meshes have something to sample.
			if place.block.baked then
				place.done = true
			else
				place.block.baked = true
				FinishFace(place)
			end
		end

		TBMap.Bake.Slice()
	end
end

local function EmitMeshes(layout, unplaced)
	emittedFrom = #batches + 1

	local byBatch = {}

	for _, place in ipairs(layout) do
		-- The kind is part of the key, so a see-through texture gets a batch and a material of its own
		-- rather than sharing one with opaque geometry of the same name.
		local kind = TBMap.AlphaKind(place.tag)
		local key = place.tag .. "|" .. tostring(place.atlas.index) .. "|" .. kind
		local entry = byBatch[key]
		if not entry then
			entry = { tag = place.tag, atlas = place.atlas, orientation = place.orientation,
				kind = kind, places = {} }
			byBatch[key] = entry
		end
		table.insert(entry.places, place)
	end

	-- No rectangle went with these, so they are drawn with the surface pass alone.
	for _, place in ipairs(unplaced or {}) do
		local key = place.tag .. "|flat"
		local entry = byBatch[key]

		if not entry then
			entry = { tag = place.tag, orientation = place.orientation, places = {} }
			byBatch[key] = entry
		end

		table.insert(entry.places, place)
	end

	local meshCount, triangleCount = 0, 0

	for _, entry in pairs(byBatch) do
		local list = entry.places
		local source, sourceName = ResolveSource(entry.tag, entry.orientation)
		local texW, texH = TBMap.TexSize(source)

		-- A placed see-through face takes the lightmapped path: the atlas is bound as the lightmap and the
		-- vertex's second UV reads it, so the multiply is modulated by the surface's own alpha and never
		-- reaches what shows through a translucent or cut out face. Opaque faces keep the two pass
		-- multiply, which needs no second UV channel.
		local lightmapped = entry.atlas ~= nil and entry.kind ~= "opaque"

		local batch = {
			tag = entry.tag,
			baseName = sourceName,
			kind = entry.kind or "opaque",
			lightmap = lightmapped and entry.atlas.rt or nil,
			surfaceMaterial = SourceMaterial(entry.tag, source, entry.orientation, entry.kind,
				lightmapped and "LightmappedGeneric" or nil),
			lightMaterial = (entry.atlas and not lightmapped) and AtlasMaterial(entry.atlas) or nil,
			pairs = {},
		}

		local groups, group, groupTris = {}, {}, 0

		for i = 1, #list do
			local tris = #list[i].face.poly - 2

			if groupTris + tris > MAX_TRIS_PER_MESH and #group > 0 then
				table.insert(groups, group)
				group, groupTris = {}, 0
			end

			table.insert(group, i)
			groupTris = groupTris + tris
		end

		if #group > 0 then table.insert(groups, group) end

		for _, members in ipairs(groups) do
			local tris = 0
			for _, i in ipairs(members) do tris = tris + (#list[i].face.poly - 2) end

			-- An error between Begin and End without End crashes the engine, so End always runs.
			local function Build(useAtlasUVs)
				-- The material is a hint for the vertex format: LightmappedGeneric reads the lightmap from
				-- the second UV, so the mesh has to be made knowing it carries one.
				local imesh = Mesh(lightmapped and batch.surfaceMaterial or nil)
				mesh.Begin(imesh, MATERIAL_TRIANGLES, tris)

				local ok, err = pcall(function()
					for _, i in ipairs(members) do
						local place = list[i]
						local face = place.face
						local poly, normal = face.poly, face.normal
						-- Reversed, so the outside faces are front facing.
						for k = 2, #poly - 1 do
							for _, corner in ipairs({ 1, k + 1, k }) do
								mesh.Position(poly[corner])

								if useAtlasUVs then
									mesh.TexCoord(0, place.uvs[corner][1], place.uvs[corner][2])
								else
									local u, v = TBMap.ComputeUV(face, poly[corner], texW, texH)
									mesh.TexCoord(0, u, v)
								end

								-- The atlas position is the lightmap coordinate on the lightmapped face,
								-- and unused on the two pass meshes.
								if lightmapped then
									mesh.TexCoord(1, place.uvs[corner][1], place.uvs[corner][2])
								else
									mesh.TexCoord(1, 0, 0)
								end
								mesh.Normal(normal)
								mesh.Color(255, 255, 255, 255)
								mesh.AdvanceVertex()
							end
						end
					end
				end)

				mesh.End()

				if ok then return imesh end

				print("[tbmap] mesh build error: " .. tostring(err))
				if imesh.Destroy then imesh:Destroy() end
				return nil
			end

			local surface = Build(false)
			local light = batch.lightMaterial and Build(true) or nil

			if surface and (light or not batch.lightMaterial) then
				table.insert(batch.pairs, { surface = surface, light = light })
				meshCount = meshCount + (light and 2 or 1)
				triangleCount = triangleCount + tris
			end
		end

		table.insert(batches, batch)
	end

	return meshCount, triangleCount
end

function TBMap.ClearClientMeshes(keepAtlas)
	for _, ent in ipairs(renderEnts) do
		if IsValid(ent) then ent:Remove() end
	end
	Clear(renderEnts)

	for _, batch in ipairs(batches) do
		for _, pair in ipairs(batch.pairs) do
			if pair.surface and pair.surface.Destroy then pair.surface:Destroy() end
			if pair.light and pair.light.Destroy then pair.light:Destroy() end
		end
	end
	Clear(batches)

	-- A build in flight would carry on filling rectangles that are no longer on screen, and the next
	-- stream arrives with a fresh one of its own.
	hook.Remove("Think", "tbmap_bake")
	hook.Remove("Think", "tbmap_client_world")
	drawQueue = {}
	drainAt = 1

	lastBuildKey = nil

	if not keepAtlas then TBMap.Atlas.Reset() end
end

-- One entity per group, drawing its surface and then its lighting. Both passes have to be in one draw:
-- as two entities the engine picks the order, and a multiply that runs first multiplies nothing.
local function CreateRenderEntity(batch)
	local ent = ents.CreateClientside("base_anim")
	if not IsValid(ent) then
		print("[tbmap] could not create a clientside render entity")
		return nil
	end

	-- Both, so the engine calls this entity in both passes. Which pass a batch is drawn in is decided by the
	-- guard in each hook, not by the group, and a group naming only one pass is a hook that never runs.
	ent.RenderGroup = RENDERGROUP_BOTH

	ent:SetModel("models/props_c17/FurnitureCouch002a.mdl")
	ent:DrawShadow(false)

	ent.tbBatch = batch

	local function DrawBatch(data)
		-- A see-through face carries its atlas as the lightmap the lightmapped material samples, so the
		-- surface's own alpha masks the multiply.
		if data.lightmap then render.SetLightmapTexture(data.lightmap) end

		for _, pair in ipairs(data.pairs) do
			render.SetMaterial(data.surfaceMaterial)
			pair.surface:Draw()

			if pair.light then
				-- Destination colour times source colour, which is a multiply: the atlas scales whatever the
				-- surface pass drew.
				render.OverrideBlend(true, BLEND_DST_COLOR, BLEND_ZERO, BLENDFUNC_ADD,
					BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)

				render.SetMaterial(data.lightMaterial)
				pair.light:Draw()

				render.OverrideBlend(false)
			end
		end
	end

	-- A blend or an additive writes no depth and is drawn in the translucent pass. Everything else, cutouts
	-- included, is drawn in the opaque pass, because a cutout writes depth like any other surface.
	local function LatePass(kind)
		return kind == "translucent" or kind == "additive"
	end

	ent.Draw = function(self)
		local data = self.tbBatch
		if not data or LatePass(data.kind) then return end

		DrawBatch(data)
	end

	ent.DrawTranslucent = function(self)
		local data = self.tbBatch
		if not data or not LatePass(data.kind) then return end

		DrawBatch(data)
	end

	ent:SetPos(vector_origin)
	ent:Spawn()
	ent:Activate()

	if World.BoundsMins and World.BoundsMaxs then
		ent:SetRenderBounds(World.BoundsMins, World.BoundsMaxs)
	end

	return ent
end

-- The new entities are created before the old ones are removed, so a rebuild does not blink the map.
function TBMap.ApplyRenderEntities()
	-- A copy: emptying this table in place would also empty the list of entities to remove.
	local previousEnts = {}

	for i = 1, #renderEnts do previousEnts[i] = renderEnts[i] end

	local firstNew = emittedFrom or 1

	Clear(renderEnts)

	for index = firstNew, #batches do
		local ent = CreateRenderEntity(batches[index])
		if ent then table.insert(renderEnts, ent) end
	end

	for _, ent in ipairs(previousEnts) do
		if IsValid(ent) then ent:Remove() end
	end

	for index = 1, firstNew - 1 do
		for _, pair in ipairs(batches[index].pairs) do
			if pair.surface and pair.surface.Destroy then pair.surface:Destroy() end
			if pair.light and pair.light.Destroy then pair.light:Destroy() end
		end
	end

	local kept = {}

	for index = firstNew, #batches do
		kept[#kept + 1] = batches[index]
	end

	Clear(batches)

	for index = 1, #kept do
		batches[index] = kept[index]
	end

	local valid = 0

	for _, ent in ipairs(renderEnts) do
		if IsValid(ent) then valid = valid + 1 end
	end

	print(string.format("[tbmap] %d render entities over %d batches, %d still valid",
		#renderEnts, #batches, valid))
end

function TBMap.FinishBuild(decoded, meshCount, triangleCount)
	local mins, maxs
	for _, face in ipairs(decoded.faces) do
		for _, v in ipairs(face.poly) do
			if not mins then
				mins, maxs = Vector(v.x, v.y, v.z), Vector(v.x, v.y, v.z)
			else
				mins = Vector(math.min(mins.x, v.x), math.min(mins.y, v.y), math.min(mins.z, v.z))
				maxs = Vector(math.max(maxs.x, v.x), math.max(maxs.y, v.y), math.max(maxs.z, v.z))
			end
		end
	end

	World.BoundsMins, World.BoundsMaxs = mins, maxs

	for _, ent in ipairs(ents.FindByClass("tbmap_world")) do
		if mins and maxs then ent:SetRenderBounds(mins, maxs) end
	end

	print(string.format("[tbmap] %d atlas targets, %d texels baked, %d meshes, %d triangles",
		TBMap.Atlas.Count(), texelsBaked, meshCount, triangleCount))
	print(string.format("[tbmap] client phases: atlas fills %.2f s over %d texels",
		TBMap.DrainClock or 0, texelsBaked))
	print(string.format("[tbmap] %d rectangles drawn for %d texels, %.1f texels per rectangle",
		TBMap.FillRuns or 0, TBMap.FillRects or 0,
		(TBMap.FillRuns or 0) > 0 and ((TBMap.FillRects or 0) / TBMap.FillRuns) or 0))
	print(string.format("[tbmap] bounds %s to %s", tostring(mins), tostring(maxs)))
	print("[tbmap] HDR enabled: " .. tostring(render.GetHDREnabled()))

	-- Watched across rebuilds: this should come back to the same number every time, and when it does, a
	-- rebuild that keeps getting slower is the engine holding the meshes and entities rather than Lua.
	print(string.format("[tbmap] client lua heap %.1f MB", collectgarbage("count") / 1024))

	TBMap.Probe.Report()

	TBMap.ApplyRenderEntities()
end

function TBMap.StartBuild(decoded)
	TBMap.DrainClock = 0
	TBMap.FillRects = 0
	TBMap.FillRuns = 0

	local started = SysTime()
	local lastReport = SysTime()
	local meshCount, triangleCount = 0, 0
	local unplaced

	local co = coroutine.create(function()
		placements, unplaced = LayoutFaces(decoded)
		texelsBaked = 0

		if #placements == 0 then
			print("[tbmap] nothing to bake")
			return
		end

		print(string.format("[tbmap] %d faces laid out at %s units per texel, %d atlas targets",
			#placements, tostring(cfg.LightmapTexelSize), TBMap.Atlas.Count()))

		for _, light in ipairs(decoded.lights or {}) do
			if light.kind == "sun" then
				local elevation = math.deg(math.asin(math.Clamp(light.dir.z, -1, 1)))
				print(string.format("[tbmap] sun direction (%.2f %.2f %.2f), elevation %.0f degrees",
					light.dir.x, light.dir.y, light.dir.z, elevation))
			end
		end

		Bake(placements)
	end)

	hook.Add("Think", "tbmap_bake", function()
		-- A flat window per frame rather than the server's AIMD: a client has no tick rate to keep. See
		-- ClientBakeSliceMs.
		TBMap.Bake.sliceDeadline = SysTime() + cfg.ClientBakeBudgetMs / 1000

		if coroutine.status(co) ~= "dead" then
			-- The status check before this cannot tell a finished coroutine from one that died.
			local resumeStart = os.clock()
			local ok, err = coroutine.resume(co)
			TBMap.Probe.Worst("client.slice", os.clock() - resumeStart, #drawQueue .. " queued")

			if not ok then
				hook.Remove("Think", "tbmap_bake")
				print("[tbmap] the bake stopped early: " .. tostring(err))
				return
			end

			if SysTime() - lastReport > 5 then
				lastReport = SysTime()
				print(string.format("[tbmap] baked %d texels, %d queued, %.0f s in",
					texelsBaked, #drawQueue, SysTime() - started))
			end
		end

		-- Everything is expanded, but the fill is still working through what the expansion queued.
		if coroutine.status(co) ~= "dead" or #drawQueue > 0 then return end

		hook.Remove("Think", "tbmap_bake")

		print(string.format("[tbmap] rectangles expanded in %.1f s", SysTime() - started))

		local meshStart = SysTime()
		meshCount, triangleCount = EmitMeshes(placements, unplaced)

		print(string.format("[tbmap] meshes and entities %.0f ms", (SysTime() - meshStart) * 1000))

		TBMap.FinishBuild(decoded, meshCount, triangleCount)
	end)
end

-- The payload and the lighting together describe everything on screen, and the key folds in every
-- setting that shapes a sample. The same pair arriving again means rebuilding would arrive at the same
-- picture.
function TBMap.BuildMeshes(payload, light)
	local key = TBMap.Bake.CacheKey(payload) .. "|" .. tostring(util.CRC(light or "")) ..
		"|" .. tostring(game.GetMap())

	if key == lastBuildKey then
		print("[tbmap] map and lighting unchanged, keeping what is on screen")
		return
	end

	lastBuildKey = key

	-- What the previous build decoded and laid out is not what is on screen: the batches carry their own
	-- meshes, and their colours were let go as they were filled. Releasing the rest here, before the
	-- decode allocates, keeps the client's longest single call from collecting the last build as it works,
	-- and the collect is done here rather than left to be spread through the decode's allocations.
	placements = {}
	lightBuffer, lightBlocks, lightFirstTag = nil, nil, nil
	texelsBaked = 0

	collectgarbage("collect")

	TBMap.Probe.Clear()

	-- The parse and the world build are split across frames like everything after them: a second of
	-- parsing in the frame the payload lands in is a freeze, and none of the work needs to finish before
	-- the frame does. The batches already on screen keep drawing throughout, since nothing here touches
	-- them until the swap at the end of a build.
	local co = coroutine.create(function()
		TBMap.Probe.Start("client.decode")
		local decoded = TBMap.WireDecode(payload)
		TBMap.Probe.Stop("client.decode")

		if not decoded then
			print("[tbmap] could not decode the streamed map")
			return nil
		end

		lightBuffer = (light and light ~= "") and light or nil
		TBMap.Probe.Start("client.lights")
		ParseLightBlocks()
		TBMap.Probe.Stop("client.lights")

		if lightBlocks then
			local records = 0
			for _ in pairs(lightBlocks) do records = records + 1 end

			print(string.format("[tbmap] lighting from the server: %.1f KB, %d records",
				#lightBuffer / 1024, records))
		end

		-- The meshes and entities are deliberately left alone here: the old ones stay until the new ones
		-- exist, so the map does not blink out while a rebuild runs. The world the collision and the
		-- tracer are built from is replaced outright, below.
		--
		-- The whole faces, not the drawn ones: the collision convexes and the tracer's planes are built
		-- from face geometry, and the drawn list has had the covered parts of every face cut out of it.
		-- Building from that would leave a wall standing on a floor without the plane of its underside.
		TBMap.ResetWorld()

		TBMap.Probe.Start("client.world")
		World.Convexes = TBMap.Brushes.Build(decoded.collisionFaces)
		World.SkyConvexes = decoded.skyConvexes or {}
		World.ClipConvexes = decoded.clipConvexes or {}

		-- The grid the server's tracer walks, built here as well: the cull below asks which brushes are
		-- near a face, and without a grid that answer is every brush on the map.
		TBMap.Trace.Build()

		-- Bucketed once here rather than per build: an entity is matched to a cell by the bucket's index,
		-- so the list has to be the same object every time it is asked for.
		local chunkSize = cfg.CollisionChunkSize

		World.ConvexChunks = TBMap.ChunkConvexes(World.Convexes, chunkSize)
		World.SkyConvexChunks = TBMap.ChunkConvexes(World.SkyConvexes, chunkSize)
		World.ClipConvexChunks = TBMap.ChunkConvexes(World.ClipConvexes, chunkSize)
		TBMap.Probe.Stop("client.world")

		TBMap.Bake.SetLights(decoded.lights or {})

		return decoded
	end)

	hook.Add("Think", "tbmap_client_world", function()
		TBMap.Bake.sliceDeadline = SysTime() + cfg.ClientBakeBudgetMs / 1000

		local ok, decoded = coroutine.resume(co)

		if not ok then
			hook.Remove("Think", "tbmap_client_world")
			print("[tbmap] the map build stopped early: " .. tostring(decoded))
			return
		end

		if coroutine.status(co) ~= "dead" then return end

		hook.Remove("Think", "tbmap_client_world")

		if not decoded then return end

		-- Collision has to exist before the bake, and the bake is deferred a frame so the physics
		-- environment has ticked before it is queried.
		local function Ready(attempts)
			if TBMap.BuildClientPhysics() or attempts >= 20 then
				timer.Simple(0, function() TBMap.StartBuild(decoded) end)
				return
			end

			timer.Simple(0.1, function() Ready(attempts + 1) end)
		end

		Ready(0)
	end)
end

TBMap.Stream.Receive("tbmap_stream", function(_, _, data)
	if not data or data == "" then return end

	local payload, light = TBMap.Wire.Unpack(data)

	if not payload then
		print("[tbmap] streamed map is not the format this client expects: reload after the server")
		return
	end

	TBMap.BuildMeshes(payload, light)
end)

-- A full update removes the collision entities on the client and re-creates them (the second argument
-- of GM:EntityRemoved marks one), and the physics built on them goes with them. OnEntityCreated cannot
-- put it back: it runs before the entity's class name is set, so a class filter can miss the entity
-- outright and the build would never run. NetworkEntityCreated runs once the entity has been received
-- whole, so its class and chunk index are there to match on. Every cell is rebuilt from the last
-- creation in a burst, since a build that finds a cell's entity not yet arrived leaves it for the next.
hook.Add("NetworkEntityCreated", "tbmap_client_physics", function(ent)
	local class = ent:GetClass()

	if class ~= "tbmap_world" and class ~= "tbmap_sky" and class ~= "tbmap_clip" then return end

	TBMap.BuildClientPhysics()
end)

concommand.Add("tbmap_clear", function()
	-- A deliberate clear means the atlas goes too, otherwise the next payload would keep
	-- rectangles belonging to nothing.
	TBMap.ClearClientMeshes(false)
	print("[tbmap] client meshes cleared")
end)
