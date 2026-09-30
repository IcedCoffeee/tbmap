-- Lighting bake. Four terms: the base (the map's ambient or a flat value), the authored lights (each
-- shadow traced against the map's own collision), the sun, and the contact term, which is the distance
-- to any brush pressed against a surface and so is geometry rather than rays. All four are composed
-- here, on the server, and what a client receives is the finished rectangle.

TBMap = TBMap or {}
TBMap.Bake = TBMap.Bake or {}

local cfg = TBMap.Config
local Bake = TBMap.Bake

-- The lights live on Bake rather than in a local: a code reload empties locals while the map that needs
-- them persists, so everything derived from them is recomputed at load as well as on a set.
Bake.lights = Bake.lights or {}

local worldEnt

local function RefreshLights()
	Bake.mapAmbient = nil

	for _, entry in ipairs(Bake.lights) do
		if entry.kind == "sun" and entry.ambient then
			Bake.mapAmbient = entry.ambient
		end
	end
end

RefreshLights()

function Bake.SetLights(list)
	Bake.lights = list or {}

	RefreshLights()
end

-- Yields to whatever is driving a sliced build once this frame's share of work is spent. Nothing happens
-- on a call path with no coroutine behind it, like the server's own build, so the geometry code can call
-- this wherever it loops over a map without knowing who is driving it.
function Bake.Slice()
	if coroutine.running() and SysTime() > (Bake.sliceDeadline or 0) then
		coroutine.yield()
	end
end

function Bake.SunDirection()
	for _, entry in ipairs(Bake.lights) do
		if entry.kind == "sun" then return entry.dir end
	end

	return nil
end

local function WorldEntity()
	-- On a client the collision is built on one specific entity, and during a reload the old one is
	-- still present for a moment, so the first of the class is not always the one carrying it.
	if IsValid(worldEnt) and (not CLIENT or worldEnt.tbPhysicsBuilt) then return worldEnt end

	for _, ent in ipairs(ents.FindByClass("tbmap_world")) do
		if IsValid(ent) and ent.tbPhysicsBuilt then
			worldEnt = ent
			return worldEnt
		end
	end

	worldEnt = ents.FindByClass("tbmap_world")[1]
	return worldEnt
end

-- Whitelisted to the world entity, so the imported map casts shadows only on itself: the host map's
-- own ground would otherwise block every ray.
function Bake.TraceEngine(pos, dir, length)
	local world = WorldEntity()
	if not IsValid(world) then return false, false, 0 end

	local trace = util.TraceLine({
		start = pos,
		endpos = pos + dir * length,
		mask = MASK_SOLID,
		filter = { world, "tbmap_world" },
		whitelist = true,
	})

	if not trace.Hit then return false, false, 0 end

	return true, trace.StartSolid == true, (trace.HitPos - pos):Length()
end

-- One shadow ray along a direction already known to be a unit vector: the sun's direction is one vector
-- for the whole bake, and normalizing the target again every node is a square root and three divides.
local function ShadowRay(fx, fy, fz, dx, dy, dz, length)
	if cfg.UseFastTracer and TBMap.Trace then
		return TBMap.Trace.Ray(fx, fy, fz, dx, dy, dz, length)
	end

	return Bake.TraceEngine(Vector(fx, fy, fz), Vector(dx, dy, dz), length)
end

-- One shadow ray between two points: hit, started inside solid, and distance. The whole contract a
-- tracer has to satisfy, so swapping which one runs is this function and nothing else. Numbers rather
-- than Vectors, because this is called once per lamp per node and a Vector here is a heap allocation.
local function ShadowTrace(fx, fy, fz, tx, ty, tz)
	local dx, dy, dz = tx - fx, ty - fy, tz - fz
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if length <= 0 then return false, false, 0 end

	return ShadowRay(fx, fy, fz, dx / length, dy / length, dz / length, length)
end

-- The base every surface starts from, and the whole of the lighting for anything the sun cannot reach
-- that has no lamp on it. A map with a light_environment gets that entity's _ambient.
function Bake.Ambient()
	local mapped = Bake.mapAmbient

	if mapped then return mapped.x, mapped.y, mapped.z end

	local value = cfg.AmbientLight
	return value, value, value
end

local function SpotFactor(light, px, py, pz)
	if not light.dir then return 1 end

	local dx, dy, dz = px - light.pos.x, py - light.pos.y, pz - light.pos.z
	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if length <= 0 then return 0 end

	local cos = (light.dir.x * dx + light.dir.y * dy + light.dir.z * dz) / length
	if cos <= light.cosOuter then return 0 end
	if cos >= light.cosInner then return 1 end

	return (cos - light.cosOuter) / (light.cosInner - light.cosOuter)
end

-- The smooth half of a lamp's term at a point: falloff, the surface's angle to it and a spot's cone. The
-- visibility is traced on the node lattice and multiplied in by the caller, so this allocates nothing and
-- stays a handful of scalar operations in the innermost loop of the bake.
local function PointContribution(light, px, py, pz, nx, ny, nz)
	local dx, dy, dz = light.pos.x - px, light.pos.y - py, light.pos.z - pz
	local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
	if dist < 1 or dist > light.radius then return 0, 0, 0 end

	local ndl = (nx * dx + ny * dy + nz * dz) / dist
	if ndl <= 0 then return 0, 0, 0 end

	local att = 1 - dist / light.radius
	att = att * att

	local scale = light.brightness * att * ndl

	if light.kind == "spot" then
		local cone = SpotFactor(light, px, py, pz)
		if cone <= 0 then return 0, 0, 0 end

		scale = scale * cone
	end

	return light.color.x * scale, light.color.y * scale, light.color.z * scale
end



-- The sun's contribution for a face at full visibility, which the composition scales by the
-- visibility: the term is linear in it, so the per texel call reached the same answer.
function Bake.SunUnit(normal)
	local r, g, b = 0, 0, 0

	if cfg.EnableSun == false then return r, g, b end

	for _, entry in ipairs(Bake.lights) do
		if entry.kind == "sun" then
			local ndl = normal:Dot(entry.dir or Vector(0, 0, 1))

			if ndl > 0 then
				local scale = entry.brightness * ndl
				r = r + entry.color.x * scale
				g = g + entry.color.y * scale
				b = b + entry.color.z * scale
			end
		end
	end

	return r, g, b
end

-- The lamps that can reach a face's sampled rectangle, so the per texel loop walks a handful rather than
-- every lamp on the map. Both tests are conservative: the rectangle's box against the lamp's own reach,
-- and the plane test opened by the box's extent, so a lamp that could light any texel of it survives.
local function LampCandidates(s, normal)
	local list, count = {}, 0

	local u0, v0 = s.uStart, s.vStart
	local u1, v1 = s.uStart + s.width * s.unit, s.vStart + s.height * s.unit
	local ox, oy, oz = s.origin.x, s.origin.y, s.origin.z
	local t1x, t1y, t1z = s.t1.x, s.t1.y, s.t1.z
	local t2x, t2y, t2z = s.t2.x, s.t2.y, s.t2.z

	local minx, miny, minz = math.huge, math.huge, math.huge
	local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge

	for corner = 1, 4 do
		local u = (corner == 2 or corner == 3) and u1 or u0
		local v = (corner == 3 or corner == 4) and v1 or v0
		local px = ox + t1x * u + t2x * v
		local py = oy + t1y * u + t2y * v
		local pz = oz + t1z * u + t2z * v

		minx, miny, minz = math.min(minx, px), math.min(miny, py), math.min(minz, pz)
		maxx, maxy, maxz = math.max(maxx, px), math.max(maxy, py), math.max(maxz, pz)
	end

	local cx, cy, cz = (minx + maxx) * 0.5, (miny + maxy) * 0.5, (minz + maxz) * 0.5
	local half = (math.abs(normal.x) * (maxx - minx) + math.abs(normal.y) * (maxy - miny)
		+ math.abs(normal.z) * (maxz - minz)) * 0.5

	for _, entry in ipairs(Bake.lights) do
		if entry.kind ~= "sun" then
			local px = math.Clamp(entry.pos.x, minx, maxx)
			local py = math.Clamp(entry.pos.y, miny, maxy)
			local pz = math.Clamp(entry.pos.z, minz, maxz)
			local dx, dy, dz = entry.pos.x - px, entry.pos.y - py, entry.pos.z - pz

			if dx * dx + dy * dy + dz * dz < entry.radius * entry.radius then
				local facing = normal.x * (entry.pos.x - cx) + normal.y * (entry.pos.y - cy)
					+ normal.z * (entry.pos.z - cz)

				if facing > -half then
					count = count + 1
					list[count] = entry
				end
			end
		end
	end

	return list, count
end

-- The visibility of each candidate lamp, traced on the lamp node lattice and read back by interpolation:
-- a shadow edge is smooth enough that a trace per texel re-answers the same question thousands of times.
-- LampSampleSpacing = 1 puts a node on every texel and is exact.
local function TraceLampNodes(s, normal, lamps, count)
	local cols, rows, stride = s.lampCols, s.lampRows, s.lampStride
	local ox, oy, oz = s.origin.x, s.origin.y, s.origin.z
	local t1x, t1y, t1z = s.t1.x, s.t1.y, s.t1.z
	local t2x, t2y, t2z = s.t2.x, s.t2.y, s.t2.z
	local uStart, vStart, unit = s.uStart, s.vStart, s.unit
	local uMin, uMax, vMin, vMax = s.uMin, s.uMax, s.vMin, s.vMax
	local margin = s.margin
	local lastCol, lastRow = s.width - 1 - margin, s.height - 1 - margin
	local startX = normal.x * cfg.TraceStartOffset
	local startY = normal.y * cfg.TraceStartOffset
	local startZ = normal.z * cfg.TraceStartOffset
	local grids = {}

	-- The node position is worked out here rather than through a helper that builds a Vector: a node
	-- per lamp over a whole map is a heap allocation per node.
	for i = 1, count do
		local light = lamps[i]
		local pos = light.pos
		local reach = light.radius * light.radius
		local grid = {}

		for gy = 0, rows - 1 do
			local row = margin + gy * stride

			if row > lastRow then row = lastRow end

			local w = vStart + (row + 0.5) * unit

			if w < vMin then w = vMin elseif w > vMax then w = vMax end

			local base = gy * cols

			for gx = 0, cols - 1 do
				local col = margin + gx * stride

				if col > lastCol then col = lastCol end

				local u = uStart + (col + 0.5) * unit

				if u < uMin then u = uMin elseif u > uMax then u = uMax end

				local px = ox + t1x * u + t2x * w
				local py = oy + t1y * u + t2y * w
				local pz = oz + t1z * u + t2z * w
				local dx, dy, dz = px - pos.x, py - pos.y, pz - pos.z

				-- Past the lamp's own reach the falloff is zero, so this node cannot be lit by it and the
				-- trace is wasted: the zero written here is what the smooth term already multiplies to
				-- nothing. On a map with hundreds of lights, most of a face's lattice is out of reach of
				-- most of its candidates, and this is where that is paid.
				if dx * dx + dy * dy + dz * dz < reach then
					-- The node is offset along its surface normal, so its own surface is behind the ray
					-- and anything met is in front: a hit is the answer, at any distance.
					local hit = ShadowTrace(px + startX, py + startY, pz + startZ, pos.x, pos.y, pos.z)
					grid[base + gx + 1] = hit and 0 or 1
				else
					grid[base + gx + 1] = 0
				end
			end
		end

		grids[i] = grid
	end

	return grids
end

-- =========================================================================
-- Composing a face
-- =========================================================================

-- What a texel's colour becomes on the wire: one integer, clamped and floored here, so the compose and
-- the client's expansion of the same texel cannot round it two ways. The reader in cl_render is the
-- other half of this.
function Bake.Colour(r, g, b)
	if r < 0 then r = 0 elseif r > 1 then r = 1 end
	if g < 0 then g = 0 elseif g > 1 then g = 1 end
	if b < 0 then b = 0 elseif b > 1 then b = 1 end

	return math.floor(r * 255) * 65536 + math.floor(g * 255) * 256 + math.floor(b * 255)
end

-- That integer as the three bytes a form 0 or a form 2 texel is written with.
function Bake.ColourBytes(packed)
	return string.char(math.floor(packed / 65536) % 256, math.floor(packed / 256) % 256, packed % 256)
end

-- One face's rectangle, filled with the composed colour of every texel in row order, one packed RGB
-- each. Shared: the server composes and only sends the result, and a client that has to compose a
-- face itself for any reason does it with this same function rather than a second copy of the maths.
-- Returns false when it ran out of its slice, resuming from place.row next call.

local contactRow = {}
local contactRowDY = {}

function Bake.ComposeFace(place, sliceEnd)
	-- The blur first, over the whole grid: the rectangle and the ring the trace kept around it, so every
	-- texel that gets written has a full window and the margins carry the field as it is past the face.
	-- A face beside another then reads the same values at their join instead of repeating its own edge.
	if not place.blurred then
		local radius = math.max(cfg.ShadowSoftness, 0)
		local cols, rows = place.pcols, place.prows
		local source = place.sun

		if radius <= 0 then
			place.blurred = true
		else
			-- A square window over the grid, row by row: a separable pair of passes reads a column at a
			-- cols-sized stride, which misses cache every node, and measures slower than this does.
			-- On the face rather than in a local, because this yields part way through and a resumed row
			-- would otherwise find the earlier rows gone.
			local target = place.blurTarget or {}
			place.blurTarget = target

			while place.row < rows do
				local row = place.row

				for col = 0, cols - 1 do
					local sum, count = 0, 0
					local limL, limR, limU, limD = radius, radius, radius, radius

					-- A cell the drawn surface only partly covers is where it stops: the wall covering the
					-- rest is between these samples, however thin it is, and light does not blur across it
					-- through the surface the wall hides. Only nodes beside such a cell pay for the walk.
					local bu, bw = place.blockU, place.blockW

					if bu then
						local at = row * cols + col + 1
						local k = 1

						-- A pair with a covered cross section between it stops the window on that side;
						-- a pair with nothing between it, a join between two pieces included, carries on.
						while k <= radius and not bu[at - k] do k = k + 1 end
						limL = k - 1
						k = 1
						while k <= radius and not bu[at + k - 1] do k = k + 1 end
						limR = k - 1
						k = 1
						while k <= radius and not bw[at - k * cols] do k = k + 1 end
						limU = k - 1
						k = 1
						while k <= radius and not bw[at + (k - 1) * cols] do k = k + 1 end
						limD = k - 1
					end

					-- The window is always the full square: a tap past the reach is answered with the
					-- nearest sample inside it, so the kernel's weight does not step from texel to texel
					-- while what is beyond the wall still contributes nothing.
					for dy = -radius, radius do
						local cy = row + dy

						if dy < -limU then cy = row - limU elseif dy > limD then cy = row + limD end

						if cy >= 0 and cy < rows then
							for dx = -radius, radius do
								local cx = col + dx

								if dx < -limL then cx = col - limL elseif dx > limR then cx = col + limR end

								if cx >= 0 and cx < cols then
									sum = sum + source[cy * cols + cx + 1]
									count = count + 1
								end
							end
						end
					end

					target[row * cols + col + 1] = sum / count
				end

				place.row = row + 1
				if sliceEnd and SysTime() > sliceEnd then return false end
			end

			place.sun = target
			place.blurTarget = nil
			place.blurred = true
			place.row = 0
		end
	end

	local normal = place.face.normal
	local pcols = place.pcols
	local pad = place.pad
	local margin = place.margin
	local lastCol = place.width - 1 - margin
	local lastRow = place.height - 1 - margin

	-- Everything the inner loop reads, read once here instead: each was a field lookup on a table, per
	-- texel, and a face can be four hundred thousand of them.
	local colours = place.colours
	local sun = place.sun
	local ambR, ambG, ambB = Bake.Ambient()

	-- The contact term: a distance to the nearest of the cross sections the layout gathered, evaluated
	-- where the texel is and never interpolated. Per row it keeps only the shapes that can reach that
	-- row, so the cost per texel does not grow with how much geometry the face sits among.
	local contactList, contactCount = place.contact, place.contactCount or 0
	local contactWidth = math.max(cfg.CreaseWidth, 0)
	local contactStrength = cfg.CreaseStrength
	local contactOn = cfg.EnableContactShadows ~= false and contactWidth > 0
	local contactWide2 = contactWidth * contactWidth

	-- How far apart two junctions' darkenings can be while still blending into each other, in shade.
	-- Small: it only rounds the corner where they meet, it is not a second crease.
	local contactSmooth = 0.08

	local uStart, vStart, unit = place.uStart, place.vStart, place.unit
	local t1x, t1y, t1z = place.t1.x, place.t1.y, place.t1.z
	local t2x, t2y, t2z = place.t2.x, place.t2.y, place.t2.z
	local ox, oy, oz = place.origin.x, place.origin.y, place.origin.z
	local nx, ny, nz = normal.x, normal.y, normal.z
	local unitSunR, unitSunG, unitSunB = Bake.SunUnit(normal)
	local lampList = place.lampList
	local lampCount = place.lampCount or 0
	local lampVis = place.lampVis
	local lampCols, lampRows, lampStride = place.lampCols, place.lampRows, place.lampStride
	local shadeOut = place.shade

	while place.row < place.height do
		local row = place.row
		local r = math.min(math.max(row, margin), lastRow)

		-- The row's own position, unclamped: a margin row is past the face and its contact and sun
		-- values must be the ones there, which is what the neighbour across the join also reads.
		local w = vStart + (row + 0.5) * unit
		local activeCount = 0

		if contactOn then
			local at = 1

			for k = 1, contactCount do
				local dy = 0

				if w < contactList[at + 3] then dy = contactList[at + 3] - w
				elseif w > contactList[at + 4] then dy = w - contactList[at + 4] end

				if dy < contactWidth then
					activeCount = activeCount + 1
					contactRow[activeCount] = at
					contactRowDY[activeCount] = dy * dy
				end

				-- Past this shape to the next one: its count, its box's four numbers, its area, and three
				-- per vertex.
				at = at + contactList[at] * 3 + 6
			end
		end

		local n = row * place.width

		for col = 0, place.width - 1 do
			-- Clamped for the lamp lattice, which only has the face's own nodes; the position itself
			-- and the sun read use the texel's own.
			local c = math.min(math.max(col, margin), lastCol)

			local baseR, baseG, baseB = ambR, ambG, ambB
			local u = uStart + (col + 0.5) * unit

			local visibility = sun[(row + pad) * pcols + (col + pad) + 1]
			local sunR, sunG, sunB = unitSunR * visibility, unitSunG * visibility, unitSunB * visibility
			local lampR, lampG, lampB = 0, 0, 0

			-- Only for the lamps that can reach this face, and only where the node lattice says one is
			-- visible: the falloff is per texel, the occlusion is not.
			if lampCount > 0 then
				local px = ox + t1x * u + t2x * w
				local py = oy + t1y * u + t2y * w
				local pz = oz + t1z * u + t2z * w
				local nodeCol = c - margin
				local nodeRow = r - margin

				for i = 1, lampCount do
					-- The node lattice read back by interpolation, bilinear between the four nodes
					-- around the texel and clamped at the edges the nodes themselves are clamped to.
					-- Inline, since this is the innermost loop of the bake.
					local grid = lampVis[i]
					local gx, gy = nodeCol / lampStride, nodeRow / lampStride
					local x0, y0 = math.floor(gx), math.floor(gy)

					if x0 > lampCols - 1 then x0 = lampCols - 1 end
					if y0 > lampRows - 1 then y0 = lampRows - 1 end

					local x1 = x0 + 1 < lampCols and x0 + 1 or lampCols - 1
					local y1 = y0 + 1 < lampRows and y0 + 1 or lampRows - 1
					local fx, fy = gx - x0, gy - y0
					local top = grid[y0 * lampCols + x0 + 1] or 0
					local bottom = grid[y0 * lampCols + x1 + 1] or 0
					local nextTop = grid[y1 * lampCols + x0 + 1] or 0
					local nextBottom = grid[y1 * lampCols + x1 + 1] or 0
					local a = top + (bottom - top) * fx
					local b = nextTop + (nextBottom - nextTop) * fx
					local seen = a + (b - a) * fy

					if seen > 0 then
						local lr, lg, lb = PointContribution(lampList[i], px, py, pz, nx, ny, nz)

						lampR = lampR + lr * seen
						lampG = lampG + lg * seen
						lampB = lampB + lb * seen
					end
				end
			end

			-- A shade on the surface's own light: dark at the join, nothing at the width, and zero with
			-- nothing pressed against the surface. The junctions' darkenings combine by a smooth max of
			-- the two darkest: taking only the darkest kinks where two junctions are equidistant, and
			-- smoothing every pair in turn would add a little each time, which reads as a spot wherever
			-- several meet.
			local shade = 1

			if activeCount > 0 then
				local darkest, second = 0, 0

				for k = 1, activeCount do
					local at = contactRow[k]
					local dx = 0

					if u < contactList[at + 1] then dx = contactList[at + 1] - u
					elseif u > contactList[at + 2] then dx = u - contactList[at + 2] end

					if dx * dx + contactRowDY[k] < contactWide2 then
						local d, edgeScale = TBMap.Brushes.PolyDistance(contactList, at, u, w)

						if d < contactWidth then
							local t = 1 - d / contactWidth
							local darkening = contactStrength * edgeScale * t * t

							if darkening > darkest then
								second = darkest
								darkest = darkening
							elseif darkening > second then
								second = darkening
							end
						end
					end
				end

				local over = contactSmooth - (darkest - second)

				if over > 0 and second > 0 then
					darkest = darkest + over * over / (4 * contactSmooth)
				end

				shade = shade - darkest
			end

			-- Every term is scaled: a crease that only darkens the ambient half reads as a bright rim.
			local cr = (baseR + sunR + lampR) * shade
			local cg = (baseG + sunG + lampG) * shade
			local cb = (baseB + sunB + lampB) * shade

			n = n + 1

			if shadeOut then shadeOut[n] = shade end

			colours[n] = Bake.Colour(cr, cg, cb)
		end

		place.row = row + 1
		if sliceEnd and SysTime() > sliceEnd then return false end
	end

	place.done = true

	return true
end

-- =========================================================================
-- Packing
-- =========================================================================

-- The shelf walk that picks a rectangle for a face's lightmap, shared so that the server can plan the
-- layout and the client can only fill what it is told. atlasList is a list of sheets carrying shelfY,
-- shelfH, nextY and cursorX, whether they are render targets on a client or plain tables on a server.
-- Returns the sheet's index and the corner, or nil when none has room.
function Bake.PlaceRect(atlasList, width, height, size)
	for index = 1, #atlasList do
		local atlas = atlasList[index]

		if height <= atlas.shelfH and atlas.cursorX + width <= size then
			local x = atlas.cursorX
			atlas.cursorX = x + width

			return index, x, atlas.shelfY
		end

		if atlas.nextY + height <= size then
			atlas.shelfY = atlas.nextY
			atlas.shelfH = height
			atlas.nextY = atlas.shelfY + height
			atlas.cursorX = width

			return index, 0, atlas.shelfY
		end
	end

	return nil
end

-- =========================================================================
-- Composing the whole map
-- =========================================================================

-- Every face's rectangle composed and packed, ready to be laid out as bytes. The sun is traced here
-- into the node grid, the contact shapes are gathered here, and the colour maths is Bake.ComposeFace,
-- which is the same function a client runs. Sheets are numbers here: a server has nothing to draw them
-- into, and the client makes one per number it is told about.

-- Under this many nodes, proving a verdict by ray costs more than tracing the nodes themselves, and
-- most of a map's pieces are small.
local COVER_MIN_NODES = 128

-- A grid of a face's nodes for TBMap.Cover.Grid: the rectangle plus the ring, on the face's own frame,
-- unwound so the walk runs over every one of them rather than the face's inside.
local function CoverFrame(s, cols, rows)
	return {
		face = s.face,
		normal = s.normal,
		origin = s.origin,
		t1 = s.t1,
		t2 = s.t2,
		uStart = s.uStart,
		vStart = s.vStart,
		unit = s.unit,
		margin = 0,
		width = cols,
		height = rows,
	}
end

function Bake.ComposeBlocks(faces, unit, margin, size, pieces)
	-- Whatever the caller culled is what is baked: the cull runs on the drawn pieces, and culling whole
	-- faces again here could drop one that still has a piece drawn, leaving that piece with no rectangle
	-- and drawn unlit.
	local visible = faces
	local atlases = {}
	local blocks = {}
	local placed = 0
	local started = SysTime()

	Bake.texels = 0
	Bake.counts = { lit = 0, dark = 0, mixed = 0 }
	Bake.traced, Bake.filled, Bake.small, Bake.blurNodes = 0, 0, 0, 0
	TBMap.NearCalls, TBMap.NearCandidates = 0, 0

	local sunDir = Bake.SunDirection()

	if cfg.EnableSun == false then sunDir = nil end

	-- The rectangles are all known before any is placed, so the tallest faces can be packed first. A
	-- shelf is as tall as the tallest face on it, so placing tall faces first is what keeps a sheet from
	-- being mostly empty, which is where the sheet count was coming from.
	local plans = {}
	local boundsOf = {}

	-- The drawn pieces each whole face still has, keyed by the face: the bake list is a subset of the
	-- build's faces, so the pieces, which name theirs by the build's index, are matched through that.
	local wholeOf = {}

	for _, face in ipairs(faces) do
		if face.tbWhole then wholeOf[face.tbWhole] = face end
	end

	local piecesOf = {}

	for _, piece in ipairs(pieces or {}) do
		local whole = wholeOf[piece.tbSource or piece.tbWhole or 0]

		if whole then
			local list = piecesOf[whole]

			if not list then
				list = {}
				piecesOf[whole] = list
			end

			list[#list + 1] = piece
		end
	end

	-- Sliced: a second for the map, and it runs on a tick. Holding the server for seconds is worse for
	-- everyone on it than taking longer out of the time between ticks.
	for _, face in ipairs(visible) do
		TBMap.Probe.Start("bake.plan")
		local s = TBMap.Sample.Face(face, unit, margin, size)
		local n = s.normal
		local first = face.poly[1]
		local key = TBMap.PlaneKey(n.x, n.y, n.z, n.x * first.x + n.y * first.y + n.z * first.z)

		-- The cells of the lattice the face's own samples sit on, at the same spacing the ring below
		-- samples at: a plane's surface is the union of these over its faces, which is what tells the
		-- ring whether the plane carries on or the sample has run off it.
		local cu0 = math.floor((s.uStart + (margin + 0.5) * s.unit) / s.unit)
		local cu1 = math.floor((s.uStart + (s.width - margin - 0.5) * s.unit) / s.unit)
		local cw0 = math.floor((s.vStart + (margin + 0.5) * s.unit) / s.unit)
		local cw1 = math.floor((s.vStart + (s.height - margin - 0.5) * s.unit) / s.unit)
		local b = boundsOf[key]

		if b then
			if cu0 < b[1] then b[1] = cu0 end
			if cu1 > b[2] then b[2] = cu1 end
			if cw0 < b[3] then b[3] = cw0 end
			if cw1 > b[4] then b[4] = cw1 end
		else
			boundsOf[key] = { cu0, cu1, cw0, cw1 }
		end

		plans[#plans + 1] = { face = face, s = s, planeKey = key }
		TBMap.Probe.Stop("bake.plan")

		if SysTime() > (TBMap.Bake.sliceDeadline or 0) then coroutine.yield() end
	end

	table.sort(plans, function(a, b) return a.s.height > b.s.height end)

	local cellsOf = {}

	for key, b in pairs(boundsOf) do
		cellsOf[key] = { cu = b[1], cw = b[3], stride = b[2] - b[1] + 1, marks = {} }
	end

	for _, plan in ipairs(plans) do
		local s = plan.s
		local cells = cellsOf[plan.planeKey]
		local ox, oy, oz = s.origin.x, s.origin.y, s.origin.z
		local t1x, t1y, t1z = s.t1.x, s.t1.y, s.t1.z
		local t2x, t2y, t2z = s.t2.x, s.t2.y, s.t2.z
		local rows = s.height - 2 * margin

		TBMap.Probe.Start("bake.cells")

		-- The plane's surface where it is drawn, per row and per cell as the fraction of the cell the
		-- drawn pieces cover. A cell under a wall is covered by no piece, or partly by the pieces on
		-- either side of it, and either way it is where the surface stops: the blur below reads the
		-- fraction, so what a wall keeps out cannot cross it, however thin the wall is.
		local polys, polyCount = {}, 0

		for _, piece in ipairs(piecesOf[plan.face] or {}) do
			local piecePoly, pn = piece.poly, #piece.poly
			local qu, qw = {}, {}

			for i = 1, pn do
				local v = piecePoly[i]
				local dx, dy, dz = v.x - ox, v.y - oy, v.z - oz

				qu[i] = dx * t1x + dy * t1y + dz * t1z
				qw[i] = dx * t2x + dy * t2y + dz * t2z
			end

			polyCount = polyCount + 1
			polys[polyCount] = { u = qu, w = qw, n = pn }
		end

		-- Kept so the sun's off-surface snap can answer with the nearest point on the surface this face
		-- draws, rather than the nearest point on the whole face's plane.
		plan.pieces, plan.pieceCount = polys, polyCount

		local loOf, hiOf = {}, {}

		for r = 0, rows - 1 do
			local w = s.vStart + (r + margin + 0.5) * s.unit
			local spans = 0

			for p = 1, polyCount do
				local qu, qw, pn = polys[p].u, polys[p].w, polys[p].n
				local lo, hi = math.huge, -math.huge

				for i = 1, pn do
					local j = i % pn + 1
					local wi, wj = qw[i], qw[j]

					if (wi <= w) ~= (wj <= w) then
						local t = (w - wi) / (wj - wi)
						local u = qu[i] + (qu[j] - qu[i]) * t

						if u < lo then lo = u end
						if u > hi then hi = u end
					end
				end

				if lo <= hi then
					spans = spans + 1
					loOf[spans], hiOf[spans] = lo, hi
				end
			end

			-- Merged, because two pieces meeting at an angle cover their shared cells as one surface.
			for a = 1, spans do
				for b = a + 1, spans do
					if loOf[a] > loOf[b] then
						loOf[a], loOf[b] = loOf[b], loOf[a]
						hiOf[a], hiOf[b] = hiOf[b], hiOf[a]
					end
				end
			end

			local merged = 0

			for a = 1, spans do
				local lo, hi = loOf[a], hiOf[a]

				if merged > 0 and lo <= hiOf[merged] + 0.001 then
					if hi > hiOf[merged] then hiOf[merged] = hi end
				else
					merged = merged + 1
					loOf[merged], hiOf[merged] = lo, hi
				end
			end

			local base = (math.floor(w / s.unit) - cells.cw) * cells.stride

			for a = 1, merged do
				local lo, hi = loOf[a], hiOf[a]
				local c0 = math.floor(lo / s.unit) - cells.cu
				local c1 = math.floor(hi / s.unit) - cells.cu

				for c = c0, c1 do
					local left = (c + cells.cu) * s.unit
					local x = lo > left and lo or left
					local y = hi < left + s.unit and hi or (left + s.unit)
					local part = (y - x) / s.unit
					local at = base + c
					local had = cells.marks[at]

					if not had or part > had then cells.marks[at] = part end
				end
			end
		end

		TBMap.Probe.Stop("bake.cells")

		if SysTime() > (TBMap.Bake.sliceDeadline or 0) then coroutine.yield() end
	end

	for index, plan in ipairs(plans) do
		TBMap.Probe.Start("bake.face")
		local face = plan.face
		local s = plan.s
		local normal = s.normal

		-- The sun's grid is the rectangle plus a softness wide ring, traced on the plane's own lattice.
		-- The ring and the margins are real samples rather than a repeat of the face's edge, so a face
		-- beside another is a window onto the same field: read across their join, both sides see the
		-- same values and the seam a shadow edge cut into the border is not there.
		local pad = math.max(cfg.ShadowSoftness, 0)
		local pcols, prows = s.width + 2 * pad, s.height + 2 * pad
		local sun = {}
		local cover = "mixed"

		-- The sun's direction and the ray's constants, read once per face rather than per node, and the
		-- whole trace on numbers: a Vector here is a heap allocation and these nodes are the bake's
		-- innermost loop. Nothing reads them with the sun off, which is why they may stay zero.
		local nx, ny, nz = normal.x, normal.y, normal.z
		local sdx, sdy, sdz = 0, 0, 0
		local facing = 0

		if sunDir then
			sdx, sdy, sdz = sunDir.x, sunDir.y, sunDir.z
			facing = nx * sdx + ny * sdy + nz * sdz
		end

		local startOffset, rayLength = cfg.TraceStartOffset, cfg.ShadowRayLength
		local cells = cellsOf[plan.planeKey]
		local blockU, blockW

		-- The face's frame, read once: the trace and the snap both work in these two dimensions.
		local ox, oy, oz = s.origin.x, s.origin.y, s.origin.z
		local t1x, t1y, t1z = s.t1.x, s.t1.y, s.t1.z
		local t2x, t2y, t2z = s.t2.x, s.t2.y, s.t2.z
		local uStart, vStart, unit = s.uStart, s.vStart, s.unit
		local pieces, pieceCount = plan.pieces, plan.pieceCount or 0

		-- One shadow ray from a point on the plane, offset along the normal. On numbers rather than
		-- Vectors: this is the bake's innermost loop and a Vector here is a heap allocation.
		local function SunAt(su, sw)
			if facing <= 0 then return 0 end

			local fx = ox + t1x * su + t2x * sw + nx * startOffset
			local fy = oy + t1y * su + t2y * sw + ny * startOffset
			local fz = oz + t1z * su + t2z * sw + nz * startOffset
			local hit, solid = ShadowRay(fx, fy, fz, sdx, sdy, sdz, rayLength)

			-- The ray is offset along the normal and facing outward, so nothing it meets is this face's
			-- own surface: a hit is in front of it, at whatever distance, and occludes.
			if solid or hit then return 0 end

			return 1
		end

		-- The nearest point on the surface this face draws, the pieces rather than the whole face's
		-- plane: a node under a wall borders that wall, not the face's far edge, so the value it takes is
		-- the contact's own and not the lighting of somewhere else on the face.
		local function SnapToFace(u, w)
			local best, su, sw = math.huge, u, w

			for p = 1, pieceCount do
				local qu, qw, qn = pieces[p].u, pieces[p].w, pieces[p].n

				for i = 1, qn do
					local j = i % qn + 1
					local au, aw = qu[i], qw[i]
					local eu, ew = qu[j] - au, qw[j] - aw
					local l2 = eu * eu + ew * ew
					local t = 0

					if l2 > 0 then
						t = ((u - au) * eu + (w - aw) * ew) / l2

						if t < 0 then t = 0 elseif t > 1 then t = 1 end
					end

					local quu, qww = au + eu * t, aw + ew * t
					local du, dw = u - quu, w - qww
					local d2 = du * du + dw * dw

					if d2 < best then
						best, su, sw = d2, quu, qww
					end
				end
			end

			return su, sw
		end

		local function TraceSun(px0, px1, py0, py1)
			TBMap.Probe.Start("sun.trace")
			Bake.traced = Bake.traced + (px1 - px0 + 1) * (py1 - py0 + 1)

			for py = py0, py1 do
				local w = vStart + (py - pad + 0.5) * unit
				local cw = math.floor(w / unit) - cells.cw

				for px = px0, px1 do
					local u = uStart + (px - pad + 0.5) * unit
					local su, sw = u, w

					-- A sample off this plane's own surface has run off the end of the wall or around a
					-- corner, and what it would see there is the next plane over or the open sky. The
					-- face's nearest point is the answer, which is what keeps edges from rimming. The
					-- tracer reads leaving that surface as clear and entering it as a shadow, so a sample
					-- at a contact takes the value of the sun on that side rather than a bare dark.
					if (cells.marks[math.floor(u / unit) - cells.cu + cw * cells.stride] or 0) <= 0 then
						su, sw = SnapToFace(u, w)
					end

					sun[py * pcols + px + 1] = SunAt(su, sw)
				end
			end

			TBMap.Probe.Stop("sun.trace")
		end

		-- Decided without a ray where a brush's shadow cannot reach: lit at every node or dark at every
		-- node, asked of the padded grid so a verdict covers the margins and a face it holds for needs
		-- no ray at all. A face whose border a shadow edge reaches, or one too small for the proof to
		-- pay, is sampled node by node.
		local uniform = false

		if sunDir and pcols * prows > COVER_MIN_NODES then
			TBMap.Probe.Start("bake.cover")

			cover = TBMap.Cover.Grid(CoverFrame(s, pcols, prows), pcols, prows, 1,
				sunDir.x, sunDir.y, sunDir.z, cfg.ShadowBias)

			TBMap.Probe.Stop("bake.cover")
		end

		TBMap.Probe.Start("bake.sun")

		Bake.counts[cover] = Bake.counts[cover] + 1

		if (s.width - 2 * margin) * (s.height - 2 * margin) <= 4 then
			Bake.small = Bake.small + 1
		end

		if cover == "lit" or cover == "dark" then
			local value = cover == "lit" and 1 or 0

			TBMap.Probe.Start("sun.fill")
			Bake.filled = Bake.filled + pcols * prows

			for node = 1, pcols * prows do sun[node] = value end

			TBMap.Probe.Stop("sun.fill")

			uniform = true
		elseif sunDir then
			TraceSun(0, pcols - 1, 0, prows - 1)

			Bake.blurNodes = Bake.blurNodes + pcols * prows
		else
			-- No sun: every node is zero, one value, and nothing to blur.
			for node = 1, pcols * prows do sun[node] = 0 end

			uniform = true
		end

		TBMap.Probe.Stop("bake.sun")

		TBMap.Probe.Start("bake.contact")

		local contact, contactCount = TBMap.Brushes.ContactRects(face, face.normal,
			cfg.CreaseWidth, cfg.CreaseDepth)

		TBMap.Probe.Stop("bake.contact")

		-- Steps between neighbouring samples with a solid surface between them. The contact gather holds
		-- every solid brush crossing this face's plane, nodraw ones too, in the face's own coordinates:
		-- a step whose box meets one of theirs has that surface between its two samples, so the blur
		-- stops there rather than carrying what is on the far side across. The row keeps the shapes
		-- whose span covers it, so the test below is a handful of comparisons.
		if contactCount > 0 then
			local shapes = {}
			local list = contact

			blockU, blockW = {}, {}

			for py = 0, prows - 1 do
				local w = s.vStart + (py - pad + 0.5) * s.unit
				local base = py * pcols
				local found = 0
				local a = 1

				for k = 1, contactCount do
					if w >= list[a + 3] and w <= list[a + 4] then
						found = found + 1
						shapes[found] = a
					end

					a = a + math.floor(list[a] * 3 + 6)
				end

				for cx = 0, pcols - 1 do
					local u = s.uStart + (cx - pad + 0.5) * s.unit
					local at = base + cx + 1

					for k = 1, found do
						local a2 = shapes[k]
						local u0, u1 = list[a2 + 1], list[a2 + 2]

						if u <= u1 and u + s.unit >= u0 then
							blockU[at] = true
						end

						if u >= u0 and u <= u1 then
							blockW[at] = true
						end
					end
				end
			end
		end

		-- The lamps that can reach this rectangle, and their occlusion traced once per node rather than per
		-- texel. Both are per face, so a face no lamp reaches skips the per texel lamp loop entirely.
		TBMap.Probe.Start("bake.lamps")
		local lampList, lampCount = LampCandidates(s, normal)
		local lampVis = lampCount > 0 and TraceLampNodes(s, normal, lampList, lampCount) or nil
		TBMap.Probe.Stop("bake.lamps")

		-- A face with nothing pressed against it and no lamp in reach is the base plus the sun, which is one
		-- byte of visibility a texel with the two colours it blends, rather than three bytes of the result.
		-- Where the sun is uniform over it as well, the whole rectangle is one colour.
		local touched = contactCount > 0 or lampCount > 0

		local form = 2
		local mix

		-- Nothing pressed against the face and no lamp in reach is one byte a texel. Something pressed
		-- against it is two, the visibility and the crease shade that multiplies the same blend. Both are
		-- exact, and a brush map has a neighbour against most of its faces, so the second is the common
		-- case rather than the exception.
		if lampCount == 0 then
			if not touched then
				form = (cover == "mixed") and 1 or 0
			else
				form = 3
			end
		end

		if form == 1 or form == 3 then
			local ambR, ambG, ambB = Bake.Ambient()
			local sunR, sunG, sunB = Bake.SunUnit(normal)

			mix = { ambR, ambG, ambB, sunR, sunG, sunB }
		end

		local place = {
			face = face,
			pad = pad,
			pcols = pcols,
			prows = prows,
			width = s.width,
			height = s.height,
			unit = s.unit,
			margin = margin,
			t1 = s.t1,
			t2 = s.t2,
			origin = s.origin,
			uStart = s.uStart,
			vStart = s.vStart,
			contact = contact,
			contactCount = contactCount,
			sun = sun,
			-- Steps between neighbouring samples with a covered cross section between them, for the
			-- blur to stop at.
			blockU = blockU,
			blockW = blockW,
			-- The plane's cell coverage, for the ring clamp above.
			cells = cells,
			cellBase = math.floor(s.uStart / s.unit) - pad - cells.cu
				+ (math.floor(s.vStart / s.unit) - pad - cells.cw) * cells.stride,
			cellStride = cells.stride,
			-- A verdict grid is one value, so the blur is the identity and is skipped.
			blurred = uniform,
			lampList = lampList,
			lampCount = lampCount,
			lampVis = lampVis,
			lampCols = s.lampCols,
			lampRows = s.lampRows,
			lampStride = s.lampStride,
			row = 0,
			colours = {},
		}

		-- The shelf walk, which is the only planner either side has: the client fills the rectangle it is
		-- told about rather than choosing one.
		local sheet, x, y = Bake.PlaceRect(atlases, s.width, s.height, size)

		if not sheet then
			if #atlases >= cfg.MaxAtlases then
				print(string.format("[tbmap] atlas cap reached at %d faces, %d left out",
					placed, #visible - index + 1))
				break
			end

			atlases[#atlases + 1] = { shelfY = 0, shelfH = s.height, nextY = s.height, cursorX = s.width }
			sheet, x, y = #atlases, 0, 0
		end

		-- Only the two byte form needs the shade kept, and the compose writes it as it goes.
		if form == 3 then place.shade = {} end

		-- Driven to completion across slices, because a face the deadline lands in the middle of resumes from
		-- its own row counter rather than from the top. The probe wraps the call and not the yield, so it
		-- measures the compose rather than the frames it gave back.
		local finished = false

		while not finished do
			TBMap.Probe.Start("bake.compose")
			finished = Bake.ComposeFace(place, TBMap.Bake.sliceDeadline)
			TBMap.Probe.Stop("bake.compose")

			if not finished then coroutine.yield() end
		end

		TBMap.Probe.Start("bake.write")

		local texels

		if form == 0 then
			texels = Bake.ColourBytes(place.colours[1] or 0)
		elseif form == 1 or form == 3 then
			-- Every texel of the rectangle, margins included: the grid holds real values past the face
			-- on all four sides, so a neighbour's window onto the same field meets this one. The bytes
			-- are gathered and string.char called per chunk rather than per texel, since this is a
			-- million texels and a million small strings.
			local parts = {}
			local bytes = {}
			local used = 0
			local grid = place.sun
			local stride = place.pcols

			for row = 0, s.height - 1 do
				local base = (row + pad) * stride + pad

				for col = 0, s.width - 1 do
					local value = grid[base + col + 1] or 0

					used = used + 1
					bytes[used] = math.floor(math.Clamp(value, 0, 1) * 255 + 0.5)

					if used == 128 then
						parts[#parts + 1] = string.char(unpack(bytes))
						used = 0
					end
				end
			end

			-- The crease shade follows as a second plane, multiplied over the same blend by the reader.
			if form == 3 then
				local shade = place.shade

				for i = 1, s.width * s.height do
					used = used + 1
					bytes[used] = math.floor(math.Clamp(shade[i] or 1, 0, 1) * 255 + 0.5)

					if used == 128 then
						parts[#parts + 1] = string.char(unpack(bytes))
						used = 0
					end
				end
			end

			if used > 0 then parts[#parts + 1] = string.char(unpack(bytes, 1, used)) end

			texels = table.concat(parts)
		else
			local parts = {}
			local bytes = {}
			local used = 0

			for i = 1, s.width * s.height do
				local packed = place.colours[i] or 0

				used = used + 1
				bytes[used] = math.floor(packed / 65536) % 256
				used = used + 1
				bytes[used] = math.floor(packed / 256) % 256
				used = used + 1
				bytes[used] = packed % 256

				if used >= 126 then
					parts[#parts + 1] = string.char(unpack(bytes, 1, used))
					used = 0
				end
			end

			if used > 0 then parts[#parts + 1] = string.char(unpack(bytes, 1, used)) end

			texels = table.concat(parts)
		end

		TBMap.Probe.Stop("bake.write")

		placed = placed + 1
		Bake.texels = Bake.texels + s.width * s.height

		blocks[placed] = {
			tag = Bake.FaceTag(face),
			sheet = sheet,
			x = x,
			y = y,
			width = s.width,
			height = s.height,
			-- No corners of the face's own: the wire gives every piece its corners on this rectangle, so
			-- nothing on this side reads them and they would be bytes per face for nothing.
			uvs = {},
			form = form,
			mix = mix,
			texels = texels,
		}

		if index % 500 == 0 then
			print(string.format("[tbmap] composing: %d of %d faces, %d sheets, %.0f s in",
				index, #visible, #atlases, SysTime() - started))
		end

		TBMap.Probe.Stop("bake.face")

		-- Between faces, so a tick is never held for longer than one face's own texels: a fraction of a
		-- millisecond on an ordinary face, tens on a very large one.
		if SysTime() > (TBMap.Bake.sliceDeadline or 0) then coroutine.yield() end
	end

	print(string.format("[tbmap] composed %d of %d faces over %d sheets in %.1f s (%d texels)",
		placed, #visible, #atlases, SysTime() - started, Bake.texels))

	print(string.format(
		"[tbmap] sun: %d lit, %d dark, %d mixed, %d of 4 texels or less; %d nodes traced, %d filled, %d blurred; near %d calls, %d candidates",
		Bake.counts.lit, Bake.counts.dark, Bake.counts.mixed, Bake.small, Bake.traced, Bake.filled,
		Bake.blurNodes, TBMap.NearCalls or 0, TBMap.NearCandidates or 0))

	return blocks, #atlases
end

-- =========================================================================
-- Faces, tags and the settings key
-- =========================================================================

-- Changes every load and folds into the settings key, so a code reload that changes a formula
-- invalidates what the client is holding. A formula change alters no setting on its own. It also names
-- the client's atlas materials, with the same reasoning: a material made before this load outlives it.
Bake.LoadID = tostring(os.time()) .. ":" .. tostring(math.floor(os.clock() * 100000))

-- Built from the brush and the outward normal, the two things that survive being sent. The plane
-- offset is needed as well: two faces of one brush can be nearly parallel without being coplanar, and
-- rounding the normal alone collapses their keys into one.
function Bake.FaceKey(face)
	if face.tbKey then return face.tbKey end

	local n = face.normal

	local d = n:Dot(face.poly[1])

	-- The piece number, because the clip turns one face into several that share every other field.
	face.tbKey = string.format("%d|%.1f,%.1f,%.1f|%.1f|%d",
		face.brush or 0, n.x, n.y, n.z, d, face.tbPiece or 0)

	return face.tbKey
end

function Bake.FaceTag(face)
	-- A tag from the wire is the server's own answer, used as it stands.
	if face.tbWireTag then return face.tbWireTag end

	if not face.tbTag then
		-- Unsigned: util.CRC is signed on some builds, and a negative tag packed as four bytes reads back
		-- as its unsigned twin, so every lookup would miss.
		face.tbTag = util.CRC(Bake.FaceKey(face)) % 4294967296
	end

	return face.tbTag
end

-- Not required to match on both sides: a face within a hair of the buried test's slack can be culled
-- on one and kept on the other, and the buffer is self describing, so that costs one face.
function Bake.VisibleFaces(faces, draws, yieldable)
	local visible = {}

	for _, face in ipairs(faces) do
		if yieldable then Bake.Slice() end

		local fmin, fmax = TBMap.PolyBox(face.poly)

		-- The bounds are kept either way, because the contact rule's broad phase asks again.
		if not TBMap.Brushes.Buried(face.poly, fmin, fmax, face.brush or 0, draws) then
			face.tbMins, face.tbMaxs = fmin, fmax
			table.insert(visible, face)
		end
	end

	return visible
end

-- Everything that changes what a sample comes out as, apart from the geometry: every setting that is
-- a plain value, so one added later is in the key without anyone remembering to put it there. The
-- tables are left out, because changing those changes the payload this key already covers, or
-- changes only what is drawn with it.
local function SettingsString()
	-- The live table rather than this file's own local, which is captured at load.
	local c = TBMap.Config
	local keys = {}

	for key, value in pairs(c) do
		if type(value) ~= "table" then keys[#keys + 1] = key end
	end

	table.sort(keys)

	local parts = { Bake.LoadID }

	for _, key in ipairs(keys) do
		parts[#parts + 1] = key .. "=" .. tostring(c[key])
	end

	return table.concat(parts, "|")
end

function Bake.CacheKey(payload)
	return string.format("%08x", util.CRC(payload .. "|" .. SettingsString()))
end

-- A late tick halves the allowance, an on time one grows it by a tenth, and the ceiling is a fraction
-- of the tick interval. The signal is how long ticks are taking, not a duration read off the engine's
-- clock: engine.AbsoluteFrameTime on a listen server contains the client's rendering.
function Bake.NextSlice()
	local now = SysTime()
	local interval = engine.TickInterval()
	local previous = Bake.sliceCalled
	Bake.sliceCalled = now

	local target = 1 / math.max(cfg.MinServerTickRate, 1)
	local share = cfg.MaxTickUsage
	local maxSlice = cfg.MaxBakeSliceMs / 1000
	local minSlice = cfg.MinBakeSliceMs / 1000

	local window = Bake.sliceWindow or minSlice
	local late = previous ~= nil and (now - previous) > target

	if late then
		window = window * 0.5
	else
		window = math.min(window * 1.1, interval * share, maxSlice)
	end

	window = math.Clamp(window, minSlice, maxSlice)
	Bake.sliceWindow = window

	return window
end
