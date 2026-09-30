-- The brush as a solid, from the .map side: the planes its faces name, the convex hull they bound, and
-- the points the collision is built from. Shared by both realms.

TBMap = TBMap or {}

local function PlaneOf(face)
	-- TrenchBroom orients the plane by the point order, with the brush on the negative side.
	local n = (face.p3 - face.p1):Cross(face.p2 - face.p1)

	local len = n:Length()
	if len < 1e-6 then return nil end
	n = n / len

	return { n = n, d = n:Dot(face.p1), face = face, nx = n.x, ny = n.y, nz = n.z }
end

function TBMap.PlanesFromBrush(brush)
	local planes = {}
	for _, face in ipairs(brush.faces) do
		local plane = PlaneOf(face)
		if plane then table.insert(planes, plane) end
	end
	return planes
end

-- The 3x3 system of three planes, by Cramer's rule.
local function Intersect3(a, b, c)
	local a1, a2, a3, ad = a.nx, a.ny, a.nz, a.d
	local b1, b2, b3, bd = b.nx, b.ny, b.nz, b.d
	local c1, c2, c3, cd = c.nx, c.ny, c.nz, c.d

	local x1, y1, z1 = b2 * c3 - b3 * c2, b3 * c1 - b1 * c3, b1 * c2 - b2 * c1
	local x2, y2, z2 = c2 * a3 - c3 * a2, c3 * a1 - c1 * a3, c1 * a2 - c2 * a1
	local x3, y3, z3 = a2 * b3 - a3 * b2, a3 * b1 - a1 * b3, a1 * b2 - a2 * b1

	local denom = a1 * x1 + a2 * y1 + a3 * z1
	if math.abs(denom) < 1e-6 then return nil end

	local inv = 1 / denom

	return (x1 * ad + x2 * bd + x3 * cd) * inv,
		(y1 * ad + y2 * bd + y3 * cd) * inv,
		(z1 * ad + z2 * bd + z3 * cd) * inv
end

function TBMap.BuildBrush(planes, eps)
	eps = eps or TBMap.Config.GeometryTolerance

	local unique = {}
	for _, plane in ipairs(planes) do
		local duplicate = false
		for _, other in ipairs(unique) do
			if plane.n:Dot(other.n) > 0.9999 and math.abs(plane.d - other.d) < eps then
				duplicate = true
				break
			end
		end
		if not duplicate then table.insert(unique, plane) end
	end

	local count = #unique
	if count < 4 then return nil end

	local vertices, seen = {}, {}
	for i = 1, count - 2 do
		local a = unique[i]

		for j = i + 1, count - 1 do
			local b = unique[j]

			for k = j + 1, count do
				local px, py, pz = Intersect3(a, b, unique[k])
				if px then
					local inside = true

					for m = 1, count do
						local p = unique[m]

						if p.nx * px + p.ny * py + p.nz * pz > p.d + eps then
							inside = false
							break
						end
					end

					if inside then
						local key = string.format("%.3f %.3f %.3f", px, py, pz)
						if not seen[key] then
							seen[key] = true
							table.insert(vertices, Vector(px, py, pz))
						end
					end
				end
			end
		end
	end

	if #vertices < 4 then return nil end

	local faces = {}
	for _, plane in ipairs(unique) do
		local onPlane = {}
		for _, v in ipairs(vertices) do
			if math.abs(plane.nx * v.x + plane.ny * v.y + plane.nz * v.z - plane.d) <= eps then
				table.insert(onPlane, v)
			end
		end

		if #onPlane >= 3 then
			local cx, cy, cz = 0, 0, 0
			for _, v in ipairs(onPlane) do cx, cy, cz = cx + v.x, cy + v.y, cz + v.z end
			cx, cy, cz = cx / #onPlane, cy / #onPlane, cz / #onPlane

			local t1, t2 = TBMap.Sample.Basis(plane.n)
			local t1x, t1y, t1z = t1.x, t1.y, t1.z
			local t2x, t2y, t2z = t2.x, t2.y, t2.z
			local ordered = {}

			for _, v in ipairs(onPlane) do
				local dx, dy, dz = v.x - cx, v.y - cy, v.z - cz

				table.insert(ordered, {
					v = v,
					angle = math.atan2(dx * t2x + dy * t2y + dz * t2z, dx * t1x + dy * t1y + dz * t1z),
				})
			end
			table.sort(ordered, function(a, b) return a.angle < b.angle end)

			local poly = {}
			for _, entry in ipairs(ordered) do table.insert(poly, entry.v) end

			table.insert(faces, { normal = plane.n, poly = poly, face = plane.face })
		end
	end

	return { vertices = vertices, faces = faces }
end

-- One flat brush would fail the whole multi convex call, so they are filtered out here.
function TBMap.IsSolid(points, eps)
	eps = eps or TBMap.Config.GeometryTolerance
	if #points < 4 then return false end

	local mins, maxs = TBMap.PolyBox(points)

	return (maxs.x - mins.x) > eps and (maxs.y - mins.y) > eps and (maxs.z - mins.z) > eps
end

-- Convexes bucketed into cells of this size by the centre of each one's box, so no single physics
-- object carries a whole map. Both realms bucket identically, and an entity is matched to a bucket by
-- its index in this list, so the order is settled by sorting the keys. The second return maps the
-- input index of each convex to the bucket it landed in.
function TBMap.ChunkConvexes(convexes, size)
	size = math.max(size, 1)

	local buckets, order = {}, {}

	for index, points in ipairs(convexes) do
		TBMap.Bake.Slice()

		local mins, maxs = TBMap.PolyBox(points)

		local key = math.floor((mins.x + maxs.x) * 0.5 / size) .. "," ..
			math.floor((mins.y + maxs.y) * 0.5 / size) .. "," ..
			math.floor((mins.z + maxs.z) * 0.5 / size)

		local bucket = buckets[key]

		if not bucket then
			bucket = { convexes = {}, indexOf = {} }
			buckets[key] = bucket
			order[#order + 1] = key
		end

		bucket.convexes[#bucket.convexes + 1] = points
		bucket.indexOf[#bucket.indexOf + 1] = index
	end

	table.sort(order)

	local chunks, bucketOf = {}, {}

	for i = 1, #order do
		local bucket = buckets[order[i]]
		chunks[i] = bucket.convexes

		for _, index in ipairs(bucket.indexOf) do
			bucketOf[index] = i
		end
	end

	return chunks, bucketOf
end

-- For standard format maps: no axis vectors, so project along the dominant world axis the way the
-- original Quake compilers do, then turn that frame by the face's rotation. The Valve 220 maps that do
-- not use this path carry the rotation in their axes instead.
local PARAXIAL = {
	[1]  = { Vector(0, -1, 0), Vector(0, 0, -1) }, -- +X
	[-1] = { Vector(0, 1, 0),  Vector(0, 0, -1) }, -- -X
	[2]  = { Vector(1, 0, 0),  Vector(0, 0, -1) }, -- +Y
	[-2] = { Vector(1, 0, 0),  Vector(0, 0, -1) }, -- -Y
	[3]  = { Vector(1, 0, 0),  Vector(0, -1, 0) }, -- +Z
	[-3] = { Vector(1, 0, 0),  Vector(0, -1, 0) }, -- -Z
}

function TBMap.AxesFromNormal(n, rotation)
	local ax, ay, az = math.abs(n.x), math.abs(n.y), math.abs(n.z)

	local key
	if ax >= ay and ax >= az then
		key = n.x >= 0 and 1 or -1
	elseif ay >= az then
		key = n.y >= 0 and 2 or -2
	else
		key = n.z >= 0 and 3 or -3
	end

	local axes = PARAXIAL[key]
	local u, v = axes[1], axes[2]

	if rotation and rotation ~= 0 then
		local angle = math.rad(rotation)
		local c, s = math.cos(angle), math.sin(angle)

		-- The texture frame turned about the face, which is what the format means when the axes are not
		-- written out. The offsets ride the turned axes, so dropping it misplaces them as well as the grain.
		u, v = u * c - v * s, u * s + v * c
	end

	return u, v
end

-- UVs from the Valve 220 axes, with the rotation field left out because TrenchBroom bakes it into
-- the axis vectors on export. Reads the resolved material's size, so it only runs on the client.
-- Every face on the wire carries its axes, from the map or from AxesFromNormal.
function TBMap.ComputeUV(face, pos, texW, texH)
	local ua, va = face.uaxis, face.vaxis

	local sx = face.xscale
	if not sx or sx == 0 then sx = 1 end
	local sy = face.yscale
	if not sy or sy == 0 then sy = 1 end

	return pos:Dot(ua) / (texW * sx) + (face.uoffset or 0) / texW,
		pos:Dot(va) / (texH * sy) + (face.voffset or 0) / texH
end

