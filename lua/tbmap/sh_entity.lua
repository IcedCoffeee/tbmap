-- One entity class per collision group: world, sky and clip, with the traces whitelisted to world
-- so a sky or clip brush blocks the player and not light. None of them draws anything.

local ENT = {}

ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "TrenchBroom Map"
ENT.Category = "TrenchBroom"
ENT.Spawnable = false
ENT.AdminOnly = true
ENT.PhysgunDisabled = true
ENT.RenderGroup = RENDERGROUP_BOTH

function ENT:Draw() end
function ENT:DrawTranslucent() end

-- The world's collision lives on this entity and the client rebuilds it from the payload, so the
-- engine's own entity cleanup has to leave it alone rather than take the collision with it.
function ENT:Initialize()
	self:AddEFlags(EFL_KEEP_ON_RECREATE_ENTITIES)
end

-- Which collision cell this entity carries. Both realms bucket the convexes the same way, and the
-- client attaches each bucket to the entity bearing its index.
function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "ChunkIndex")
end

-- Collision is built at runtime on both realms, so the client has to be guaranteed a copy of the
-- entity to attach it to.
function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end

scripted_ents.Register(ENT, "tbmap_world")

local SKY = table.Copy(ENT)
SKY.PrintName = "TrenchBroom Sky"

scripted_ents.Register(SKY, "tbmap_sky")

local CLIP = table.Copy(ENT)
CLIP.PrintName = "TrenchBroom Clip"

scripted_ents.Register(CLIP, "tbmap_clip")
