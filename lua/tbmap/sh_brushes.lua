-- The brushes as collision: the point sets the collision is built from, the shapes pressed against a
-- face, and the parts of a face another brush covers. Shared by both realms.

TBMap = TBMap or {}

TBMap.Brushes = { list = {} }

-- Rebuilds the per brush point sets and planes from the faces. The points are what VPhysics is given,
-- so collision matches on both sides.
function TBMap.Brushes.Build(faces)
	local byBrush = {}

	for _, face in ipairs(faces) do
		local key = face.brush or 0
		local list = byBrush[key]

		if not list then
			list = {}
			byBrush[key] = list
		end

		table.insert(list, face)
	end

	local convexes = {}
	TBMap.Brushes.list = {}

	for id, list in pairs(byBrush) do
		TBMap.Bake.Slice()

		local points, seen = {}, {}
		local planes = {}

		for _, face in ipairs(list) do
			local n = face.normal

			TBMap.Probe.Start("brushes.planes")
			planes[#planes + 1] = n.x
			planes[#planes + 1] = n.y
			planes[#planes + 1] = n.z
			planes[#planes + 1] = n:Dot(face.poly[1])
			TBMap.Probe.Stop("brushes.planes")

			TBMap.Probe.Start("brushes.points")

			for _, v in ipairs(face.poly) do
				local key = string.format("%.3f %.3f %.3f", v.x, v.y, v.z)

				if not seen[key] then
					seen[key] = true
					table.insert(points, v)
				end
			end

			TBMap.Probe.Stop("brushes.points")
		end

		TBMap.Probe.Start("brushes.solid")
		local solid = TBMap.IsSolid(points)
		TBMap.Probe.Stop("brushes.solid")

		if solid then
			table.insert(convexes, points)

			local mins, maxs = TBMap.PolyBox(points)

			if mins and maxs then
				table.insert(TBMap.Brushes.list, {
					mins = mins,
					maxs = maxs,
					brush = id,
					planes = planes,
					points = points,
					minx = mins.x, miny = mins.y, minz = mins.z,
					maxx = maxs.x, maxy = maxs.y, maxz = maxs.z,
				})
			end
		end
	end

	return convexes
end

-- The brushes whose boxes overlap a box, from the tracer's grid. The result table is reused, since
-- this runs once per face.
local seen = {}
local candidates = {}

function TBMap.Brushes.Near(mins, maxs, margin)
	local grid = TBMap.Trace.grid
	local count = 0

	-- Counted, because how many candidates the grid hands back is what the clip, the cover and the
	-- contact gather all pay per call, and it is the grid's cell size that decides it.
	TBMap.NearCalls = (TBMap.NearCalls or 0) + 1

	if grid.nx == 0 then
		for index = 1, #TBMap.Brushes.list do
			count = count + 1
			candidates[count] = index
		end

		TBMap.NearCandidates = (TBMap.NearCandidates or 0) + count

		return candidates, count
	end

	local cell = grid.cell
	local nx, ny = grid.nx, grid.ny

	local pad = math.floor((margin or 0) / cell) + 1

	local x0 = math.max(math.floor((mins.x - grid.ox) / cell) - pad, 0)
	local y0 = math.max(math.floor((mins.y - grid.oy) / cell) - pad, 0)
	local z0 = math.max(math.floor((mins.z - grid.oz) / cell) - pad, 0)
	local x1 = math.min(math.floor((maxs.x - grid.ox) / cell) + pad, nx - 1)
	local y1 = math.min(math.floor((maxs.y - grid.oy) / cell) + pad, ny - 1)
	local z1 = math.min(math.floor((maxs.z - grid.oz) / cell) + pad, grid.nz - 1)

	local boxCells = (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)
	local occupied = grid.occupied

	-- Whichever is fewer: the cells in the box, or the cells that hold brushes. The prism box a sun face
	-- asks about is long and thin and mostly empty, so walking the occupied cells skips the empty ones.
	if occupied and boxCells > #occupied then
		local brushList = TBMap.Brushes.list

		-- A box this large makes the walk visit a brush once per cell it fills, which is more than one
		-- test per brush, so once the grid holds more entries than there are brushes the flat list is the
		-- cheaper enumeration. It is the same set: a brush is a candidate when its box meets a cell of
		-- the query, which is a box overlap with the extent of those cells.
		if (grid.insertions or #occupied) > #brushList then
			local minx, miny, minz = grid.ox + x0 * cell, grid.oy + y0 * cell, grid.oz + z0 * cell
			local maxx, maxy, maxz = grid.ox + (x1 + 1) * cell, grid.oy + (y1 + 1) * cell,
				grid.oz + (z1 + 1) * cell

			for index = 1, #brushList do
				local brush = brushList[index]

				if not brush.seeThrough
					and brush.minx <= maxx and brush.maxx >= minx
					and brush.miny <= maxy and brush.maxy >= miny
					and brush.minz <= maxz and brush.maxz >= minz then
					count = count + 1
					candidates[count] = index
				end
			end

			TBMap.NearCandidates = (TBMap.NearCandidates or 0) + count

			return candidates, count
		end

		local stride = nx * ny

		for i = 1, #occupied do
			local key = occupied[i]
			local x = key % nx
			local y = math.floor(key / nx) % ny
			local z = math.floor(key / stride)

			if x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z0 and z <= z1 then
				local list = grid.cells[key + 1]

				for j = 1, #list do
					local index = list[j]

					if not seen[index] then
						seen[index] = true
						count = count + 1
						candidates[count] = index
					end
				end
			end
		end
	else
		for z = z0, z1 do
			for y = y0, y1 do
				local rowBase = (z * ny + y) * nx

				for x = x0, x1 do
					local list = grid.cells[rowBase + x + 1]

					if list then
						for i = 1, #list do
							local index = list[i]

							if not seen[index] then
								seen[index] = true
								count = count + 1
								candidates[count] = index
							end
						end
					end
				end
			end
		end
	end

	for i = 1, count do seen[candidates[i]] = nil end

	TBMap.NearCandidates = (TBMap.NearCandidates or 0) + count

	return candidates, count
end

-- Sutherland-Hodgman: clips a convex polygon in the face's own two dimensions by one half plane, and
-- keeps the input's winding.
local function ClipHalf(pu, pw, count, a, b, c, ou, ow)
	local out = 0

	for i = 1, count do
		local j = i % count + 1
		local ui, wi = pu[i], pw[i]
		local uj, wj = pu[j], pw[j]

		-- Positive is inside, which is the half plane a*u + b*w <= c.
		local di = c - (a * ui + b * wi)
		local dj = c - (a * uj + b * wj)

		if di >= 0 then
			out = out + 1
			ou[out], ow[out] = ui, wi
		end

		if (di >= 0) ~= (dj >= 0) then
			local t = di / (di - dj)

			out = out + 1
			ou[out] = ui + (uj - ui) * t
			ow[out] = wi + (wj - wi) * t
		end
	end

	return out
end

-- Every plane of one brush taken out of a quad in the face's own two dimensions, in place: the state
-- walk the contact rule and the clip both run, so the two cannot drift apart.
local pendingU, pendingW = {}, {}

local function ClipByPlanes(planes, t1x, t1y, t1z, t2x, t2y, t2z, ox, oy, oz, cu, cw, count)
	for p = 1, #planes, 4 do
		local px, py, pz, pd = planes[p], planes[p + 1], planes[p + 2], planes[p + 3]
		local a = px * t1x + py * t1y + pz * t1z
		local b = px * t2x + py * t2y + pz * t2z
		local c = pd - (px * ox + py * oy + pz * oz)
		local out = ClipHalf(cu, cw, count, a, b, c, pendingU, pendingW)

		for k = 1, out do cu[k], cw[k] = pendingU[k], pendingW[k] end

		count = out
		if count < 3 then break end
	end

	return count
end

-- The brushes pressed against a face, as convex polygons in the face's own two dimensions: each brush's
-- cross section with the face's plane, the same polygon the clip builds for a cover.
-- Twice the signed area of a convex polygon in the face's plane, taken about its first vertex so the
-- terms stay small: only ever compared against a threshold.
local function TwiceArea(pu, pw, count)
	local u0, w0 = pu[1], pw[1]
	local total = 0

	for i = 2, count - 1 do
		total = total + (pu[i] - u0) * (pw[i + 1] - w0) - (pu[i + 1] - u0) * (pw[i] - w0)
	end

	return total
end

--
-- A brush counts when it crosses the plane. Not one that begins in front of it but not against it, not
-- one lying flush in it, and not the face's own brush.
function TBMap.Brushes.ContactRects(face, normal, width, depth)
	local list = TBMap.Brushes.list
	local fmin, fmax = face.tbMins, face.tbMaxs

	if not fmin then fmin, fmax = TBMap.PolyBox(face.poly) end

	local near, count = TBMap.Brushes.Near(fmin, fmax, width)

	local nx, ny, nz = normal.x, normal.y, normal.z
	local t1, t2 = TBMap.Sample.Basis(normal)
	local first = face.poly[1]
	local t1x, t1y, t1z = t1.x, t1.y, t1.z
	local t2x, t2y, t2z = t2.x, t2.y, t2.z

	-- How far a brush has to reach through the plane to count as standing on the face rather than lying
	-- in it.

	local plane = nx * first.x + ny * first.y + nz * first.z
	local front = TBMap.Config.GeometryTolerance
	local own = face.brush or 0

	local ox, oy, oz = nx * plane, ny * plane, nz * plane

	-- The face's bounds opened by the contact width, so a brush standing beside the face still darkens
	-- the texels within the width of the join.
	local u0, u1 = math.huge, -math.huge
	local w0, w1 = math.huge, -math.huge

	for i = 1, #face.poly do
		local dx, dy, dz = face.poly[i].x - ox, face.poly[i].y - oy, face.poly[i].z - oz
		local u = dx * t1x + dy * t1y + dz * t1z
		local w = dx * t2x + dy * t2y + dz * t2z

		if u < u0 then u0 = u elseif u > u1 then u1 = u end
		if w < w0 then w0 = w elseif w > w1 then w1 = w end
	end

	u0, u1 = u0 - width, u1 + width
	w0, w1 = w0 - width, w1 + width

	local polys = {}
	local found = 0
	local cu, cw = {}, {}

	for i = 1, count do
		local brush = list[near[i]]

		-- A see-through brush presses nothing. It does not occlude, so it cannot crease what is around it,
		-- and leaving it in darkens the floor and the wall a pane is set into.
		if brush.brush ~= own and brush.points and not brush.seeThrough then
			-- The brush's box rather than its points: the box's interval along the normal contains the
			-- points', so a box that fails either bound has no point that passes it, and this is six
			-- multiplies instead of a dot product per point.
			local cx, cy, cz = (brush.minx + brush.maxx) * 0.5, (brush.miny + brush.maxy) * 0.5,
				(brush.minz + brush.maxz) * 0.5
			local hx, hy, hz = (brush.maxx - brush.minx) * 0.5, (brush.maxy - brush.miny) * 0.5,
				(brush.maxz - brush.minz) * 0.5
			local along = nx * cx + ny * cy + nz * cz - plane
			local spread = math.abs(nx) * hx + math.abs(ny) * hy + math.abs(nz) * hz
			local ahead, behind = along + spread, along - spread

			local taken = ahead > front and behind < depth
			local cn, area = 0, 0

			if taken then
				cu[1], cw[1] = u0, w0
				cu[2], cw[2] = u1, w0
				cu[3], cw[3] = u1, w1
				cu[4], cw[4] = u0, w1

				cn = ClipByPlanes(brush.planes, t1x, t1y, t1z, t2x, t2y, t2z, ox, oy, oz, cu, cw, 4)

				-- A brush that grazes the plane instead of crossing it clips to a line. Left in, its
				-- distance is zero everywhere along that line and the whole face darkens in a band.
				area = cn >= 3 and TwiceArea(cu, cw, cn) or 0

				if cn < 3 or math.abs(area) <= 1e-6 then taken = false end
			end

			if taken then
				local minU, maxU, minW, maxW = math.huge, -math.huge, math.huge, -math.huge

				for k = 1, cn do
					local u, w = cu[k], cw[k]

					if u < minU then minU = u elseif u > maxU then maxU = u end
					if w < minW then minW = w elseif w > maxW then maxW = w end
				end

				-- Count, the box, the angle for an edge that is a cut rather than a junction, then a u, a
				-- w and that edge's own angle per vertex. Every edge of the cross section lies in one of
				-- the brush's planes, and the turn between that plane and this face is the angle of the
				-- junction the edge is: none for a coplanar continuation, one at a right angle, more for
				-- an acute fold. Taken per edge because a rounded surface turns by a different angle at
				-- each of its seams, and one angle for the whole brush read as a right angle wherever the
				-- seams did not line up with its box. The fallback is the shape's shallowest edge rather
				-- than the nearest one, since which edge is nearest changes as a texel moves and a step
				-- between two angles is a sparkle along it.
				local at = #polys + 1
				local shapeScale = -1

				polys[at] = cn
				polys[at + 1], polys[at + 2] = minU, maxU
				polys[at + 3], polys[at + 4] = minW, maxW

				for k = 1, cn do
					local j = k % cn + 1
					local u, w = cu[k], cw[k]
					local bu, bw = cu[j], cw[j]
					local scale = -1
					local mostParallel = 0.5

					-- The edge lies in one of the brush's planes: that plane is the surface it turns into
					-- here, and the turn is this junction's angle. The one that counts is the most nearly
					-- parallel facing the same way, which is what a continuation of this face looks like;
					-- a plane facing away, such as a brush's own underside along its footprint, says
					-- nothing about the turn.
					for p = 1, #brush.planes, 4 do
						local px, py, pz, pd = brush.planes[p], brush.planes[p + 1],
							brush.planes[p + 2], brush.planes[p + 3]
						local d = px * nx + py * ny + pz * nz

						if d > mostParallel then
							local a = px * t1x + py * t1y + pz * t1z
							local b = px * t2x + py * t2y + pz * t2z
							local c = px * ox + py * oy + pz * oz - pd

							if math.abs(a * u + b * w + c) < 1e-3
								and math.abs(a * bu + b * bw + c) < 1e-3 then
								mostParallel = d
								scale = math.deg(math.acos(math.min(d, 1))) / 90
							end
						end
					end

					if scale >= 0 and (shapeScale < 0 or scale < shapeScale) then
						shapeScale = scale
					end

					local vertex = at + 6 + (k - 1) * 3

					polys[vertex] = u
					polys[vertex + 1] = w
					polys[vertex + 2] = scale
				end

				polys[at + 5] = shapeScale

				found = found + 1
			end
		end
	end

	return polys, found
end

-- Zero inside the cross section, otherwise the distance to its nearest edge, and the angle of that
-- edge's junction. An edge that is a cut through the wall has no angle of its own and the shape's
-- shallowest one is used instead. Wound counter clockwise in (u, w), so the inside is on one side of
-- every edge.
function TBMap.Brushes.PolyDistance(list, at, u, w)
	local n = list[at]
	local inside = true
	local best = math.huge
	local bestScale = -1
	local shapeScale = list[at + 5]

	for i = 1, n do
		local vertices = at + 6 + (i - 1) * 3
		local j = i % n + 1
		local nextVertices = at + 6 + (j - 1) * 3
		local au, aw = list[vertices], list[vertices + 1]
		local bu, bw = list[nextVertices], list[nextVertices + 1]
		local eu, ew = bu - au, bw - aw

		if ew * (u - au) - eu * (w - aw) > 0 then inside = false end

		-- Squared until the end: a point past either end takes that end, which makes this the distance to
		-- the shape rather than to its lines.

		local len2 = eu * eu + ew * ew
		local t = 0

		if len2 > 0 then
			t = ((u - au) * eu + (w - aw) * ew) / len2

			if t < 0 then t = 0 elseif t > 1 then t = 1 end
		end

		local du = u - (au + eu * t)
		local dw = w - (aw + ew * t)
		local d2 = du * du + dw * dw

		if d2 < best then
			best = d2

			local scale = list[vertices + 2]

			if scale >= 0 then
				bestScale = scale
			end
		end
	end

	if bestScale < 0 then bestScale = shapeScale end
	if bestScale < 0 then bestScale = 1 end

	-- Cross sections are gathered with their area checked, so a collinear one never reaches this and the
	-- inside test means what it says.
	if inside then return 0, bestScale end

	return math.sqrt(best), bestScale
end

-- =========================================================================
-- Cutting away what another brush covers
-- =========================================================================
--
-- The face minus the covering polygon is the union of the face clipped by each of that polygon's half
-- planes in turn, with the earlier clips applied, so no boolean library is needed.
--
-- One rule this does not have: a brush's volume only hides a face where the covering brush's boundary
-- over that region is drawn. A brush with a nodraw top sitting in a floor hides nothing, and cutting
-- that floor away leaves a hole.

-- A plane read from either side, so a brush abutting another at a shared surface is recognised as
-- having a face in it however the two normals are written.
function TBMap.PlaneKey(nx, ny, nz, d)
	if nx < -0.001 or (math.abs(nx) <= 0.001 and (ny < -0.001 or (math.abs(ny) <= 0.001 and nz < 0))) then
		nx, ny, nz, d = -nx, -ny, -nz, -d
	end

	return string.format("%.2f,%.2f,%.2f,%.2f", nx, ny, nz, d)
end

local CLIP_SLACK = 0.1

-- The smallest cross section worth calling a cover, as twice its area: a brush that only touches the
-- plane intersects it in a line, which covers nothing.
local CLIP_MIN_TWICE_COVER = 4

-- The same clip on both sides of the plane at once, since the piece cutting below takes each side of
-- each edge and two passes over the same vertices is the innermost loop of the clip. Returns the counts
-- of the side the plane keeps and of the side it cuts away.
local function ClipBoth(pu, pw, count, a, b, c, ku, kw, ju, jw)
	local kept, aside = 0, 0

	for i = 1, count do
		local j = i % count + 1
		local ui, wi = pu[i], pw[i]
		local uj, wj = pu[j], pw[j]

		local di = c - (a * ui + b * wi)
		local dj = c - (a * uj + b * wj)

		-- Each side keeps what it would have kept on its own, a vertex on the plane included, and each
		-- crosses on its own test: the two passes this replaces were not symmetric about the plane.
		local left, leftNext = di >= 0, dj >= 0
		local right, rightNext = di <= 0, dj <= 0

		if left then
			kept = kept + 1
			ku[kept], kw[kept] = ui, wi
		end

		if right then
			aside = aside + 1
			ju[aside], jw[aside] = ui, wi
		end

		if left ~= leftNext or right ~= rightNext then
			local t = di / (di - dj)
			local u, w = ui + (uj - ui) * t, wi + (wj - wi) * t

			if left ~= leftNext then
				kept = kept + 1
				ku[kept], kw[kept] = u, w
			end

			if right ~= rightNext then
				aside = aside + 1
				ju[aside], jw[aside] = u, w
			end
		end
	end

	return kept, aside
end

-- Whether a brush reaches in front of a face's plane, and whether it lies in it.
local function Crosses(brush, nx, ny, nz, plane)
	local hx = (brush.maxx - brush.minx) * 0.5
	local hy = (brush.maxy - brush.miny) * 0.5
	local hz = (brush.maxz - brush.minz) * 0.5
	local bx, by, bz = brush.minx + hx, brush.miny + hy, brush.minz + hz
	local along = bx * nx + by * ny + bz * nz - plane
	local spread = math.abs(nx) * hx + math.abs(ny) * hy + math.abs(nz) * hz
	local ahead, behind = along + spread, along - spread

	return ahead > CLIP_SLACK, ahead <= CLIP_SLACK and behind <= -CLIP_SLACK
end

-- Cuts the covered part out of every face another drawn brush covers. A face nothing covers passes
-- through untouched, which is most of a map.
function TBMap.Brushes.ClipFaces(faces, draws, opaque, allDrawn)
	local list = TBMap.Brushes.list
	local out = {}
	local cutFaces, cutPieces, dropped = 0, 0, 0

	local fu, fw = {}, {}
	local au, aw = {}, {}
	local bu, bw = {}, {}
	local iu, iw = {}, {}
	local cu, cw = {}, {}
	local live, spare = {}, {}

	for _, face in ipairs(faces) do
		local poly, normal = face.poly, face.normal
		local t1, t2 = TBMap.Sample.Basis(normal)
		local origin = poly[1]
		local ox, oy, oz = origin.x, origin.y, origin.z
		local t1x, t1y, t1z = t1.x, t1.y, t1.z
		local t2x, t2y, t2z = t2.x, t2.y, t2.z
		local nx, ny, nz = normal.x, normal.y, normal.z
		local plane = nx * ox + ny * oy + nz * oz
		local count = #poly

		local u0, u1 = math.huge, -math.huge
		local w0, w1 = math.huge, -math.huge

		for i = 1, count do
			local dx, dy, dz = poly[i].x - ox, poly[i].y - oy, poly[i].z - oz
			local u = dx * t1x + dy * t1y + dz * t1z
			local w = dx * t2x + dy * t2y + dz * t2z

			fu[i], fw[i] = u, w

			if u < u0 then u0 = u elseif u > u1 then u1 = u end
			if w < w0 then w0 = w elseif w > w1 then w1 = w end
		end

		local fmin, fmax = face.tbMins, face.tbMaxs
		if not fmin then fmin, fmax = TBMap.PolyBox(poly) end

		local near, nearCount = TBMap.Brushes.Near(fmin, fmax, CLIP_SLACK)
		local own = face.brush or 0
		local covered = false
		local started = false
		local liveCount = 0

		local planeKey = TBMap.PlaneKey(nx, ny, nz, plane)

		for i = 1, nearCount do
			if started and liveCount == 0 then break end

			local brush = list[near[i]]
			local crossing, liesIn = false, false

			if brush.brush ~= own and draws[brush.brush] then
				crossing, liesIn = Crosses(brush, nx, ny, nz, plane)
			end

			-- A region inside a brush whose every face is drawn is hidden, because any ray to it crosses a
			-- drawn face. A brush with a tool face somewhere needs its own face over the region to be drawn
			-- instead, which is the shared surface case.
			local coverOpaque = opaque and opaque[brush.brush] and opaque[brush.brush][planeKey]
			local covers = coverOpaque or (allDrawn and allDrawn[brush.brush])

			-- A brush lying in the plane has to have its own face there drawn, or trimming this one would
			-- leave nothing on screen, and has to come first, which is a total order and so trims exactly
			-- one of a coincident pair.
			local coplanar = liesIn and brush.brush < own and covers

			if crossing or coplanar then
				cu[1], cw[1] = u0 - 1, w0 - 1
				cu[2], cw[2] = u1 + 1, w0 - 1
				cu[3], cw[3] = u1 + 1, w1 + 1
				cu[4], cw[4] = u0 - 1, w1 + 1

				local cn = ClipByPlanes(brush.planes, t1x, t1y, t1z, t2x, t2y, t2z, ox, oy, oz, cu, cw, 4)

				if cn >= 3 and math.abs(TwiceArea(cu, cw, cn)) > CLIP_MIN_TWICE_COVER then
					covered = true

					if not started then
						started = true
						liveCount = 1
						live[1] = { u = fu, w = fw, n = count }
					end

					spare = {}
					local spareCount = 0

					for pi = 1, liveCount do
						local piece = live[pi]
						local pu, pw = piece.u, piece.w
						local pn = piece.n

						for k = 1, pn do au[k], aw[k] = pu[k], pw[k] end

						for e = 1, cn do
							local j = e % cn + 1
							local ex, ey = cu[j] - cu[e], cw[j] - cw[e]
							local a, b = ey, -ex
							local c = a * cu[e] + b * cw[e]

							local inside, aside = ClipBoth(au, aw, pn, a, b, c, bu, bw, iu, iw)

							if aside >= 3 and math.abs(TwiceArea(iu, iw, aside)) > 1 then
								local ku, kw = {}, {}

								for k = 1, aside do ku[k], kw[k] = iu[k], iw[k] end

								spareCount = spareCount + 1
								spare[spareCount] = { u = ku, w = kw, n = aside }
							end

							-- What lies inside carries on; when it runs out the piece was wholly inside.
							if inside < 3 then
								pn = 0
								break
							end

							for k = 1, inside do au[k], aw[k] = bu[k], bw[k] end
							pn = inside
						end
					end

					-- What is still carried after the last edge is under this brush and is dropped; what was set
					-- aside is what the next brush is applied to.
					live = spare
					liveCount = spareCount
				end
			end
		end

		if not covered then
			out[#out + 1] = face
		elseif liveCount == 0 then
			-- Emptied: a brush crossing the plane hides the region with its body, and a coincident brush that
			-- took the coplanar rule above has its own face drawn over the region. Either way there is nothing
			-- left to draw here.
			dropped = dropped + 1
		else
			cutFaces = cutFaces + 1

			for pi = 1, liveCount do
				local piece = live[pi]
				local pu, pw = piece.u, piece.w
				local newPoly = {}

				for k = 1, piece.n do
					local u, w = pu[k], pw[k]

					newPoly[k] = Vector(
						ox + t1x * u + t2x * w,
						oy + t1y * u + t2y * w,
						oz + t1z * u + t2z * w)
				end

				cutPieces = cutPieces + 1

				-- The piece's own number, so two halves of one face are not the same face to Bake.FaceKey,
				-- and the whole face it was cut from, stamped here rather than matched back later by its
				-- plane: the match is over rounded floats and a near boundary misses.
				out[#out + 1] = {
					mat = face.mat,
					ori = face.ori,
					brush = face.brush,
					normal = normal,
					uaxis = face.uaxis,
					vaxis = face.vaxis,
					uoffset = face.uoffset,
					voffset = face.voffset,
					xscale = face.xscale,
					yscale = face.yscale,
					poly = newPoly,
					tbPiece = pi,
					tbSource = face.tbWhole,
				}
			end
		end
	end

	return out, cutFaces, cutPieces, dropped
end

-- Whether a face is entirely inside one other drawn brush. Every vertex has to be clear of every plane
-- of the same brush by a margin: a face lying exactly on a brush is on it rather than in it, and counting
-- it as buried deletes a surface that is on screen.
function TBMap.Brushes.Buried(poly, fmin, fmax, skip, draws)
	local slack = 0.1
	local brushList = TBMap.Brushes.list
	local near, count = TBMap.Brushes.Near(fmin, fmax)

	local minx, miny, minz = fmin.x, fmin.y, fmin.z
	local maxx, maxy, maxz = fmax.x, fmax.y, fmax.z

	for i = 1, count do
		local brush = brushList[near[i]]

		if brush.brush ~= skip and draws[brush.brush]
			and minx >= brush.minx - slack and maxx <= brush.maxx + slack
			and miny >= brush.miny - slack and maxy <= brush.maxy + slack
			and minz >= brush.minz - slack and maxz <= brush.maxz + slack then

			local inside = true
			local planes = brush.planes

			for _, v in ipairs(poly) do
				for p = 1, #planes, 4 do
					if planes[p] * v.x + planes[p + 1] * v.y + planes[p + 2] * v.z - planes[p + 3] > -slack then
						inside = false
						break
					end
				end

				if not inside then break end
			end

			if inside then return true end
		end
	end

	return false
end
