AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

--[[--------------------------------------------------------------------
    Webcam Screen - server
    The screen itself is just a plate. All it really stores is WHO it is
    showing (its "streamer" - the player who spawned it). The frames
    themselves are relayed below, player to player, via the game server.
----------------------------------------------------------------------]]

-- ======================================================================
-- Settings
-- ======================================================================

-- The one knob: how much webcam data a single player is allowed to push
-- through the server, in kilobytes per second. Everything else (frame rate,
-- resolution, JPEG quality) is derived from this automatically by the
-- streaming client, so there is nothing else to tune.
--   16  = potato / low quality but very cheap
--   48  = default, looks fine on a screen a few metres away
--   128 = sharp, only sensible on a LAN or a beefy server
local MaxKbps = CreateConVar("sv_webcam_max_kbps", "48",
    bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY),
    "Max webcam data one player may stream through the server, in KB/sec.", 4, 1024)

-- Players further than this from every one of a streamer's screens don't get
-- that streamer's frames at all.
local VIEW_RANGE = 4000
local VIEW_RANGE_SQR = VIEW_RANGE * VIEW_RANGE

-- ======================================================================
-- Relay
-- ======================================================================

util.AddNetworkString("wc_frame")
util.AddNetworkString("wc_hint")

local budget = {}       -- [ply] = { t = window start, n = bytes used }
local screenCache = {}  -- [ply] = { t = cached at, list = { positions } }

local function MaxFrameBytes()
    -- A single frame may never be worth more than one second of budget,
    -- and must comfortably fit inside one net message.
    return math.Clamp(MaxKbps:GetInt() * 1024, 1024, 32768)
end

local function ScreensOf(ply)
    local c = screenCache[ply]
    if c and CurTime() - c.t < 0.5 then return c.list end

    local list = {}
    for _, e in ipairs(ents.FindByClass("webcam_screen")) do
        if e:GetStreamer() == ply then
            list[#list + 1] = e:GetPos()
        end
    end

    screenCache[ply] = { t = CurTime(), list = list }
    return list
end

local function ViewersOf(ply)
    local screens = ScreensOf(ply)
    if #screens == 0 then return nil end

    local out = nil
    for _, p in ipairs(player.GetAll()) do
        if p ~= ply then
            local pos = p:GetPos()
            for i = 1, #screens do
                if pos:DistToSqr(screens[i]) < VIEW_RANGE_SQR then
                    out = out or {}
                    out[#out + 1] = p
                    break
                end
            end
        end
    end
    return out
end

local function WithinBudget(ply, bytes)
    local b = budget[ply]
    local now = CurTime()

    if not b or now - b.t >= 1 then
        b = { t = now, n = 0 }
        budget[ply] = b
    end

    if b.n + bytes > MaxKbps:GetInt() * 1024 then return false end
    b.n = b.n + bytes
    return true
end

net.Receive("wc_frame", function(_, ply)
    if not IsValid(ply) then return end

    local w = net.ReadUInt(16)
    local h = net.ReadUInt(16)
    local n = net.ReadUInt(16)
    if n <= 0 or n > MaxFrameBytes() then return end

    local data = net.ReadData(n)
    if not WithinBudget(ply, n) then return end

    local viewers = ViewersOf(ply)
    if not viewers then return end

    net.Start("wc_frame")
        net.WriteUInt(ply:UserID(), 16)
        net.WriteUInt(w, 16)
        net.WriteUInt(h, 16)
        net.WriteUInt(n, 16)
        net.WriteData(data, n)
    net.Send(viewers)
end)

hook.Add("PlayerDisconnected", "webcam_screen_cleanup", function(ply)
    budget[ply] = nil
    screenCache[ply] = nil

    for _, e in ipairs(ents.FindByClass("webcam_screen")) do
        if e:GetStreamer() == ply then
            e:SetStreamer(NULL)
        end
    end
end)

-- ======================================================================
-- Entity
-- ======================================================================

local SAVE_FILE = "webcam_screen_settings.txt"

local function LoadDefaults()
    if not file.Exists(SAVE_FILE, "DATA") then return {} end
    return util.JSONToTable(file.Read(SAVE_FILE, "DATA") or "") or {}
end

local function SaveDefaults(ent)
    file.Write(SAVE_FILE, util.TableToJSON({
        ScreenScale = ent:GetScreenScale(),
        OffsetX = ent:GetOffsetX(),
        OffsetY = ent:GetOffsetY(),
        OffsetZ = ent:GetOffsetZ(),
        RotX = ent:GetRotX(),
        RotY = ent:GetRotY(),
        RotZ = ent:GetRotZ(),
    }))
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

-- Point the screen at a player and nudge them to start their camera.
function ENT:SetupStreamer(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    self:SetStreamer(ply)
    self:SetCreator(ply)
    screenCache[ply] = nil

    net.Start("wc_hint")
    net.Send(ply)
end

function ENT:Think()
    local hash = self:GetScreenScale() + self:GetOffsetX() + self:GetOffsetY()
        + self:GetOffsetZ() + self:GetRotX() + self:GetRotY() + self:GetRotZ()

    if hash ~= self._lastHash then
        self._lastHash = hash
        SaveDefaults(self)
    end

    self:NextThink(CurTime() + 0.5)
    return true
end

function ENT:OnRemove()
    local ply = self:GetStreamer()
    if IsValid(ply) then screenCache[ply] = nil end
end

-- Duplicator / save-load: whoever pastes it becomes the streamer.
function ENT:PostEntityPaste(ply)
    self:SetupStreamer(ply)
end

function ENT:SpawnFunction(ply, tr)
    if not tr.Hit then return end

    local ent = ents.Create("webcam_screen")
    ent:SetPos(tr.HitPos + tr.HitNormal * 10)
    ent:SetAngles(Angle(0, ply:EyeAngles().y + 180, 0))
    ent:Spawn()
    ent:Activate()
    ent:SetupStreamer(ply)

    return ent
end
