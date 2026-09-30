-- =========================================================================
-- What a parallel light can reach
-- =========================================================================
--
-- A directional term's answer is a step, so whole faces can be classified without a ray. If no brush's
-- shadow can touch the grid every sample is lit, since a brush's shadow lies inside the projection of
-- its box onto the face's plane. If one brush shadows all four corners it shadows all of them, since a
-- convex brush's shadow on a plane is convex and the grid's rectangle is the hull of its corners.
--
-- Only the first is a proof: a brush can shadow the middle of a face while missing its corners.

TBMap = TBMap or {}

TBMap.Cover = {}

local cfg = TBMap.Config
local Cover = TBMap.Cover

-- Whether the ray from this point along the light meets this one brush, no closer than bias: the ray
-- is inside from tmin, so tmin is the distance to the blocker. The readable copy of the tracer's inline
-- clip, and the two have to agree.
local function HitsBrush(planes, fx, fy, fz, dx, dy, dz, bias)
	local tmin, tmax = 0, math.huge

	for p = 1, #planes, 4 do
		local nx, ny, nz, d = planes[p], planes[p + 1], planes[p + 2], planes[p + 3]
		local num = nx * fx + ny * fy + nz * fz - d
		local den = nx * dx + ny * dy + nz * dz

		if den > -1e-6 and den < 1e-6 then
			if num > 0 then return false end
		else
			local t = -num / den

			if den > 0 then
				if t < tmax then tmax = t end
			elseif t > tmin then
				tmin = t
			end
		end

		if tmin > tmax then return false end
	end

	return tmin >= (bias or 0)
end

-- Whether every sample of a grid is blocked by one brush, no closer than the bias.
--
-- The samples are walked rather than the corners: the distance to the first blocker is convex, and a
-- convex function on a rectangle is at its smallest in the interior, so a corner test cannot see the
-- sample in the middle of a face that sits just under a roof its corners clear.
local function CoversGrid(planes, s, cols, rows, stride, dx, dy, dz, bias)
	local ox, oy, oz = s.origin.x, s.origin.y, s.origin.z
	local t1x, t1y, t1z = s.t1.x, s.t1.y, s.t1.z
	local t2x, t2y, t2z = s.t2.x, s.t2.y, s.t2.z
	local nx, ny, nz = s.face.normal.x, s.face.normal.y, s.face.normal.z
	local offset = cfg.TraceStartOffset
	local margin, unit = s.margin, s.unit
	local uStart, vStart = s.uStart, s.vStart
	local lastCol, lastRow = s.width - 1 - margin, s.height - 1 - margin

	-- Row and column walked directly rather than through TBMap.Sample.NodeAxis: this is the innermost
	-- loop of the cover, and the index to coordinates is a division per node.
	for row = 0, rows - 1 do
		local r = margin + row * stride

		if r > lastRow then r = lastRow end

		local w = vStart + (r + 0.5) * unit

		for col = 0, cols - 1 do
			local c = margin + col * stride

			if c > lastCol then c = lastCol end

			local u = uStart + (c + 0.5) * unit

			local px = ox + t1x * u + t2x * w + nx * offset
			local py = oy + t1y * u + t2y * w + ny * offset
			local pz = oz + t1z * u + t2z * w + nz * offset

			if not HitsBrush(planes, px, py, pz, dx, dy, dz, bias) then return false end
		end
	end

	return true
end

-- The four corner samples of a grid, offset off the surface the way sh_bake's traces are.
local function Anchors(s, cols, rows, stride)
	local last = rows * cols
	local indices = { 1, cols, last - cols + 1, last }
	local points = {}
	local u0, u1, v0, v1 = math.huge, -math.huge, math.huge, -math.huge

	local ox, oy, oz = s.origin.x, s.origin.y, s.origin.z
	local t1x, t1y, t1z = s.t1.x, s.t1.y, s.t1.z
	local t2x, t2y, t2z = s.t2.x, s.t2.y, s.t2.z
	local n = s.face.normal
	local offset = cfg.TraceStartOffset

	for i = 1, 4 do
		local col, row = TBMap.Sample.NodeAxis(s, indices[i], cols, stride)
		local u = s.uStart + (col + 0.5) * s.unit
		local w = s.vStart + (row + 0.5) * s.unit

		local px = ox + t1x * u + t2x * w
		local py = oy + t1y * u + t2y * w
		local pz = oz + t1z * u + t2z * w

		points[i] = { x = px + n.x * offset, y = py + n.y * offset, z = pz + n.z * offset }

		if u < u0 then u0 = u elseif u > u1 then u1 = u end
		if w < v0 then v0 = w elseif w > v1 then v1 = w end
	end

	return points, u0, u1, v0, v1
end

local suspectIndices = {}

-- The brushes whose shadow could land anywhere on the grid, as indices into the brush list. A blocking
-- ray passes through the prism the corners sweep toward the light, and a brush's shadow is inside its
-- box's projection onto the face's plane, so a brush this misses cannot block any sample.
local function Suspects(s, points, u0, u1, v0, v1, dx, dy, dz)
	local grid = TBMap.Trace.grid
	if grid.nx == 0 then return 0 end

	local n = s.face.normal
	local nd = n.x * dx + n.y * dy + n.z * dz
	local skip = s.face.brush

	if nd <= 0 then return 0 end

	local cell = grid.cell
	local bx0, by0, bz0 = grid.ox, grid.oy, grid.oz
	local bx1 = bx0 + grid.nx * cell
	local by1 = by0 + grid.ny * cell
	local bz1 = bz0 + grid.nz * cell

	local far, anchorNear = -math.huge, math.huge

	for mask = 0, 7 do
		local x = (mask % 2 == 0) and bx0 or bx1
		local y = (math.floor(mask / 2) % 2 == 0) and by0 or by1
		local z = (math.floor(mask / 4) % 2 == 0) and bz0 or bz1
		local d = x * dx + y * dy + z * dz

		if d > far then far = d end
	end

	for i = 1, 4 do
		local p = points[i]
		local d = p.x * dx + p.y * dy + p.z * dz

		if d < anchorNear then anchorNear = d end
	end

	-- The whole map behind the grid along the light: nothing can block it.

	if far - anchorNear <= 0 then return 0 end

	local sweep = far - anchorNear
	local px0, py0, pz0 = points[1].x, points[1].y, points[1].z
	local px1, py1, pz1 = px0, py0, pz0

	for i = 1, 4 do
		local p = points[i]
		local ex, ey, ez = p.x + dx * sweep, p.y + dy * sweep, p.z + dz * sweep

		if p.x < px0 then px0 = p.x elseif p.x > px1 then px1 = p.x end
		if p.y < py0 then py0 = p.y elseif p.y > py1 then py1 = p.y end
		if p.z < pz0 then pz0 = p.z elseif p.z > pz1 then pz1 = p.z end
		if ex < px0 then px0 = ex elseif ex > px1 then px1 = ex end
		if ey < py0 then py0 = ey elseif ey > py1 then py1 = ey end
		if ez < pz0 then pz0 = ez elseif ez > pz1 then pz1 = ez end
	end

	-- The box around the prism, not the prism: a superset, so the query stays the axis aligned one.
	TBMap.Probe.Start("cover.near")
	local near, count = TBMap.Brushes.Near(Vector(px0, py0, pz0), Vector(px1, py1, pz1))
	TBMap.Probe.Stop("cover.near")

	local list = TBMap.Brushes.list
	local ox, oy, oz = s.origin.x, s.origin.y, s.origin.z
	local t1x, t1y, t1z = s.t1.x, s.t1.y, s.t1.z
	local t2x, t2y, t2z = s.t2.x, s.t2.y, s.t2.z
	local found = 0

	-- The shadow of a point at height h above the plane lands at u + su*h, so the shadow of a box is the
	-- same linear function of its corners. Its extents are then the box's centre and half extents in two
	-- shifted bases, which is exact and a dozen multiplies rather than eight projected corners.
	local inv = 1 / nd
	local su = -(dx * t1x + dy * t1y + dz * t1z) * inv
	local sv = -(dx * t2x + dy * t2y + dz * t2z) * inv
	local ux, uy, uz = t1x + su * n.x, t1y + su * n.y, t1z + su * n.z
	local wx, wy, wz = t2x + sv * n.x, t2y + sv * n.y, t2z + sv * n.z
	local uax, uay, uaz = math.abs(ux), math.abs(uy), math.abs(uz)
	local wax, way, waz = math.abs(wx), math.abs(wy), math.abs(wz)

	TBMap.Probe.Start("cover.project")

	for i = 1, count do
		local index = near[i]
		local brush = list[index]

		-- The face's own brush cannot shadow it while the face points toward the light: its plane is a
		-- supporting plane of its own convex brush, so the ray leaves the surface.
		if brush.brush ~= skip then
			local bx, by, bz = brush.minx, brush.miny, brush.minz
			local Bx, By, Bz = brush.maxx, brush.maxy, brush.maxz

			local cx, cy, cz = (bx + Bx) * 0.5, (by + By) * 0.5, (bz + Bz) * 0.5
			local hx, hy, hz = (Bx - bx) * 0.5, (By - by) * 0.5, (Bz - bz) * 0.5
			local boxFar = cx * dx + cy * dy + cz * dz
				+ math.abs(dx) * hx + math.abs(dy) * hy + math.abs(dz) * hz

			if boxFar >= anchorNear then
				local rx, ry, rz = cx - ox, cy - oy, cz - oz
				local uc = rx * ux + ry * uy + rz * uz
				local ur = uax * hx + uay * hy + uaz * hz

				-- Only an overlap with the grid's rectangle can matter.
				if uc + ur >= u0 and uc - ur <= u1 then
					local wc = rx * wx + ry * wy + rz * wz
					local wr = wax * hx + way * hy + waz * hz

					if wc + wr >= v0 and wc - wr <= v1 then
						found = found + 1
						suspectIndices[found] = index
					end
				end
			end
		end
	end

	TBMap.Probe.Stop("cover.project")

	return found
end

-- "lit" when no brush can shadow any sample, "dark" when one covers all of them, and "mixed" when the
-- answer has to be sampled. The centre ray is tried first, since most of a roofed map is entirely under
-- one brush. Only when the middle is clear is the prism built.
function Cover.Grid(s, cols, rows, stride, dx, dy, dz, bias)
	if cols < 1 or rows < 1 then return "mixed" end

	-- A face pointing away is dark at every sample, exactly: the sun's own test returns zero for this
	-- case.
	local n = s.face.normal

	if n.x * dx + n.y * dy + n.z * dz <= 0 then return "dark" end

	local grid = TBMap.Trace.grid
	if grid.nx == 0 then return "mixed" end

	TBMap.Probe.Start("cover.anchors")
	local points, u0, u1, v0, v1 = Anchors(s, cols, rows, stride)
	TBMap.Probe.Stop("cover.anchors")

	local cell = grid.cell

	local far = -math.huge

	for mask = 0, 7 do
		local x = (mask % 2 == 0) and grid.ox or (grid.ox + grid.nx * cell)
		local y = (math.floor(mask / 2) % 2 == 0) and grid.oy or (grid.oy + grid.ny * cell)
		local z = (math.floor(mask / 4) % 2 == 0) and grid.oz or (grid.oz + grid.nz * cell)
		local d = x * dx + y * dy + z * dz

		if d > far then far = d end
	end

	local cx = (points[1].x + points[2].x + points[3].x + points[4].x) * 0.25
	local cy = (points[1].y + points[2].y + points[3].y + points[4].y) * 0.25
	local cz = (points[1].z + points[2].z + points[3].z + points[4].z) * 0.25
	local centreD = cx * dx + cy * dy + cz * dz
	local reach = math.min(cfg.ShadowRayLength, math.max(far - centreD, 1))

	TBMap.Probe.Start("cover.ray")
	local hit, startSolid, distance = TBMap.Trace.Ray(cx, cy, cz, dx, dy, dz, reach)
	TBMap.Probe.Stop("cover.ray")

	if hit and (startSolid or distance >= (bias or 0)) then
		-- A brush further back could cover the grid where this one does not, which is a classification missed
		-- rather than a wrong one: the answer falls through to mixed.
		local rx, ry, rz = cx + dx * distance, cy + dy * distance, cz + dz * distance

		TBMap.Probe.Start("cover.near")
		local near, count = TBMap.Brushes.Near(Vector(rx, ry, rz), Vector(rx, ry, rz))
		TBMap.Probe.Stop("cover.near")

		local list = TBMap.Brushes.list

		local floor = bias or 0

		for i = 1, count do
			-- Every sample has to meet this brush no closer than the bias, and no other brush may reach the
			-- grid at all: without the second, a brush inside the bias window makes the trace call a sample
			-- lit while a clip against this one calls it blocked. The cheap half runs first.
			TBMap.Probe.Start("cover.covers")
			local covers = CoversGrid(list[near[i]].planes, s, cols, rows, stride, dx, dy, dz, floor)
			TBMap.Probe.Stop("cover.covers")

			if covers then
				TBMap.Probe.Start("cover.suspects")
				local suspects = Suspects(s, points, u0, u1, v0, v1, dx, dy, dz)
				TBMap.Probe.Stop("cover.suspects")

				if suspects == 1 and suspectIndices[1] == near[i] then
					return "dark"
				end
			end
		end

		return "mixed"
	end

	-- Nothing in the way from the middle, so the only answer left is that nothing is in the way anywhere:
	-- a brush covering the whole grid would have been met by the centre ray. An empty suspect set is the
	-- whole argument.
	TBMap.Probe.Start("cover.suspects")
	local suspects = Suspects(s, points, u0, u1, v0, v1, dx, dy, dz)
	TBMap.Probe.Stop("cover.suspects")

	if suspects == 0 then return "lit" end

	return "mixed"
end
