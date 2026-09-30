-- Geometry shared by the brush build, the collision, the tracer and the bake: the box around a point
-- list, and the face's own two dimensions, which the lightmap lattice is laid out in.

TBMap = TBMap or {}

function TBMap.PolyBox(poly)
	local first = poly[1]
	local minx, miny, minz = first.x, first.y, first.z
	local maxx, maxy, maxz = minx, miny, minz

	for i = 2, #poly do
		local v = poly[i]

		if v.x < minx then minx = v.x elseif v.x > maxx then maxx = v.x end
		if v.y < miny then miny = v.y elseif v.y > maxy then maxy = v.y end
		if v.z < minz then minz = v.z elseif v.z > maxz then maxz = v.z end
	end

	return Vector(minx, miny, minz), Vector(maxx, maxy, maxz)
end

-- =========================================================================
-- Sampling geometry
-- =========================================================================

TBMap.Sample = {}

function TBMap.Sample.Basis(normal)
	local ref = math.abs(normal.x) < 0.9 and Vector(1, 0, 0) or Vector(0, 1, 0)
	local t1 = (ref - normal * ref:Dot(normal)):GetNormalized()
	return t1, normal:Cross(t1)
end

-- Everything both sides have to agree on about one face, derived from the face and the density alone.
-- A face larger than an atlas gets a coarser density rather than not fitting.
function TBMap.Sample.Face(face, unit, margin, size)
	local poly, normal = face.poly, face.normal
	local t1, t2 = TBMap.Sample.Basis(normal)

	-- The point on the plane nearest the world origin, so two faces in one plane measure their dimensions
	-- from the same place and can share a grid below.
	local nx, ny, nz = normal.x, normal.y, normal.z
	local first = poly[1]
	local plane = nx * first.x + ny * first.y + nz * first.z
	local origin = Vector(nx * plane, ny * plane, nz * plane)

	local minU, maxU = math.huge, -math.huge
	local minV, maxV = math.huge, -math.huge

	for _, v in ipairs(poly) do
		local dx, dy, dz = v.x - origin.x, v.y - origin.y, v.z - origin.z
		local u = dx * t1.x + dy * t1.y + dz * t1.z
		local w = dx * t2.x + dy * t2.y + dz * t2.z

		minU, maxU = math.min(minU, u), math.max(maxU, u)
		minV, maxV = math.min(minV, w), math.max(maxV, w)
	end

	local faceUnit = unit
	local spanU, spanV = maxU - minU, maxV - minV

	-- One texel less than the interior holds: the anchored grid can start up to a texel before the
	-- margin.
	local limit = math.max(size - 2 * margin - 1, 1)

	if spanU / faceUnit > limit then faceUnit = spanU / limit end
	if spanV / faceUnit > limit then faceUnit = math.max(faceUnit, spanV / limit) end

	-- Anchored to the unit in that frame, so two faces in one plane land on the same world points where
	-- they meet. The sun's blur window reaches into the face next door, so separate phases would sample
	-- different points to answer for the same place, which is a step along the join.
	local uStart = math.floor((minU - margin * faceUnit) / faceUnit) * faceUnit
	local vStart = math.floor((minV - margin * faceUnit) / faceUnit) * faceUnit

	local cols = math.max(math.ceil((maxU - uStart) / faceUnit) - margin, 1)
	local rows = math.max(math.ceil((maxV - vStart) / faceUnit) - margin, 1)
	local width = cols + 2 * margin
	local height = rows + 2 * margin

	local lampStride = math.max(TBMap.Config.LampSampleSpacing, 1)
	return {
		face = face,
		normal = normal,
		t1 = t1,
		t2 = t2,
		origin = origin,
		unit = faceUnit,
		width = width,
		height = height,
		margin = margin,
		uStart = uStart,
		vStart = vStart,
		-- The face's own extent, so a sample can be kept on the surface: a grid over a face whose extent is
		-- not a whole number of texels has nodes past its edges.
		uMin = minU,
		uMax = maxU,
		vMin = minV,
		vMax = maxV,
		lampStride = lampStride,
		lampCols = math.floor((cols - 1) / lampStride) + 1,
		lampRows = math.floor((rows - 1) / lampStride) + 1,
	}
end

-- Where one sample of a grid sits, as texel coordinates.
function TBMap.Sample.NodeAxis(s, index, cols, stride)
	local gx = (index - 1) % cols
	local gy = math.floor((index - 1) / cols)
	local col = math.min(s.margin + gx * stride, s.width - 1 - s.margin)
	local row = math.min(s.margin + gy * stride, s.height - 1 - s.margin)

	return col, row
end

