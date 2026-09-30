-- Stored maps, flat under data/tbmap/, on both sides:
--
--   data/tbmap/<path>.map        placed by hand
--   data/tbmap/<path>.map.txt    written by a push, since .map is not on file.Write's whitelist
--
-- A path is relative to TBMap.Maps.Root and taken literally. Command feedback goes to the console
-- rather than chat or a toast, so it can be read back afterwards.

local cfg = TBMap.Config

TBMap = TBMap or {}
TBMap.Maps = TBMap.Maps or {}

TBMap.Maps.Root = "tbmap"
TBMap.Maps.State = "tbmap/editors.json"

-- Paths become filenames. Lowercase, because file.Write forces it anyway, and no colon or
-- traversal, because both are restricted one way or another.
function TBMap.Maps.Clean(path)
	path = tostring(path or ""):lower():gsub("%.map%.txt$", ""):gsub("%.map$", ""):gsub("%.vmf$", "")
		:gsub("[^%w_%-%./]", ""):gsub("/+", "/"):gsub("/$", "")

	if path == "" or #path > 96 or path:find("..", 1, true) or path:sub(1, 1) == "/" then return nil end

	-- A first segment naming an editor is rewritten to their SteamID64, so a map can be addressed by
	-- the name its owner set with tbmap_nick. Here rather than in each command, so every one gets it.
	local who, rest = path:match("^([^/]+)/(.+)$")

	if who and TBMap.Maps.Nicks then
		for id, nick in pairs(TBMap.Maps.Nicks) do
			if tostring(nick):lower() == who then return id .. "/" .. rest end
		end
	end

	return path
end

-- The file for a path, hand-placed first. The extension says how it arrived, not what is in it: a .map or
-- .vmf placed by hand, or the .txt a push writes because file.Write will not take the others.
function TBMap.Maps.Resolve(path)
	local base = TBMap.Maps.Root .. "/" .. path

	if file.Exists(base .. ".map", "DATA") then return base .. ".map" end
	if file.Exists(base .. ".vmf", "DATA") then return base .. ".vmf" end
	if file.Exists(base .. ".map.txt", "DATA") then return base .. ".map.txt" end

	return nil
end

function TBMap.Maps.Display(path)
	return (path:gsub("^" .. TBMap.Maps.Root .. "/", ""):gsub("%.map%.txt$", ""):gsub("%.map$", "")
		:gsub("%.vmf$", ""))
end

if SERVER then
	util.AddNetworkString("tbmap_map_request")

	TBMap.Maps.Nicks = {}
	TBMap.Maps.Pushed = {}

	local function LoadState()
		local text = file.Read(TBMap.Maps.State, "DATA")
		local decoded = text and util.JSONToTable(text)

		if decoded then
			TBMap.Maps.Nicks = decoded.nicks or {}
			TBMap.Maps.Pushed = decoded.pushed or {}

			-- A code reload re-runs the config file too, so without this reloading would quietly switch
			-- the server back to the default map.
			if decoded.active then cfg.StartupMap = decoded.active end
		end
	end

	local function SaveState()
		file.CreateDir("tbmap")
		file.Write(TBMap.Maps.State, util.TableToJSON({
			nicks = TBMap.Maps.Nicks,
			pushed = TBMap.Maps.Pushed,
			active = cfg.StartupMap,
		}, true))
	end

	LoadState()

	function TBMap.Maps.Nick(id)
		return TBMap.Maps.Nicks[id] or id
	end

	local function IsEditor(ply)
		if not IsValid(ply) then return false end
		if ply:IsSuperAdmin() then return true end

		for _, allowed in ipairs(cfg.AllowedEditors) do
			if tostring(allowed) == ply:SteamID64() then return true end
		end

		return false
	end

	local function Tell(ply, line)
		-- Both the caller's console and the server's, which is the only record on a dedicated server.
		print(line)

		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) end
	end

	TBMap.Stream.Receive("tbmap_map_push", function(ply, path, data)
		if not IsValid(ply) then return end

		if not IsEditor(ply) then
			Tell(ply, "[tbmap] you are not on the editors list")
			return
		end

		path = TBMap.Maps.Clean(path)

		if not path then return end

		if not data or data == "" then
			Tell(ply, "[tbmap] empty upload")
			return
		end

		if #data > cfg.MaxUploadKB * 1024 then
			Tell(ply, "[tbmap] too large to accept")
			return
		end

		-- Into the pusher's own folder, named by their SteamID64, so two editors never write the
		-- same file.
		local id = ply:SteamID64()
		local full = id .. "/" .. path
		local folder = full:match("^(.*)/[^/]+$")
		local target = TBMap.Maps.Root .. "/" .. full .. ".map.txt"

		if folder then file.CreateDir(TBMap.Maps.Root .. "/" .. folder) end
		file.Write(target, data)

		cfg.StartupMap = target
		cfg.SearchPath = "DATA"

		TBMap.Maps.Pushed[full] = { id = id, nick = TBMap.Maps.Nick(id), time = os.time() }
		SaveState()

		Tell(ply, string.format("[tbmap] pushed %s (%d KB), now the active map", full, #data / 1024))

		if TBMap.NoticeFileChanged then TBMap.NoticeFileChanged() end
	end)

	net.Receive("tbmap_map_request", function(_, ply)
		if not IsValid(ply) then return end
		if not IsEditor(ply) then
			Tell(ply, "[tbmap] you are not on the editors list")
			return
		end

		local path = TBMap.Maps.Clean(net.ReadString())
		local name = net.ReadString()

		if not path then return end

		local actual = TBMap.Maps.Resolve(path)
		local data = actual and file.Read(actual, "DATA")

		if not data then
			Tell(ply, "[tbmap] no map at " .. path)
			return
		end

		local target = name == "" and path or (TBMap.Maps.Clean(name) or path)

		TBMap.Stream.Send("tbmap_map_pull", ply, target, data)

		Tell(ply, string.format("[tbmap] sending %s (%d KB)", path, #data / 1024))
	end)

	-- GMod forwards an unregistered console command to the server with the caller in the callback, so
	-- anything touching only the server's files belongs here. A client command is only needed where
	-- the client's own disk is involved: tbmap_loadlocal and tbmap_pull.
	concommand.Add("tbmap_nick", function(ply, _, args)
		if not IsValid(ply) then return end

		local nick = tostring(args[1] or ""):gsub("[^%w_%- ]", ""):sub(1, 32)

		if nick == "" then
			Tell(ply, "[tbmap] usage: tbmap_nick <name>")
			return
		end

		TBMap.Maps.Nicks[ply:SteamID64()] = nick
		SaveState()

		Tell(ply, "[tbmap] nickname set to " .. nick)
	end)

	concommand.Add("tbmap_load", function(ply, _, args)
		if not IsEditor(ply) then
			Tell(ply, "[tbmap] you are not on the editors list")
			return
		end

		local path = TBMap.Maps.Clean(args[1])
		local actual = path and TBMap.Maps.Resolve(path)

		if not actual then
			Tell(ply, "[tbmap] no map at " .. tostring(args[1]))
			return
		end

		cfg.StartupMap = actual
		cfg.SearchPath = "DATA"
		SaveState()

		Tell(ply, string.format("[tbmap] loading %s", actual))

		if TBMap.NoticeFileChanged then TBMap.NoticeFileChanged() end
	end)

	concommand.Add("tbmap_list", function(ply, _, args)
		local folder = TBMap.Maps.Clean(args[1]) or ""
		local base = folder == "" and TBMap.Maps.Root or (TBMap.Maps.Root .. "/" .. folder)
		local lines = {}

		-- Walks the tree, since maps live in per-editor subfolders. The bake cache is skipped.
		local function Walk(at)
			local files, folders = file.Find(at .. "/*", "DATA")

			for _, name in ipairs(files or {}) do
				if name:find("%.map$") or name:find("%.map%.txt$") then
					local full = at .. "/" .. name
					local display = TBMap.Maps.Display(full)
					local pushed = TBMap.Maps.Pushed[display]
					local active = (cfg.StartupMap == full) and " [active]" or ""

					local by = pushed and (" last pushed by " ..
						tostring(TBMap.Maps.Nick(pushed.id or ""))) or ""

					lines[#lines + 1] = string.format("[tbmap] %s, %.0f KB%s%s",
						display, (file.Size(full, "DATA") or 0) / 1024, by, active)
				end
			end

			for _, name in ipairs(folders or {}) do
				if name ~= "cache" then Walk(at .. "/" .. name) end
			end
		end

		Walk(base)

		if #lines == 0 then lines[1] = "[tbmap] nothing under " .. base end

		for _, line in ipairs(lines) do Tell(ply, line) end
	end)

	concommand.Add("tbmap_delete", function(ply, _, args)
		if not IsEditor(ply) then
			Tell(ply, "[tbmap] you are not on the editors list")
			return
		end

		local path = TBMap.Maps.Clean(args[1])
		local actual = path and TBMap.Maps.Resolve(path)

		if not actual then
			Tell(ply, "[tbmap] no map at " .. tostring(args[1]))
			return
		end

		if cfg.StartupMap == actual then
			Tell(ply, "[tbmap] that map is active")
			return
		end

		file.Delete(actual)
		TBMap.Maps.Pushed[path] = nil
		SaveState()

		Tell(ply, "[tbmap] deleted " .. actual)
	end)
else
	-- The editing side. tbmap_loadlocal uploads the local file and then watches it, so every save
	-- pushes.

	local watching
	local stamp

	local function Stamp(actual)
		return tostring(file.Time(actual, "DATA")) .. ":" .. tostring(file.Size(actual, "DATA"))
	end

	-- Stats around the read: a save is not atomic and a file that changed while it was being read is
	-- a mixture of two versions. Skipping loses nothing, since a write overlapping the read is still
	-- going and the next poll picks up its end.
	local function Push(path)
		local actual = TBMap.Maps.Resolve(path)

		if not actual then
			print("[tbmap] nothing to push at " .. path)
			return
		end

		local before = Stamp(actual)
		local data = file.Read(actual, "DATA")

		if not data or data == "" then
			print("[tbmap] nothing to push at " .. path)
			return
		end

		if before ~= Stamp(actual) then
			print("[tbmap] " .. path .. " changed while reading it, waiting for the next change")
			return
		end

		TBMap.Stream.Send("tbmap_map_push", nil, path, data)

		print(string.format("[tbmap] pushed %s (%d KB)", path, #data / 1024))
	end

	timer.Create("tbmap_local_watch", 0.3, 0, function()
		if not watching then return end

		local actual = TBMap.Maps.Resolve(watching)
		local now = actual and Stamp(actual)

		if now and stamp and now ~= stamp then Push(watching) end

		stamp = now
	end)

	-- What the console offers for a half typed path: the folders and maps under the last segment of it,
	-- lowercased like Clean does, with a slash past a folder so the next segment can follow.
	local function MapCandidates(prefix)
		local folder, partial = prefix:match("^(.*/)([^/]*)$")

		if not folder then
			folder, partial = "", prefix
		end

		partial = partial:lower()

		local files, folders = file.Find(TBMap.Maps.Root .. "/" .. folder .. "*", "DATA")
		local seen, out = {}, {}

		for _, name in ipairs(folders or {}) do
			if name ~= "cache" and name:lower():sub(1, #partial) == partial then
				out[#out + 1] = folder .. name .. "/"
			end
		end

		for _, name in ipairs(files or {}) do
			local lower = name:lower()

			if lower:find("%.map$") or lower:find("%.map%.txt$") or lower:find("%.vmf$") then
				local clean = TBMap.Maps.Clean(name)

				if clean and clean:sub(1, #partial) == partial and not seen[clean] then
					seen[clean] = true
					out[#out + 1] = folder .. clean
				end
			end
		end

		table.sort(out)

		return out
	end

	-- Options are whole command lines, the command and the arguments before the one being typed included:
	-- that is what the console matches what has been typed against.
	concommand.Add("tbmap_loadlocal", function(_, _, args)
		local path = TBMap.Maps.Clean(args[1])

		if not path then
			print("[tbmap] usage: tbmap_loadlocal <path>")
			return
		end

		local actual = TBMap.Maps.Resolve(path)

		if not actual then
			print("[tbmap] no map at " .. TBMap.Maps.Root .. "/" .. path)
			return
		end

		watching = path
		stamp = Stamp(actual)

		print("[tbmap] editing " .. actual .. ", every save pushes")
		Push(path)
	end, function(cmd, argStr)
		local parts = string.Split((argStr or ""):TrimLeft(), " ")
		local typed = table.remove(parts) or ""
		local before = #parts > 0 and (table.concat(parts, " ") .. " ") or ""
		local out = {}

		for _, candidate in ipairs(MapCandidates(typed)) do
			out[#out + 1] = cmd .. " " .. before .. candidate
		end

		return out
	end)

	concommand.Add("tbmap_pull", function(_, _, args)
		local path = TBMap.Maps.Clean(args[1])

		if not path then
			print("[tbmap] usage: tbmap_pull <path> [filename]")
			return
		end

		net.Start("tbmap_map_request")
		net.WriteString(path)
		net.WriteString(args[2] or "")
		net.SendToServer()

		print("[tbmap] asked for " .. path)
	end)

	TBMap.Stream.Receive("tbmap_map_pull", function(_, path, data)
		if not data or data == "" then return end

		local folder = path:match("^(.*)/[^/]+$")

		file.CreateDir(TBMap.Maps.Root)
		if folder then file.CreateDir(TBMap.Maps.Root .. "/" .. folder) end

		local target = TBMap.Maps.Root .. "/" .. path .. ".map.txt"
		file.Write(target, data)

		print(string.format("[tbmap] wrote %s (%d KB)", target, #data / 1024))
	end)
end
