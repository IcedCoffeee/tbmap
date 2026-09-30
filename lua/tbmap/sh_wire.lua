-- Wire format for streaming finished brush faces to clients.
--
--   "TBMB12" <materialCount> { <nameLen> <name> } <wholeFaceCount>
--   { <matIndex> <ori> <brushIndex> <tag> <vertCount>
--       <nx> <ny> <nz> <ux> <uy> <uz> <uoffset> <vx> <vy> <vz> <voffset> <xscale> <yscale>
--       { <x> <y> <z> } }
--   <pieceCount>
--   { <sourceIndex> <tag> <vertCount> { <u16 u> <u16 v> } { <x> <y> <z> } }
--   <lightCount> { <kind> <x> <y> <z> <dx> <dy> <dz> <r> <g> <b>
--       <brightness> <radius> <cosOuter> <cosInner> <ar> <ag> <ab> }
--   <skyBrushCount> { <pointCount> { <x> <y> <z> } }
--   <clipBrushCount> { <pointCount> { <x> <y> <z> } }
--   <seeThroughBrushCount> { <brushIndex> }
--
-- Numbers are four bytes, little endian, and every coordinate or float is fixed point at one ten
-- thousandth. The vertex count of a face and the light kind are one byte.
--
-- The whole faces come first, for collision and the tracer's brush hulls: a list with the covered parts
-- removed leaves a wall standing on a floor missing the plane of its own underside, and the tracer would
-- light the room through it. The pieces follow, each naming the whole face it came from and sharing
-- every field with it but its polygon, which is the only part the clip can change.
--
-- Geometry only, no triangles and no texture coordinates, the latter because those need the resolved
-- material's texture size, which the server cannot be trusted to have.
--
-- The magic is bumped when the layout below changes, since a binary stream handed to the wrong
-- parser reads counts out of coordinates rather than failing.
--
-- The composed light: one record per face, self describing, so a reader walks it from what it is told
-- and neither side has to agree with the other about which faces exist. Sheets are numbers here, since
-- a server has nothing to draw them into.
--
--   "TBLK2" <blockCount>
--   { <tag> <sheet> <x> <y> <width> <height> <uvCount> { <u> <v> } <form>
--       [<ambR> <ambG> <ambB> <sunR> <sunG> <sunB>] <byteCount> <bytes> }
--
-- Form 0 is one colour for the whole rectangle, 1 is a byte of sun visibility per texel with the two
-- colours it blends between, 3 adds a second plane of the crease shade multiplied over that blend, and
-- 2 is three bytes per texel of the composed colour. 0, 1 and 3 are exact, and between them they cover
-- every face that has no lamp in reach, which is where the payload comes down.

TBMap = TBMap or {}

-- The list each wire number is an index into, and the reverse lookup derived from it, so the two
-- realms cannot disagree about what a number means.
local ORIENTATIONS = { "floor", "wall", "ceiling" }
local LIGHT_KINDS = { "point", "spot", "sun" }

local orientationNumber = {}
for index, name in ipairs(ORIENTATIONS) do orientationNumber[name] = index - 1 end

local lightKindNumber = {}
for index, name in ipairs(LIGHT_KINDS) do lightKindNumber[name] = index - 1 end

TBMap.Wire = {
	Magic = "TBMB12",
	LightMagic = "TBLK2",
	StreamMagic = "TBML2",
	Orientations = ORIENTATIONS,
	OrientationNumber = orientationNumber,
	LightKinds = LIGHT_KINDS,
	LightKindNumber = lightKindNumber,
}

local function HasMagic(data, magic)
	return type(data) == "string" and string.sub(data, 1, #magic) == magic
end

-- The payload and the lighting go as one transfer, with the payload's length in a prefix: two
-- transfers have no ordering against each other, and the client would act on the map before the
-- lighting arrived.
function TBMap.Wire.Pack(payload, light)
	return string.format("%s%08x%s%s", TBMap.Wire.StreamMagic, #payload, payload, light or "")
end

function TBMap.Wire.Unpack(data)
	local magic = TBMap.Wire.StreamMagic
	local start = #magic + 9

	if #data < start - 1 or string.sub(data, 1, #magic) ~= magic then return nil end

	local length = tonumber(string.sub(data, #magic + 1, #magic + 8), 16)
	if not length then return nil end

	return string.sub(data, start, start + length - 1), string.sub(data, start + length)
end

-- The bytes both formats above are read and written with. Lua's % is floored, so the unsigned form is
-- two's complement for negatives without a branch.
local function Writer(magic)
	local out, bytes, pending = { magic }, {}, 0

	local function Flush()
		if pending == 0 then return end

		out[#out + 1] = string.char(unpack(bytes, 1, pending))
		pending = 0
	end

	local function Byte(value)
		pending = pending + 1
		bytes[pending] = value

		if pending == 64 then Flush() end
	end

	local function UInt(value)
		local v = value % 4294967296

		Byte(v % 256)
		Byte(math.floor(v / 256) % 256)
		Byte(math.floor(v / 65536) % 256)
		Byte(math.floor(v / 16777216) % 256)
	end

	local function Fixed(value)
		UInt(math.floor(value * 10000 + 0.5))
	end

	-- Two bytes for a value that fits, which is what a piece's corner on its face's lattice is: a texel
	-- count within an atlas sheet, in sixteenths.
	local function UShort(value)
		local v = value % 65536

		Byte(v % 256)
		Byte(math.floor(v / 256) % 256)
	end

	local function Str(text)
		Flush()
		UInt(#text)
		Flush()

		out[#out + 1] = text
	end

	local function Finish()
		Flush()

		return table.concat(out)
	end

	return { byte = Byte, uint = UInt, ushort = UShort, fixed = Fixed, str = Str, finish = Finish }
end

local function Reader(data, magic)
	local at = #magic + 1
	local length = #data

	local function Byte()
		at = at + 1
		return string.byte(data, at - 1)
	end

	local function UInt()
		local b1, b2, b3, b4 = string.byte(data, at, at + 3)
		at = at + 4

		if not b4 then return nil end

		return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	end

	-- Back to signed, which is what the coordinates on the wire mean. Zero rather than nil on a short
	-- read, so a truncated stream does not error on arithmetic before the end of stream check reports
	-- it.
	local function Int()
		local v = UInt()
		if not v then return 0 end
		if v >= 2147483648 then v = v - 4294967296 end

		return v
	end

	local function Fixed()
		return Int() / 10000
	end

	local function UShort()
		local b1, b2 = string.byte(data, at, at + 1)
		at = at + 2

		if not b2 then return 0 end

		return b1 + b2 * 256
	end

	local function Str()
		local size = UInt()
		if not size or at + size - 1 > length then return nil end

		local text = string.sub(data, at, at + size - 1)
		at = at + size

		return text
	end

	return { byte = Byte, uint = UInt, ushort = UShort, fixed = Fixed, str = Str,
		done = function() return at == length + 1 end,
		position = function() return at end }
end

function TBMap.LightEncodeBlocks(blocks)
	local w = Writer(TBMap.Wire.LightMagic)

	w.uint(#blocks)

	for _, block in ipairs(blocks) do
		w.uint(block.tag)
		w.uint(block.sheet)
		w.uint(block.x)
		w.uint(block.y)
		w.uint(block.width)
		w.uint(block.height)
		w.uint(#block.uvs)

		for _, uv in ipairs(block.uvs) do
			w.fixed(uv[1])
			w.fixed(uv[2])
		end

		w.uint(block.form or 2)

		if block.mix then
			for i = 1, 6 do w.fixed(block.mix[i]) end
		end

		w.str(block.texels)
	end

	return w.finish()
end

function TBMap.LightDecodeBlocks(data)
	if not HasMagic(data, TBMap.Wire.LightMagic) then return nil end

	local r = Reader(data, TBMap.Wire.LightMagic)
	local count = r.uint() or 0
	local blocks, byTag = {}, {}

	for i = 1, count do
		local block = {
			tag = r.uint(),
			sheet = r.uint(),
			x = r.uint(),
			y = r.uint(),
			width = r.uint(),
			height = r.uint(),
		}

		local uvCount = r.uint() or 0
		local uvs = {}

		for c = 1, uvCount do uvs[c] = { r.fixed(), r.fixed() } end
		block.uvs = uvs

		local form = r.uint() or 2
		block.form = form

		if form == 1 or form == 3 then
			local mix = {}

			for m = 1, 6 do mix[m] = r.fixed() end
			block.mix = mix
		end

		block.texels = r.str()

		blocks[i] = block
		byTag[block.tag] = block
	end

	return blocks, byTag
end

-- materials: array of names. faces: array of
-- { mat, normal, poly, uaxis, vaxis, uoffset, voffset, xscale, yscale }
function TBMap.WireEncode(materials, faces, collisionFaces, lights, skyConvexes, clipConvexes, seeThrough)
	local w = Writer(TBMap.Wire.Magic)

	local function Verts(poly)
		for _, v in ipairs(poly) do
			w.fixed(v.x)
			w.fixed(v.y)
			w.fixed(v.z)
		end
	end

	w.uint(#materials)

	for _, name in ipairs(materials) do
		w.str((tostring(name):gsub("%s", "_")))
	end

	w.uint(#collisionFaces)

	for _, face in ipairs(collisionFaces) do
		local ua, va = face.uaxis, face.vaxis

		w.uint(face.mat)
		w.byte(face.ori or 1)
		w.uint(face.brush or 0)

		-- Sent rather than derived: the geometry on the wire is rounded, and a float near a rounding
		-- boundary never matches on the far side.
		w.uint(TBMap.Bake.FaceTag(face))

		w.byte(#face.poly)

		w.fixed(face.normal.x)
		w.fixed(face.normal.y)
		w.fixed(face.normal.z)

		w.fixed(ua.x)
		w.fixed(ua.y)
		w.fixed(ua.z)
		w.fixed(face.uoffset or 0)

		w.fixed(va.x)
		w.fixed(va.y)
		w.fixed(va.z)
		w.fixed(face.voffset or 0)

		w.fixed(face.xscale or 1)
		w.fixed(face.yscale or 1)

		Verts(face.poly)
	end

	w.uint(#faces)

	-- Each piece names the whole face it was cut from and carries its corners' coordinates on that face's
	-- lattice: one lightmap is composed per whole face and the piece is a window into it. The rectangle's
	-- atlas position is only known at bake time, so these are texels from its own corner rather than
	-- texture coordinates.
	local cfg = TBMap.Config
	local unit = cfg.LightmapTexelSize
	local margin = math.max(cfg.AtlasPadding, 1)
	local sampleOf = {}

	for _, face in ipairs(faces) do
		local sourceIndex = face.tbSource or face.tbWhole or 0
		local whole = collisionFaces[sourceIndex] or face
		local s = sampleOf[whole]

		if not s then
			s = TBMap.Sample.Face(whole, unit, margin, cfg.AtlasSize)
			sampleOf[whole] = s
		end

		w.uint(sourceIndex)
		w.uint(TBMap.Bake.FaceTag(face))
		w.byte(#face.poly)

		local ox, oy, oz = s.origin.x, s.origin.y, s.origin.z
		local t1x, t1y, t1z = s.t1.x, s.t1.y, s.t1.z
		local t2x, t2y, t2z = s.t2.x, s.t2.y, s.t2.z

		-- Sixteenths of a texel from the rectangle's corner, two bytes each: the corner is a texel count
		-- within a sheet, and the precision of a fixed float is bytes the transfer does not need.
		for _, v in ipairs(face.poly) do
			local dx, dy, dz = v.x - ox, v.y - oy, v.z - oz

			w.ushort(math.floor(((dx * t1x + dy * t1y + dz * t1z - s.uStart) / s.unit + 1024) * 16 + 0.5))
			w.ushort(math.floor(((dx * t2x + dy * t2y + dz * t2z - s.vStart) / s.unit + 1024) * 16 + 0.5))
		end

		Verts(face.poly)
	end

	local function Convexes(list)
		list = list or {}

		w.uint(#list)

		for _, points in ipairs(list) do
			w.uint(#points)
			Verts(points)
		end
	end

	lights = lights or {}
	w.uint(#lights)

	for _, light in ipairs(lights) do
		local dir = light.dir or Vector(0, 0, 1)
		local ambient = light.ambient

		w.byte(lightKindNumber[light.kind] or 0)

		w.fixed(light.pos.x)
		w.fixed(light.pos.y)
		w.fixed(light.pos.z)

		w.fixed(dir.x)
		w.fixed(dir.y)
		w.fixed(dir.z)

		w.fixed(light.color.x)
		w.fixed(light.color.y)
		w.fixed(light.color.z)

		w.fixed(light.brightness or 1)
		w.fixed(light.radius or 512)
		w.fixed(light.cosOuter or 0)
		w.fixed(light.cosInner or 1)

		w.fixed(ambient and ambient.x or 0)
		w.fixed(ambient and ambient.y or 0)
		w.fixed(ambient and ambient.z or 0)
	end

	Convexes(skyConvexes)
	Convexes(clipConvexes)

	-- Sent rather than derived on the far side: whether a brush hides anything decides the clip, the cull,
	-- the tracer and the contact rule, and two realms reading material files can disagree.
	seeThrough = seeThrough or {}

	local indices = {}

	for index in pairs(seeThrough) do indices[#indices + 1] = index end

	table.sort(indices)
	w.uint(#indices)

	for _, index in ipairs(indices) do
		w.uint(index)
	end

	return w.finish()
end

function TBMap.WireDecode(data)
	if not HasMagic(data, TBMap.Wire.Magic) then
		print("[tbmap] streamed map is not the format this client expects: reload after the server")
		return nil
	end

	local r = Reader(data, TBMap.Wire.Magic)

	local materials = {}
	local materialCount = r.uint() or 0

	for m = 1, materialCount do
		local name = r.str()
		if not name then return nil end

		materials[m] = name
	end

	local function ReadWhole()
		local faces = {}
		local faceCount = r.uint() or 0

		for f = 1, faceCount do
			local face = {}

			face.mat = r.uint()
			face.ori = r.byte()
			face.brush = r.uint()
			face.tbWireTag = r.uint()

			local vertexCount = r.byte() or 0

			face.normal = Vector(r.fixed(), r.fixed(), r.fixed())

			face.uaxis = Vector(r.fixed(), r.fixed(), r.fixed())
			face.uoffset = r.fixed()

			face.vaxis = Vector(r.fixed(), r.fixed(), r.fixed())
			face.voffset = r.fixed()

			face.xscale = r.fixed()
			face.yscale = r.fixed()

			local poly = {}
			for v = 1, vertexCount do
				poly[v] = Vector(r.fixed(), r.fixed(), r.fixed())
			end
			face.poly = poly

			faces[f] = face
			TBMap.Bake.Slice()
		end

		return faces
	end

	-- A piece carries only what the clip changes, and is completed from the whole face it names.
	local function ReadPieces(whole)
		local faces = {}
		local faceCount = r.uint() or 0

		for f = 1, faceCount do
			local sourceIndex = r.uint() or 0
			local source = whole[sourceIndex] or {}
			local face = {
				mat = source.mat,
				ori = source.ori,
				brush = source.brush,
				normal = source.normal,
				uaxis = source.uaxis,
				uoffset = source.uoffset,
				vaxis = source.vaxis,
				voffset = source.voffset,
				xscale = source.xscale,
				yscale = source.yscale,
				tbSourceIndex = sourceIndex,
			}

			face.tbWireTag = r.uint()

			local vertexCount = r.byte() or 0
			local uvs = {}
			local poly = {}

			for v = 1, vertexCount do
				uvs[v] = { r.ushort() / 16 - 1024, r.ushort() / 16 - 1024 }
			end

			for v = 1, vertexCount do
				poly[v] = Vector(r.fixed(), r.fixed(), r.fixed())
			end

			face.poly = poly
			face.tbUvs = uvs

			faces[f] = face
			TBMap.Bake.Slice()
		end

		return faces
	end

	local collisionFaces = ReadWhole()
	local faces = ReadPieces(collisionFaces)

	local lights = {}
	local lightCount = r.uint() or 0

	for l = 1, lightCount do
		local kind = LIGHT_KINDS[(r.byte() or 0) + 1] or "point"
		local pos = Vector(r.fixed(), r.fixed(), r.fixed())
		local dir = Vector(r.fixed(), r.fixed(), r.fixed())
		local color = Vector(r.fixed(), r.fixed(), r.fixed())
		local brightness = r.fixed()
		local radius = r.fixed()
		local cosOuter = r.fixed()
		local cosInner = r.fixed()
		local ambientR, ambientG, ambientB = r.fixed(), r.fixed(), r.fixed()
		local ambient

		if ambientR ~= 0 or ambientG ~= 0 or ambientB ~= 0 then
			ambient = Vector(ambientR, ambientG, ambientB)
		end

		lights[l] = {
			kind = kind,
			pos = pos,
			dir = dir,
			color = color,
			brightness = brightness,
			radius = radius,
			cosOuter = cosOuter,
			cosInner = cosInner,
			ambient = ambient,
		}
	end

	local function ReadConvexes()
		local list = {}
		local count = r.uint() or 0

		for b = 1, count do
			local points = {}
			local pointCount = r.uint() or 0

			for p = 1, pointCount do
				points[p] = Vector(r.fixed(), r.fixed(), r.fixed())
			end

			list[b] = points
		end

		return list
	end

	local skyConvexes = ReadConvexes()
	local clipConvexes = ReadConvexes()

	local seeThrough = {}
	local seeThroughCount = r.uint() or 0

	for i = 1, seeThroughCount do
		seeThrough[r.uint() or 0] = true
	end

	-- A field added to one side and not the other is the mistake worth catching, and here it is exact.
	if not r.done() then
		print(string.format("[tbmap] wire format drift: stopped %d bytes into %d",
			r.position() - 1, #data))
		return nil
	end

	return { materials = materials, faces = faces, collisionFaces = collisionFaces, lights = lights,
		skyConvexes = skyConvexes, clipConvexes = clipConvexes, seeThrough = seeThrough }
end
