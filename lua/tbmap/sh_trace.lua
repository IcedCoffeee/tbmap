-- Shadow tracer.
--
-- The engine's trace costs the same whether a ray is short or long, so this walks the brushes instead:
-- a uniform grid, each brush bucketed into the cells its box overlaps, a cell by cell walk and a plane
-- clip. It satisfies the contract of the engine trace in sh_bake.

TBMap = TBMap or {}

TBMap.Trace = { grid = { cell = 1, ox = 0, oy = 0, oz = 0, nx = 0, ny = 0, nz = 0, cells = {} } }

function TBMap.Trace.Build()
	TBMap.Probe.Start("grid")

	local grid = TBMap.Trace.grid
	local list = TBMap.Brushes.list

	if not list[1] then
		grid.cell = 1
		grid.nx, grid.ny, grid.nz = 0, 0, 0
		grid.cells = {}
		grid.occupied, grid.occupiedCount = {}, 0
		grid.insertions = 0
		TBMap.Probe.Stop("grid")
		return
	end

	-- The grid covers the brushes, since brushes are what it is there to find, and a brush's box is the
	-- map's own extent for anything the tracer asks. A query outside it still answers: the cell walk and
	-- the near query both clamp to the edge cell.
	local minx, miny, minz = list[1].minx, list[1].miny, list[1].minz
	local maxx, maxy, maxz = list[1].maxx, list[1].maxy, list[1].maxz

	for index = 2, #list do
		local brush = list[index]

		minx = math.min(minx, brush.minx)
		miny = math.min(miny, brush.miny)
		minz = math.min(minz, brush.minz)
		maxx = math.max(maxx, brush.maxx)
		maxy = math.max(maxy, brush.maxy)
		maxz = math.max(maxz, brush.maxz)
	end

	local spanX, spanY, spanZ = maxx - minx, maxy - miny, maxz - minz
	local longest = math.max(spanX, spanY, spanZ, 1)
	local cell = math.max(longest / math.max(TBMap.Config.TracerGridSize, 1), 16)

	grid.cell = cell
	grid.ox, grid.oy, grid.oz = minx, miny, minz
	grid.nx = math.max(math.ceil(spanX / cell), 1)
	grid.ny = math.max(math.ceil(spanY / cell), 1)
	grid.nz = math.max(math.ceil(spanZ / cell), 1)
	grid.cells = {}

	local nx, ny = grid.nx, grid.ny
	local insertions = 0

	for index, brush in ipairs(list) do
		TBMap.Bake.Slice()

		local x0 = math.max(math.floor((brush.mins.x - grid.ox) / cell), 0)
		local y0 = math.max(math.floor((brush.mins.y - grid.oy) / cell), 0)
		local z0 = math.max(math.floor((brush.mins.z - grid.oz) / cell), 0)
		local x1 = math.min(math.floor((brush.maxs.x - grid.ox) / cell), nx - 1)
		local y1 = math.min(math.floor((brush.maxs.y - grid.oy) / cell), ny - 1)
		local z1 = math.min(math.floor((brush.maxs.z - grid.oz) / cell), grid.nz - 1)

		for z = z0, z1 do
			for y = y0, y1 do
				for x = x0, x1 do
					local key = (z * ny + y) * nx + x + 1
					local list = grid.cells[key]

					if not list then
						list = {}
						grid.cells[key] = list
					end

					-- Light passes through a see-through brush as it does through sky and clip, so its hull is not
					-- bucketed: a pane left in the grid casts a shadow, which is a dark rectangle under it.
					if not brush.seeThrough then
						list[#list + 1] = index
						insertions = insertions + 1
					end
				end
			end
		end
	end

	-- The occupied cells as a flat list, so a query whose box is mostly empty can walk those instead.
	-- A sun face asks about the prism its shadow sweeps along the light, which is long and thin, and the
	-- box around it is far bigger than the brushes in it or the cells that hold them.
	local occupied, occupiedCount = {}, 0

	for key, cellList in pairs(grid.cells) do
		if #cellList > 0 then
			occupiedCount = occupiedCount + 1
			occupied[occupiedCount] = key - 1
		end
	end

	grid.occupied, grid.occupiedCount = occupied, occupiedCount
	grid.insertions = insertions

	TBMap.Probe.Stop("grid")
end

-- Walks the cells the ray passes through in order, stopping as soon as the nearest hit is closer than
-- the next cell boundary. The direction has to be normalised: the parameter is a distance in world
-- units.
local function Walk(fx, fy, fz, dx, dy, dz, length)
	local grid = TBMap.Trace.grid
	local cell = grid.cell
	local nx, ny, nz = grid.nx, grid.ny, grid.nz

	local ix = math.min(math.max(math.floor((fx - grid.ox) / cell), 0), nx - 1)
	local iy = math.min(math.max(math.floor((fy - grid.oy) / cell), 0), ny - 1)
	local iz = math.min(math.max(math.floor((fz - grid.oz) / cell), 0), nz - 1)

	local stepX = dx > 0 and 1 or (dx < 0 and -1 or 0)
	local stepY = dy > 0 and 1 or (dy < 0 and -1 or 0)
	local stepZ = dz > 0 and 1 or (dz < 0 and -1 or 0)

	local invX = stepX ~= 0 and 1 / dx or 0
	local invY = stepY ~= 0 and 1 / dy or 0
	local invZ = stepZ ~= 0 and 1 / dz or 0

	local deltaX = stepX ~= 0 and math.abs(cell * invX) or math.huge
	local deltaY = stepY ~= 0 and math.abs(cell * invY) or math.huge
	local deltaZ = stepZ ~= 0 and math.abs(cell * invZ) or math.huge

	local maxX = stepX ~= 0 and ((ix + (stepX > 0 and 1 or 0)) * cell + grid.ox - fx) * invX or math.huge
	local maxY = stepY ~= 0 and ((iy + (stepY > 0 and 1 or 0)) * cell + grid.oy - fy) * invY or math.huge
	local maxZ = stepZ ~= 0 and ((iz + (stepZ > 0 and 1 or 0)) * cell + grid.oz - fz) * invZ or math.huge

	-- Never nil: a miss is a distance beyond any ray, so this compare never sees two types.
	local best = math.huge

	while true do
		local list = grid.cells[(iz * ny + iy) * nx + ix + 1]

		if list then
			for i = 1, #list do
				-- Written out rather than called: a call the JIT will not inline is paid once per brush, in
				-- the innermost loop of the bake.
				--
				-- A convex brush is the intersection of its face planes, so the ray keeps the interval where
				-- it is inside all of them: tmin from the last plane to admit it, tmax from the first to
				-- reject it. An inverted interval is a miss. Four numbers per plane: nx, ny, nz, d.
				local planes = TBMap.Brushes.list[list[i]].planes
				local tmin, tmax = 0, length

				for p = 1, #planes, 4 do
					local pnx, pny, pnz, pd = planes[p], planes[p + 1], planes[p + 2], planes[p + 3]
					local num = pnx * fx + pny * fy + pnz * fz - pd
					local den = pnx * dx + pny * dy + pnz * dz

					if den > -1e-6 and den < 1e-6 then
						if num > 0 then tmin, tmax = 1, 0 end
					else
						-- Inside is f <= 0 for f(t) = num + den*t. Growing den means leaving the half space, so it
						-- clamps tmax; shrinking means entering, so it clamps tmin.
						local t = -num / den

						if den > 0 then
							if t < tmax then tmax = t end
						elseif t > tmin then
							tmin = t
						end
					end

					if tmin > tmax then break end
				end

				-- A brush the ray is only leaving is behind the origin: its interval ahead has no length,
				-- so a sample sitting on a surface it walks away from does not shadow itself. A brush the
				-- ray enters starts at the origin and has length ahead, which is a contact with a wall and
				-- has to read as shadow.
				if tmin <= tmax and tmax - tmin > 1e-3 and tmin < best then best = tmin end
			end
		end

		local next = math.min(maxX, maxY, maxZ)
		if best < next or next > length then break end

		if maxX <= maxY and maxX <= maxZ then
			ix = ix + stepX
			maxX = maxX + deltaX
		elseif maxY <= maxZ then
			iy = iy + stepY
			maxY = maxY + deltaY
		else
			iz = iz + stepZ
			maxZ = maxZ + deltaZ
		end

		if ix < 0 or ix >= nx or iy < 0 or iy >= ny or iz < 0 or iz >= nz then break end
	end

	return best
end

function TBMap.Trace.Ray(fx, fy, fz, dx, dy, dz, length)
	local grid = TBMap.Trace.grid
	if grid.nx == 0 then return false, false, 0 end

	local hit = Walk(fx, fy, fz, dx, dy, dz, length)
	if hit == math.huge then return false, false, 0 end

	return true, hit <= 1e-4, hit
end
