-- TrenchBroom .map loader for Garry's Mod. The server reads and builds the map and streams the
-- faces to clients; the client never sees the .map file.

AddCSLuaFile()

TBMap = TBMap or {}

local shared = {
	"tbmap/sh_config.lua",
	"tbmap/sh_stream.lua",
	"tbmap/sh_maps.lua",
	"tbmap/sh_parse.lua",
	"tbmap/sh_probe.lua",
	"tbmap/sh_geom.lua",
	"tbmap/sh_brush.lua",
	"tbmap/sh_brushes.lua",
	"tbmap/sh_trace.lua",
	"tbmap/sh_cover.lua",
	"tbmap/sh_bake.lua",
	"tbmap/sh_wire.lua",
	"tbmap/sh_entity.lua",
}

for _, file in ipairs(shared) do
	if SERVER then AddCSLuaFile(file) end
	include(file)
end

if SERVER then
	AddCSLuaFile("tbmap/cl_atlas.lua")
	AddCSLuaFile("tbmap/cl_render.lua")
	include("tbmap/sv_host.lua")
else
	-- cl_atlas first: cl_render uses its packer.
	include("tbmap/cl_atlas.lua")
	include("tbmap/cl_render.lua")
end
