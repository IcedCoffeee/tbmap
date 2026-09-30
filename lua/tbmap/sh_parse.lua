-- Parsers for the map files the build reads: TrenchBroom .map (Valve 220 and standard face formats) and
-- Valve Map Format. Both produce the same entities, brushes and faces the rest of the build works from.
--
-- The .map form is line based, since TrenchBroom writes one face per line: a Valve 220 face carries its
-- axes in brackets and a standard one only offsets and a rotation.

TBMap = TBMap or {}

local function ParseTriple(s)
	local x, y, z = s:match("^%(%s*([^%s%)]+)%s+([^%s%)]+)%s+([^%s%)]+)%s*%)$")
	if not x then return nil end

	return Vector(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
end

local function ParseAxis(s)
	-- Trailing space allowed: the capture this is handed comes from between brackets, and the one
	-- before the closing bracket comes with it.
	local a, b, c, offset = s:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*$")
	if not a then return nil, 0 end

	return Vector(tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0), tonumber(offset) or 0
end

local function ParseFace(line)
	local a, b, c, rest = line:match("^(%b())%s*(%b())%s*(%b())%s*(.-)%s*$")
	if not a then return nil end

	local p1, p2, p3 = ParseTriple(a), ParseTriple(b), ParseTriple(c)
	if not (p1 and p2 and p3) then return nil end

	local face = { p1 = p1, p2 = p2, p3 = p3 }

	-- [^%]]+ rather than .- between the bracket characters: the lazy form backtracks through the whole
	-- rest of the line looking for the shortest match, and this is per face.
	local name, u, v, rot, sx, sy =
		rest:match("^(%S+)%s*%[%s*([^%]]+)%]%s*%[%s*([^%]]+)%]%s*(%S+)%s*(%S+)%s*(%S+)")

	if name then
		face.texture = name
		face.uaxis, face.uoffset = ParseAxis(u)
		face.vaxis, face.voffset = ParseAxis(v)
		face.rotation = tonumber(rot) or 0
		face.xscale = tonumber(sx) or 1
		face.yscale = tonumber(sy) or 1
	else
		local n, xoff, yoff, r, xs, ys =
			rest:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$")
		if not n then return nil end

		face.texture = n
		face.offsetU, face.offsetV = tonumber(xoff) or 0, tonumber(yoff) or 0
		face.rotation = tonumber(r) or 0
		face.xscale = tonumber(xs) or 1
		face.yscale = tonumber(ys) or 1
	end

	return face
end

-- =========================================================================
-- Valve Map Format
-- =========================================================================
--
-- VMF has no significance to whitespace: braces, quoted strings and keys are the whole structure, so it is
-- walked as tokens rather than lines, and a block written on a single line reads the same as one spread
-- over many. Only the blocks the build needs are opened; anything else, displacements included, is skipped
-- by its own braces.

-- A quoted value, with the escapes an entity's own text can carry.
local function VMFString(text, at)
	local s, e = text:find('^"([^"\\]*)"', at)
	if s then return text:sub(s + 1, e - 1), e + 1 end

	local parts = {}
	at = at + 1

	while at <= #text do
		local c = text:sub(at, at)

		if c == "\\" then
			parts[#parts + 1] = text:sub(at + 1, at + 1)
			at = at + 2
		elseif c == '"' then
			return table.concat(parts), at + 1
		else
			parts[#parts + 1] = c
			at = at + 1
		end
	end

	return nil, at
end

local function VMFReader(text)
	local at = 1
	local length = #text

	local function Skip()
		while at <= length do
			local c = text:sub(at, at)

			if c:match("%s") then
				local _, finish = text:find("^%s+", at)
				at = finish + 1
			elseif text:sub(at, at + 1) == "//" then
				at = (text:find("\n", at, true) or length) + 1
			else
				return
			end
		end
	end

	return function()
		Skip()
		if at > length then return "eof" end

		local c = text:sub(at, at)

		if c == "{" or c == "}" then
			at = at + 1
			return c
		end

		if c == '"' then
			local value, nextAt = VMFString(text, at)
			at = nextAt or length + 1

			return "string", value
		end

		local s, e = text:find("^[^%s{}]+", at)
		if not s then
			at = length + 1
			return "eof"
		end

		at = e + 1
		return "ident", text:sub(s, e)
	end
end

-- A VMF axis is the same bracket triple a Valve 220 face carries, with the axis' scale written after it,
-- which is the field a 220 face writes separately.
local function ParseVMFAxis(value)
	local body, scale = value:match("^%[%s*(.-)%s*%]%s*(%S*)$")
	if not body then return nil, 0, 1 end

	local axis, offset = ParseAxis(body)
	return axis, offset, tonumber(scale) or 1
end

-- Displacements are read as the flat base face a displaced side is built on, since doing more means
-- tessellating the patch, and the count comes back so the build can say what it did. Instances live in
-- other files and are likewise skipped.
function TBMap.ParseVMF(text)
	local nextToken = VMFReader(text)
	local entities = {}
	local stack, pending = {}, nil
	local entity, brush, face
	local displaced = 0

	local function Open(name)
		local parent = stack[#stack]
		stack[#stack + 1] = name

		if (name == "world" or name == "entity") and not parent then
			entity = { properties = {}, brushes = {} }
		elseif name == "solid" and (parent == "world" or parent == "entity") then
			brush = { faces = {} }
		elseif name == "side" and parent == "solid" then
			face = {}
		elseif name == "dispinfo" and parent == "side" then
			displaced = displaced + 1
		end
	end

	local function Close()
		local name = table.remove(stack)

		if name == "side" then
			if face and brush and face.p1 and face.p2 and face.p3 then
				brush.faces[#brush.faces + 1] = face
			end

			face = nil
		elseif name == "solid" then
			if brush and entity then entity.brushes[#entity.brushes + 1] = brush end

			brush = nil
		elseif name == "world" or name == "entity" then
			if entity then entities[#entities + 1] = entity end

			entity = nil
		end
	end

	local function Assign(key, value)
		local block = stack[#stack]

		if block == "side" and face then
			if key == "plane" then
				local a, b, c = value:match("^(%b())%s*(%b())%s*(%b())$")

				if a then face.p1, face.p2, face.p3 = ParseTriple(a), ParseTriple(b), ParseTriple(c) end
			elseif key == "material" then
				face.texture = value
			elseif key == "uaxis" then
				face.uaxis, face.uoffset, face.xscale = ParseVMFAxis(value)
			elseif key == "vaxis" then
				face.vaxis, face.voffset, face.yscale = ParseVMFAxis(value)
			elseif key == "rotation" then
				face.rotation = tonumber(value) or 0
			elseif key == "xscale" then
				face.xscale = tonumber(value) or 1
			elseif key == "yscale" then
				face.yscale = tonumber(value) or 1
			end
		elseif (block == "world" or block == "entity") and entity then
			entity.properties[key] = value
		end
	end

	while true do
		local kind, value = nextToken()

		if kind == "eof" then
			break
		elseif kind == "{" then
			Open(pending or "")
			pending = nil
		elseif kind == "}" then
			Close()
			pending = nil
		elseif kind == "ident" then
			pending = value
		else
			local nextKind, nextValue = nextToken()

			if nextKind == "string" then
				Assign(value, nextValue)
			else
				-- A block name in quotes, as the displacement grids write theirs.
				pending = value

				if nextKind == "{" then
					Open(pending)
					pending = nil
				end
			end
		end
	end

	return entities, displaced
end

function TBMap.ParseMap(text)
	text = text:gsub("\r", "")

	-- VMF opens with versioninfo, and a file without one still names the world block before anything else.
	local head = text:sub(1, 256)

	if head:find("^%s*versioninfo") or head:find("world%s*{") then
		return TBMap.ParseVMF(text)
	end

	local entities, entity, brush = {}, nil, nil

	-- Lines by iterator rather than split into a table first: a map is tens of thousands of lines and the
	-- table of them is the largest thing the parse would allocate. Trimming goes by byte before it goes by
	-- pattern, and the tests are on the first byte, since most lines are a face line and have nothing to
	-- trim or test at either end.
	for raw in text:gmatch("[^\n]*") do
		local head, tail = raw:byte(1), raw:byte(-1)
		local line = raw

		if head == 32 or head == 9 or tail == 32 or tail == 9 or tail == 13 then
			line = raw:match("^%s*(.-)%s*$") or ""
		end

		local first = line:byte(1)

		if first == 123 and #line == 1 then
			if entity then
				brush = { faces = {} }
			else
				entity = { properties = {}, brushes = {} }
			end

		elseif first == 125 and #line == 1 then
			if brush then
				table.insert(entity.brushes, brush)
				brush = nil
			elseif entity then
				table.insert(entities, entity)
				entity = nil
			end

		elseif first == 34 then
			local key, value = line:match('^"(.-)"%s*"(.-)"')
			if key and entity then entity.properties[key] = value end

		elseif first == 40 and brush then
			TBMap.Probe.Start("parse.face")
			local face = ParseFace(line)
			TBMap.Probe.Stop("parse.face")

			if face then table.insert(brush.faces, face) end
		end
	end

	return entities
end
