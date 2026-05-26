AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
    self:SetModel("models/hunter/plates/plate1x1.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:DrawShadow(false)
    self:SetScreenScale(1)
    self:SetOffsetX(0)
    self:SetOffsetY(2.1)
    self:SetOffsetZ(0)
    self:SetRotX(0)
    self:SetRotY(90)
    self:SetRotZ(0)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

function ENT:SpawnFunction(ply, tr)
    if not tr.Hit then return end
    local ent = ents.Create("webcam_screen")
    ent:SetPos(tr.HitPos + tr.HitNormal * 10)
    ent:SetAngles(Angle(0, ply:EyeAngles().y + 180, 0))
    ent:Spawn()
    ent:Activate()
    return ent
end
