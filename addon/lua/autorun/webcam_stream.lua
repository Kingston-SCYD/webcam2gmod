--[[--------------------------------------------------------------------------
    Webcam Screen - multiplayer frame relay

    Flow:
        broadcaster client  --(chunked JPEG over net)-->  server
        server              --(fan-out to nearby players)-->  viewer clients
        viewer client       --(write to data/, load via DHTML)--> material

    The server decides who broadcasts: a player is only asked to send frames
    while at least one webcam_screen hosted by them has a player in range.
    Nobody's upload is used unless someone is actually looking.
--]]--------------------------------------------------------------------------

if SERVER then AddCSLuaFile() end

WebcamStream = WebcamStream or {}

local MSG_UP    = "webcam_stream_up"
local MSG_DOWN  = "webcam_stream_down"
local MSG_STATE = "webcam_stream_state"

local MAX_CHUNK_HARD = 32000 -- net messages cap at 64KB; stay well under
local MAX_CHUNKS     = 16

--[[==========================================================================
    SERVER
==========================================================================]]--

if SERVER then

util.AddNetworkString(MSG_UP)
util.AddNetworkString(MSG_DOWN)
util.AddNetworkString(MSG_STATE)

local cvEnabled  = CreateConVar("webcam_screen_enabled", "1", FCVAR_ARCHIVE,
    "Allow webcam screens to stream between players")
local cvRange    = CreateConVar("webcam_screen_range", "2000", FCVAR_ARCHIVE,
    "Only stream to players within this many units of a screen (0 = whole map)", 0, 32768)
local cvFPS      = CreateConVar("webcam_screen_fps", "5", FCVAR_ARCHIVE,
    "Frames per second each broadcaster may send", 1, 30)
local cvMaxFrame = CreateConVar("webcam_screen_maxframe", "32000", FCVAR_ARCHIVE,
    "Largest single frame (bytes) accepted from a client", 8000, 262144)
local cvChunk    = CreateConVar("webcam_screen_chunk", "16000", FCVAR_ARCHIVE,
    "Bytes per net message chunk", 1024, MAX_CHUNK_HARD)
local cvRate     = CreateConVar("webcam_screen_maxrate", "90000", FCVAR_ARCHIVE,
    "Per-broadcaster upload ceiling in bytes/sec", 4000, 1000000)

local Active  = {} -- sid -> { ply = Player, recipients = {Player}, heartbeat = t }
local Buckets = {} -- sid -> token bucket

local function PlayerBySID64(sid)
    if player.GetBySteamID64 then
        local p = player.GetBySteamID64(sid)
        if IsValid(p) then return p end
        return nil
    end
    for _, p in ipairs(player.GetAll()) do
        if p:SteamID64() == sid then return p end
    end
end

local function TakeTokens(sid, bytes)
    local max = cvRate:GetInt()
    local b = Buckets[sid]
    local now = CurTime()

    if not b then
        b = { tokens = max, t = now }
        Buckets[sid] = b
    end

    b.tokens = math.min(max, b.tokens + (now - b.t) * max)
    b.t = now

    if b.tokens < bytes then return false end
    b.tokens = b.tokens - bytes
    return true
end

local function SendState(ply, on)
    if not IsValid(ply) then return end
    net.Start(MSG_STATE)
        net.WriteBool(on)
        net.WriteUInt(cvFPS:GetInt(), 8)
        net.WriteUInt(cvMaxFrame:GetInt(), 32)
        net.WriteUInt(cvChunk:GetInt(), 32)
    net.Send(ply)
end

local function StopAll()
    for sid, a in pairs(Active) do SendState(a.ply, false) end
    Active = {}
end

local function Refresh()
    if not cvEnabled:GetBool() then
        if next(Active) then StopAll() end
        return
    end

    -- Group live screens by host.
    local byHost = {}
    for _, e in ipairs(ents.FindByClass("webcam_screen")) do
        if e.GetHostSteamID64 then
            local sid = e:GetHostSteamID64()
            if sid ~= "" then
                local t = byHost[sid]
                if not t then t = {} byHost[sid] = t end
                t[#t + 1] = e
            end
        end
    end

    local range   = cvRange:GetInt()
    local r2      = range * range
    local players = player.GetAll()
    local now     = CurTime()
    local seen    = {}

    for sid, screens in pairs(byHost) do
        local host = PlayerBySID64(sid)
        if IsValid(host) then
            local recipients = {}
            for _, p in ipairs(players) do
                if p ~= host and not p:IsBot() then
                    local pos = p:EyePos()
                    for _, e in ipairs(screens) do
                        if range <= 0 or pos:DistToSqr(e:GetPos()) <= r2 then
                            recipients[#recipients + 1] = p
                            break
                        end
                    end
                end
            end

            if #recipients > 0 then
                seen[sid] = true
                local a = Active[sid]
                if a then
                    a.ply = host
                    a.recipients = recipients
                    if now > a.heartbeat then -- resync in case a state msg was missed
                        a.heartbeat = now + 5
                        SendState(host, true)
                    end
                else
                    Active[sid] = { ply = host, recipients = recipients, heartbeat = now + 5 }
                    SendState(host, true)
                end
            end
        end
    end

    for sid, a in pairs(Active) do
        if not seen[sid] then
            SendState(a.ply, false)
            Active[sid] = nil
        end
    end
end

timer.Create("WebcamStreamRefresh", 0.5, 0, Refresh)

net.Receive(MSG_UP, function(len, ply)
    if not cvEnabled:GetBool() then return end
    if not IsValid(ply) then return end

    local sid = ply:SteamID64()
    local a = sid and Active[sid]
    if not a then return end -- not authorised to broadcast right now

    if not TakeTokens(sid, math.ceil(len / 8)) then return end

    local seq   = net.ReadUInt(16)
    local idx   = net.ReadUInt(8)
    local count = net.ReadUInt(8)
    local w     = net.ReadUInt(16)
    local h     = net.ReadUInt(16)
    local dlen  = net.ReadUInt(16)

    if count < 1 or count > MAX_CHUNKS then return end
    if idx < 1 or idx > count then return end
    if dlen < 1 or dlen > cvChunk:GetInt() then return end
    if dlen * count > cvMaxFrame:GetInt() + cvChunk:GetInt() then return end

    local data = net.ReadData(dlen)
    if #a.recipients == 0 then return end

    net.Start(MSG_DOWN)
        net.WriteString(sid)
        net.WriteUInt(seq, 16)
        net.WriteUInt(idx, 8)
        net.WriteUInt(count, 8)
        net.WriteUInt(w, 16)
        net.WriteUInt(h, 16)
        net.WriteUInt(dlen, 16)
        net.WriteData(data, dlen)
    net.Send(a.recipients)
end)

hook.Add("PlayerDisconnected", "WebcamStreamCleanup", function(ply)
    local sid = ply:SteamID64()
    if not sid then return end
    Active[sid] = nil
    Buckets[sid] = nil
end)

end -- SERVER

--[[==========================================================================
    CLIENT
==========================================================================]]--

if CLIENT then

local PANEL_W, PANEL_H = 640, 480

-- Set these from Spawnmenu > Utilities > Webcam Screen. The first two only bite
-- on older builds of the module - with a current one the capture page does the
-- encoding and these values are pushed down to it instead.
local cvMaxW     = CreateClientConVar("webcam_screen_mp_width", "320", true, false,
    "Width of the video sent to other players", 128, 640)
local cvQuality  = CreateClientConVar("webcam_screen_mp_quality", "45", true, false,
    "Compression quality of the video sent to other players", 10, 90)
local cvMaxPanel = CreateClientConVar("webcam_screen_maxstreams", "4", true, false,
    "How many remote camera feeds to decode at once", 1, 8)

--[[--------------------------------------------------------------------
    Remote feed decoding.

    GMod can't turn a JPEG in memory into a material, so we use the same
    trick the local feed uses: write it into data/ and let a hidden DHTML
    panel display it, then borrow the panel's HTML material.
--]]--------------------------------------------------------------------

local Streams = {} -- sid -> { panel, mat, file, w, h, last, ready }

local function StreamHTML(fname)
    return [[<html><body style="margin:0;overflow:hidden;background:transparent">
<img id="f" style="width:100%;height:100%;display:block">
<script>
var t=0,e=document.getElementById('f');
function F(){e.src='asset://garrysmod/data/]] .. fname .. [[?t='+(t++);setTimeout(F,33);}
F();
</script></body></html>]]
end

local function RemoveStream(sid)
    local s = Streams[sid]
    if not s then return end
    if IsValid(s.panel) then s.panel:Remove() end
    if s.file then file.Delete(s.file) end
    Streams[sid] = nil
end

local function CreateStream(sid)
    if not sid:match("^%d+$") then return nil end

    -- Evict the least recently used feed if we're at the panel budget.
    local budget = math.Clamp(cvMaxPanel:GetInt(), 1, 8)
    while table.Count(Streams) >= budget do
        local oldSid, oldest
        for k, s in pairs(Streams) do
            if not oldest or s.last < oldest then oldSid, oldest = k, s.last end
        end
        if not oldSid then break end
        RemoveStream(oldSid)
    end

    local fname = "webcam_rc_" .. sid .. ".dat"

    local s = {
        file = fname,
        w = 640, h = 480,
        last = RealTime(),
        ready = false,
    }

    s.panel = vgui.Create("DHTML")
    s.panel:SetSize(PANEL_W, PANEL_H)
    s.panel:SetVisible(false)
    s.panel:SetHTML(StreamHTML(fname))

    timer.Simple(0.5, function()
        if Streams[sid] == s and IsValid(s.panel) then s.ready = true end
    end)

    Streams[sid] = s
    return s
end

local function Feed(sid, data, w, h)
    local s = Streams[sid] or CreateStream(sid)
    if not s then return end

    if w and w > 0 then s.w = w end
    if h and h > 0 then s.h = h end
    s.last = RealTime()
    s.dirty = RealTime()

    file.Write(s.file, data)

    if s.ready and IsValid(s.panel) then
        s.panel:UpdateHTMLTexture()
        s.mat = nil
    end
end

-- The browser loads the new image asynchronously, so keep refreshing the
-- texture for a moment after each write instead of only once.
hook.Add("Think", "WebcamStreamPanels", function()
    local now = RealTime()
    for sid, s in pairs(Streams) do
        if now - s.last > 10 then
            RemoveStream(sid)
        elseif s.ready and s.dirty and now - s.dirty < 0.5
            and now - (s.lastTex or 0) > 0.03 and IsValid(s.panel) then
            s.lastTex = now
            s.panel:UpdateHTMLTexture()
            s.mat = nil
        end
    end
end)

--[[--------------------------------------------------------------------
    Public accessor used by the entity.
    Returns material, sourceW, sourceH, maxU, maxV (or nil).
--]]--------------------------------------------------------------------

function WebcamStream.Get(sid)
    local lp = LocalPlayer()

    -- Your own screens read the local feed directly - no round trip.
    if IsValid(lp) and sid == lp:SteamID64() then
        if not webcam_texture or not webcam_texture.GetMaterial then return nil end
        if not webcam or not webcam.IsRunning or not webcam.IsRunning() then return nil end

        local mat = webcam_texture.GetMaterial()
        if not mat then return nil end

        local w, h = 640, 480
        if webcam_texture.GetSize then w, h = webcam_texture.GetSize() end
        local u, v = 1, 1
        if webcam_texture.GetUV then u, v = webcam_texture.GetUV() end
        return mat, w, h, u, v
    end

    local s = Streams[sid]
    if not s or not s.ready or not IsValid(s.panel) then return nil end
    if RealTime() - s.last > 5 then return nil end

    if not s.mat then s.mat = s.panel:GetHTMLMaterial() end
    if not s.mat then return nil end

    local u, v = 1, 1
    local tex = s.mat:GetTexture("$basetexture")
    if tex then
        u = PANEL_W / tex:Width()
        v = PANEL_H / tex:Height()
    end

    return s.mat, s.w, s.h, u, v
end

function WebcamStream.IsBroadcasting()
    return WebcamStream._bc and WebcamStream._bc.on or false
end

--[[--------------------------------------------------------------------
    Receiving frames from other players.
--]]--------------------------------------------------------------------

local Assembling = {}

net.Receive(MSG_DOWN, function()
    local sid   = net.ReadString()
    local seq   = net.ReadUInt(16)
    local idx   = net.ReadUInt(8)
    local count = net.ReadUInt(8)
    local w     = net.ReadUInt(16)
    local h     = net.ReadUInt(16)
    local dlen  = net.ReadUInt(16)
    local data  = net.ReadData(dlen)

    if not sid:match("^%d+$") then return end
    if count < 1 or count > MAX_CHUNKS or idx < 1 or idx > count then return end

    local a = Assembling[sid]
    if not a or a.seq ~= seq then
        if idx ~= 1 then return end -- joined mid-frame, wait for the next one
        a = { seq = seq, parts = {}, got = 0, count = count }
        Assembling[sid] = a
    end

    if a.parts[idx] then return end
    a.parts[idx] = data
    a.got = a.got + 1

    if a.got >= a.count then
        Assembling[sid] = nil
        Feed(sid, table.concat(a.parts, "", 1, a.count), w, h)
    end
end)

--[[--------------------------------------------------------------------
    Broadcasting our own camera when the server asks for it.
--]]--------------------------------------------------------------------

local bc = {
    on = false,
    fps = 5,
    maxFrame = 32000,
    chunk = 16000,
    last = 0,
    seq = 0,
    expire = 0,
    sent = 0,
}
WebcamStream._bc = bc

net.Receive(MSG_STATE, function()
    local on = net.ReadBool()
    bc.fps      = math.Clamp(net.ReadUInt(8), 1, 30)
    bc.maxFrame = net.ReadUInt(32)
    bc.chunk    = math.Clamp(net.ReadUInt(32), 1024, MAX_CHUNK_HARD)

    if on ~= bc.on then
        MsgN("[Webcam] Broadcasting " .. (on and "ON" or "OFF"))
    end

    bc.on = on
    bc.expire = RealTime() + 15 -- stop if the server goes quiet
end)

local warnedNoEncode, warnedTooBig = false, 0

local function GrabFrame()
    if not webcam or not webcam.IsRunning or not webcam.IsRunning() then return nil end

    -- Preferred: the small frame the capture page encodes specifically for the
    -- network. Already downscaled, and still WebP-with-alpha when chroma keying
    -- is on, so it forwards byte-for-byte.
    if webcam.GetNetFrame then
        return webcam.GetNetFrame()
    end

    -- Older module: re-encode locally. JPEG only, so chroma transparency is lost.
    if webcam.GetFrameEncoded then
        return webcam.GetFrameEncoded(cvMaxW:GetInt(), cvQuality:GetInt())
    end

    if not warnedNoEncode then
        warnedNoEncode = true
        MsgN("[Webcam] gmcl_webcam is out of date - no GetNetFrame, sending raw display frames.")
        MsgN("[Webcam] Rebuild the module, or set the browser page to 480p / quality ~30.")
    end
    return webcam.GetFrame()
end

hook.Add("Think", "WebcamStreamBroadcast", function()
    if not bc.on then return end
    if RealTime() > bc.expire then bc.on = false return end
    if RealTime() - bc.last < 1 / bc.fps then return end
    bc.last = RealTime()

    local data, w, h = GrabFrame()
    if not data or #data < 8 then return end

    if #data > bc.maxFrame then
        if RealTime() > warnedTooBig then
            warnedTooBig = RealTime() + 10
            MsgN(string.format("[Webcam] Frame is %d bytes, server limit is %d.", #data, bc.maxFrame))
            MsgN("[Webcam] Lower Feed width / Feed quality in Utilities > Webcam Screen,")
            MsgN("[Webcam] or raise the limit on the server: webcam_screen_maxframe " .. math.max(8000, #data * 2))
        end
        return
    end

    -- Don't resend a frame the browser hasn't updated yet.
    local crc = util.CRC(data)
    if crc == bc.lastCRC then return end
    bc.lastCRC = crc

    local count = math.ceil(#data / bc.chunk)
    if count > MAX_CHUNKS then return end

    w = math.Clamp(math.floor(w or 640), 1, 65535)
    h = math.Clamp(math.floor(h or 480), 1, 65535)
    bc.seq = (bc.seq + 1) % 65536

    for i = 1, count do
        local part = string.sub(data, (i - 1) * bc.chunk + 1, i * bc.chunk)
        net.Start(MSG_UP)
            net.WriteUInt(bc.seq, 16)
            net.WriteUInt(i, 8)
            net.WriteUInt(count, 8)
            net.WriteUInt(w, 16)
            net.WriteUInt(h, 16)
            net.WriteUInt(#part, 16)
            net.WriteData(part, #part)
        net.SendToServer()
    end

    bc.sent = bc.sent + #data
end)

hook.Add("ShutDown", "WebcamStreamCleanup", function()
    for sid in pairs(Streams) do RemoveStream(sid) end
end)

concommand.Add("webcam_stream_status", function()
    MsgN("=== Webcam stream ===")
    MsgN(" broadcasting : " .. tostring(bc.on) ..
         string.format("  (%d fps, max %d bytes/frame, %.1f KB sent)", bc.fps, bc.maxFrame, bc.sent / 1024))
    local enc = "raw display frame (module out of date)"
    if webcam and webcam.GetNetFrame then enc = "capture page (scaled, keeps chroma alpha)"
    elseif webcam and webcam.GetFrameEncoded then enc = "module re-encode (JPEG, no chroma alpha)" end
    MsgN(" encoder      : " .. enc)
    MsgN(" incoming feeds:")
    local n = 0
    for sid, s in pairs(Streams) do
        n = n + 1
        MsgN(string.format("   %s  %dx%d  %.1fs ago  %s",
            sid, s.w, s.h, RealTime() - s.last, s.ready and "ready" or "loading"))
    end
    if n == 0 then MsgN("   (none)") end
end)

end -- CLIENT
