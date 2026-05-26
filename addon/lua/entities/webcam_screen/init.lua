AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local SAVE_FILE = "webcam_screen_settings.txt"

local function LoadDefaults()
    if not file.Exists(SAVE_FILE, "DATA") then return {} end
    local json = file.Read(SAVE_FILE, "DATA")
    return util.JSONToTable(json) or {}
end

local function SaveDefaults(ent)
    local data = {
        ScreenScale = ent:GetScreenScale(),
        OffsetX = ent:GetOffsetX(),
        OffsetY = ent:GetOffsetY(),
        OffsetZ = ent:GetOffsetZ(),
        RotX = ent:GetRotX(),
        RotY = ent:GetRotY(),
        RotZ = ent:GetRotZ(),
    }
    file.Write(SAVE_FILE, util.TableToJSON(data))
end

function ENT:Initialize()
    self:SetModel("models/hunter/plates/plate1x1.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:DrawShadow(false)
    self:SetRenderMode(RENDERMODE_TRANSALPHA)
    self:SetColor(Color(255, 255, 255, 1))

    local d = LoadDefaults()
    self:SetScreenScale(d.ScreenScale or 1)
    self:SetOffsetX(d.OffsetX or 0)
    self:SetOffsetY(d.OffsetY or 2.1)
    self:SetOffsetZ(d.OffsetZ or 0)
    self:SetRotX(d.RotX or 0)
    self:SetRotY(d.RotY or 90)
    self:SetRotZ(d.RotZ or 0)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end
end

function ENT:Think()
    -- Save when properties change
    local hash = self:GetScreenScale() + self:GetOffsetX() + self:GetOffsetY() + self:GetOffsetZ() + self:GetRotX() + self:GetRotY() + self:GetRotZ()
    if hash ~= self._lastHash then
        self._lastHash = hash
        SaveDefaults(self)
    end
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
