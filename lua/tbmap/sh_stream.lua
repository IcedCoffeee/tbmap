-- Chunked transfer of a payload over several net messages.
--
-- The engine's net.WriteStream paces a stream at about one chunk per round trip, which is a few
-- hundred KB/s however much the net library can carry. This sends a full net message per chunk and
-- keeps several in flight, so a transfer is bounded by the far side's acknowledgement rate rather
-- than by the round trip time, and the window opens and closes around what the far side confirms.
--
-- Every chunk names its transfer and carries its own length and total, so it is self describing, and
-- the far side answers with the next index it wants. A receiver that no longer has the transfer
-- answers zero, which is the sender's cue to start again, so a level change or a code reload on
-- either side ends in a retry rather than in a transfer that never completes.

TBMap = TBMap or {}
TBMap.Stream = {}

-- Under the 65,533 byte net message ceiling, with the header and the message name to spare.
local CHUNK = 60000
-- Chunks in flight. One to start with, one more per acknowledgement, halved whenever the
-- acknowledgements stop: the shape the lighting bake paces itself with, for the same reason. The
-- ceiling is a bound on what can sit in the engine's reliable buffer, which is the thing that
-- overflows on a client whose own rate is low, and it is still a few MB/s at a few hundred ms.
local MIN_WINDOW, MAX_WINDOW = 1, 8
-- A client pushes one chunk at a time: the reliable stream a client may have outstanding is smaller
-- than a server's, and a window there is what overflows it. The size the window buys is in the
-- server's own sends, which are not bounded the same way.
local CLIENT_WINDOW = 1
-- No acknowledgement for this long with chunks outstanding means the far side is not keeping up, so
-- the window halves and what is unconfirmed is sent again.
local STALL = 2
-- Chunks released per tick, so a burst of acknowledgements does not become a burst on the wire.
local PER_TICK = 4
-- The engine's own stream waiter has a 64 MB ceiling. A transfer declared larger than that is
-- refused outright rather than assembled, which is also what keeps a socket that sends chunks
-- without ever completing them from growing this realm's memory without limit.
local MAX_TOTAL = 64 * 1024 * 1024

local transferID = 0
local sends, receives, registered = {}, {}, {}

local function NextID()
	transferID = transferID + 1

	return transferID
end

-- A client has one peer and a server has one per player, so its absence is the client's key.
local function Key(ply)
	return ply or false
end

local function SendChunk(transfer, index)
	local at = index * CHUNK + 1
	local chunk = string.sub(transfer.data, at, at + CHUNK - 1)

	net.Start(transfer.name)
	net.WriteUInt(transfer.id, 32)
	net.WriteUInt(index, 32)
	net.WriteUInt(#transfer.data, 32)
	net.WriteUInt(#chunk, 32)

	-- Only the first chunk carries the caller's own header, and it is always length prefixed, so a
	-- reader can walk the record without knowing what the caller put in it.
	if index == 0 then
		local header = transfer.header or ""

		net.WriteUInt(#header, 32)

		if #header > 0 then net.WriteData(header, #header) end
	end

	net.WriteData(chunk, #chunk)

	if transfer.target then
		net.Send(transfer.target)
	else
		net.SendToServer()
	end
end

local function SendAck(name, ply, id, wanted)
	net.Start(name .. "_ack")
	net.WriteUInt(id, 32)
	net.WriteUInt(wanted, 32)

	if ply then
		if IsValid(ply) then net.Send(ply) end
	else
		net.SendToServer()
	end
end

local function Complete(transfer)
	local list = sends[transfer.name]

	if list then list[Key(transfer.target)] = nil end

	if transfer.callback then transfer.callback(transfer.target) end
end

-- The next index the far side wants. Below what was already confirmed means it lost the transfer and
-- is asking for the start again.
local function OnAck(name, ply)
	local id = net.ReadUInt(32)
	local wanted = net.ReadUInt(32)
	local list = sends[name]
	local transfer = list and list[Key(ply)]

	if not transfer or transfer.id ~= id then return end

	transfer.lastAck = SysTime()

	if wanted == 0 then
		transfer.acked, transfer.sent, transfer.window = 0, 0, MIN_WINDOW
	elseif wanted > transfer.acked then
		transfer.acked = wanted
		transfer.window = math.min(transfer.window + 1, transfer.maxWindow)
	end

	if transfer.acked >= transfer.chunkCount then Complete(transfer) end
end

-- A sender still has to hear about acknowledgements, so the ack handler goes up for every name this
-- realm writes to, not only the ones it reads.
local function Register(name)
	if registered[name] then return end

	registered[name] = true

	if SERVER then
		util.AddNetworkString(name)
		util.AddNetworkString(name .. "_ack")
	end

	net.Receive(name .. "_ack", function(_, ply) OnAck(name, ply) end)
end

local function OnChunk(name, ply, callback)
	local id = net.ReadUInt(32)
	local index = net.ReadUInt(32)
	local total = net.ReadUInt(32)
	local length = net.ReadUInt(32)
	local header

	if index == 0 then
		local headerLength = net.ReadUInt(32)

		if headerLength > 0 then header = net.ReadData(headerLength) end
	end

	local chunk = net.ReadData(length)
	local list = receives[name]

	if not list then
		list = {}
		receives[name] = list
	end

	local transfer = list[Key(ply)]

	if transfer and transfer.refused then return end

	if not transfer or transfer.id ~= id then
		if index ~= 0 then
			-- Part way through something this realm no longer has: ask for the start again.
			SendAck(name, ply, id, 0)
			return
		end

		if total > MAX_TOTAL then
			-- Nothing is answered, so the far side is left waiting on a transfer this realm will never
			-- finish, which is the point: there is nothing here worth spending an answer on.
			list[Key(ply)] = { id = id, refused = true }
			return
		end

		transfer = { id = id, total = total, chunks = {}, next = 0,
			count = math.ceil(total / CHUNK), header = header }
		list[Key(ply)] = transfer
	elseif index < transfer.next then
		-- Confirmed already, which happens when a stalled sender sends it again. The answer still
		-- tells the sender where this realm is.
		SendAck(name, ply, id, transfer.next)
		return
	elseif index > transfer.next then
		return
	end

	transfer.chunks[index + 1] = chunk
	transfer.next = index + 1

	-- Every chunk is answered, the last one included: that answer is what tells the sender the
	-- transfer is done rather than stalled.
	SendAck(name, ply, id, transfer.next)

	if transfer.next >= transfer.count then
		list[Key(ply)] = nil
		callback(ply, transfer.header, table.concat(transfer.chunks))
	end
end

local function Drain()
	local now = SysTime()

	for _, list in pairs(sends) do
		for key, transfer in pairs(list) do
			if transfer.target and not IsValid(transfer.target) then
				list[key] = nil
			else
				if transfer.sent < transfer.chunkCount and now - transfer.lastAck > STALL then
					transfer.window = math.max(math.floor(transfer.window / 2), MIN_WINDOW)
					transfer.sent = transfer.acked
					transfer.lastAck = now
				end

				local sent = 0

				while transfer.sent < transfer.chunkCount
					and transfer.sent - transfer.acked < transfer.window
					and sent < PER_TICK do
					SendChunk(transfer, transfer.sent)

					transfer.sent = transfer.sent + 1
					sent = sent + 1
				end
			end
		end
	end
end

hook.Add("Think", "tbmap_stream", Drain)

-- Target is the player to send to, or nil to send to the server. Header is the caller's own first
-- message, delivered with the payload rather than before it, since a net message of its own would
-- have no ordering against the chunks.
function TBMap.Stream.Send(name, target, header, data, callback)
	if #data == 0 then return end
	if SERVER and not IsValid(target) then return end

	Register(name)

	local list = sends[name]

	if not list then
		list = {}
		sends[name] = list
	end

	list[Key(target)] = {
		name = name,
		target = target,
		header = header ~= "" and header or nil,
		data = data,
		chunkCount = math.ceil(#data / CHUNK),
		id = NextID(),
		acked = 0,
		sent = 0,
		window = MIN_WINDOW,
		maxWindow = target and MAX_WINDOW or CLIENT_WINDOW,
		lastAck = SysTime(),
		callback = callback,
	}
end

-- The callback runs on the receiving realm with the sender as its first argument, which is the
-- player on a server and nil on a client.
function TBMap.Stream.Receive(name, callback)
	Register(name)

	net.Receive(name, function(_, ply)
		OnChunk(name, ply, callback)
	end)
end
