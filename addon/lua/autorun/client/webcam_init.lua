--[[--------------------------------------------------------------------
    Webcam - client
    ----------------------------------------------------------------------
    Three jobs:

      1. Capture. The C module runs a tiny web server; you open it in a real
         browser, allow the camera, and it pushes encoded frames back into
         GMod over a local websocket. Chroma key is applied in that browser
         page, before encoding, so the frames already have a real alpha
         channel and every viewer gets the cut-out for free.

      2. Share. If you own a Webcam Screen, a small second copy of each frame
         is pushed to the game server, which passes it to everyone standing
         near one of your screens.

      3. Show. Incoming frames (yours and other people's) are dropped into a
         2x2 atlas rendered by one hidden DHTML panel. Entities just draw a
         quarter of that texture.

    Only the person streaming needs the C module. Everyone else can watch
    with plain Lua.
----------------------------------------------------------------------]]

local HAS_MODULE = pcall(require, "webcam") and istable(webcam)

webcam_screens = webcam_screens or {}
local WS = webcam_screens

-- ======================================================================
-- Atlas panel
-- ======================================================================

local PANEL_SIZE  = 1024
local SLOT_SIZE   = 512    -- 2x2 grid
local MAX_SLOTS   = 4      -- slot 0 is reserved for you, 1-3 for other people
local SLOT_TIMEOUT = 3     -- seconds without a frame before a slot is freed

local ATLAS_HTML = [[<html><head><style>
html,body{margin:0;padding:0;width:1024px;height:1024px;background:transparent;overflow:hidden}
img{position:absolute;width:512px;height:512px;border:0}
#s0{left:0;top:0}#s1{left:512px;top:0}#s2{left:0;top:512px}#s3{left:512px;top:512px}
</style></head><body>
<img id="s0"><img id="s1"><img id="s2"><img id="s3">
<script>
var n=[0,0,0,0];
function U(i){n[i]++;document.getElementById('s'+i).src='asset://garrysmod/data/webcam_slot'+i+'.dat?t='+n[i];}
function CL(i){document.getElementById('s'+i).removeAttribute('src');}
</script></body></html>]]

local Panel, panelReady = nil, false
local atlasMat, atlasTex = nil, nil
local slots, slotOf = {}, {}
local lastTexUpdate = 0

local function EnsurePanel()
    if IsValid(Panel) then return end

    panelReady = false
    atlasMat, atlasTex = nil, nil

    Panel = vgui.Create("DHTML")
    Panel:SetSize(PANEL_SIZE, PANEL_SIZE)
    Panel:SetVisible(false)
    Panel:SetHTML(ATLAS_HTML)
    Panel.OnDocumentReady = function() panelReady = true end

    timer.Simple(0.5, function()
        if IsValid(Panel) then panelReady = true end
    end)
end

local function DestroyPanel()
    if IsValid(Panel) then Panel:Remove() end
    Panel, panelReady = nil, false
    atlasMat, atlasTex = nil, nil
    slots, slotOf = {}, {}
end

-- The raw HTML material is not flagged translucent, so alpha gets thrown away
-- and chroma keyed frames come out with a black background. Wrapping the same
-- texture in our own UnlitGeneric with $translucent fixes that.
local function GetAtlasMaterial()
    if not IsValid(Panel) then return nil end

    local html = Panel:GetHTMLMaterial()
    if not html then return nil end

    local tex = html:GetTexture("$basetexture")
    if not tex or tex:IsError() then return nil end

    if atlasMat and atlasTex == tex then
        return atlasMat, tex:Width(), tex:Height()
    end

    atlasTex = tex
    atlasMat = CreateMaterial("webcam_screen_atlas", "UnlitGeneric", {
        ["$basetexture"] = tex:GetName(),
        ["$translucent"] = "1",
        ["$vertexalpha"] = "1",
        ["$vertexcolor"] = "1",
        ["$nolod"] = "1",
    })
    atlasMat:SetTexture("$basetexture", tex)

    return atlasMat, tex:Width(), tex:Height()
end

-- ======================================================================
-- Slots
-- ======================================================================

local function LocalKey()
    local ply = LocalPlayer()
    return IsValid(ply) and ply:UserID() or -1
end

local function AssignSlot(key)
    local existing = slotOf[key]
    if existing then return existing end

    -- You always get slot 0 so a busy server can't push your own feed out.
    if key == LocalKey() then
        if slots[0] then slotOf[slots[0].key] = nil end
        slots[0] = { key = key, last = CurTime(), w = 640, h = 480 }
        slotOf[key] = 0
        return 0
    end

    local free, oldest, oldestTime
    for i = 1, MAX_SLOTS - 1 do
        local s = slots[i]
        if not s then
            free = i
            break
        end
        if not oldestTime or s.last < oldestTime then
            oldest, oldestTime = i, s.last
        end
    end

    local idx = free or oldest or 1
    if slots[idx] then slotOf[slots[idx].key] = nil end

    slots[idx] = { key = key, last = CurTime(), w = 640, h = 480 }
    slotOf[key] = idx
    return idx
end

local function FreeSlot(idx)
    local s = slots[idx]
    if not s then return end

    slotOf[s.key] = nil
    slots[idx] = nil

    if IsValid(Panel) then
        Panel:RunJavascript("CL(" .. idx .. ")")
    end
end

-- Hand a freshly encoded frame (JPEG, or WebP when chroma key is on) to the
-- atlas. `key` is the streamer's UserID.
local function PushFrame(key, data, w, h)
    if not data or #data < 8 then return end

    EnsurePanel()

    local idx = AssignSlot(key)
    local s = slots[idx]

    s.last = CurTime()
    if w and w > 0 then s.w = w end
    if h and h > 0 then s.h = h end

    file.Write("webcam_slot" .. idx .. ".dat", data)
    Panel:RunJavascript("U(" .. idx .. ")")
end

timer.Create("webcam_slot_expiry", 1, 0, function()
    local now, any = CurTime(), false

    for i = 0, MAX_SLOTS - 1 do
        local s = slots[i]
        if s then
            if now - s.last > SLOT_TIMEOUT then
                FreeSlot(i)
            else
                any = true
            end
        end
    end

    if not any and IsValid(Panel) then DestroyPanel() end
end)

-- Pull the browser's latest paint into the game texture.
hook.Add("PreRender", "webcam_atlas_update", function()
    if not IsValid(Panel) or not panelReady then return end
    if RealTime() - lastTexUpdate < 1 / 40 then return end

    local any = false
    for i = 0, MAX_SLOTS - 1 do
        if slots[i] then any = true break end
    end
    if not any then return end

    lastTexUpdate = RealTime()
    Panel:UpdateHTMLTexture()
end)

-- ======================================================================
-- Public API used by the webcam_screen entity
-- ======================================================================

-- Returns: material, u0, v0, u1, v1, sourceWidth, sourceHeight
function WS.GetFeed(ply)
    if not IsValid(ply) then return nil end

    local idx = slotOf[ply:UserID()]
    if not idx then return nil end

    local s = slots[idx]
    if not s or CurTime() - s.last > SLOT_TIMEOUT then return nil end

    local mat, tw, th = GetAtlasMaterial()
    if not mat or not tw or tw <= 0 then return nil end

    local sx = (idx % 2) * SLOT_SIZE
    local sy = math.floor(idx / 2) * SLOT_SIZE

    return mat, sx / tw, sy / th, (sx + SLOT_SIZE) / tw, (sy + SLOT_SIZE) / th, s.w, s.h
end

function WS.IsStreaming()
    return HAS_MODULE and webcam.IsRunning()
end

-- ======================================================================
-- Local capture -> atlas
-- ======================================================================

local curW, curH = 640, 480
local lastLocal = 0

hook.Add("Think", "webcam_local_feed", function()
    if not HAS_MODULE or not webcam.IsRunning() then return end
    if RealTime() - lastLocal < 1 / 20 then return end
    lastLocal = RealTime()

    local data, w, h = webcam.GetFrame()
    if not data or data == false then return end
    if w and w > 0 and h and h > 0 then curW, curH = w, h end

    PushFrame(LocalKey(), data, curW, curH)
end)

-- ======================================================================
-- Sharing to the server
-- ======================================================================

local function MaxKbps()
    local cv = GetConVar("sv_webcam_max_kbps")
    return cv and math.Clamp(cv:GetInt(), 4, 1024) or 48
end

local ownsScreen, nextOwnerCheck = false, 0
local netW, netQ = 240, 45
local nextSend, nextCfgPush = 0, 0
local lastNetFps = 6

-- We aim for roughly this many frames a second and let the pacing below absorb
-- whatever is left of the budget. Fixing a high frame rate and squeezing
-- quality to meet it just produces mush that is *still* over budget.
local TARGET_FPS = 6
local MAX_FPS = 15

local function PushCfg(enabled, fps)
    webcam.SetNetConfig(netW, netQ, fps or lastNetFps, enabled)
end

hook.Add("Think", "webcam_share", function()
    if not HAS_MODULE then return end

    local now = CurTime()

    if now >= nextOwnerCheck then
        nextOwnerCheck = now + 2

        local me, found = LocalPlayer(), false
        for _, e in ipairs(ents.FindByClass("webcam_screen")) do
            if e:GetStreamer() == me then found = true break end
        end

        if found ~= ownsScreen then
            ownsScreen = found
            if webcam.IsRunning() then PushCfg(ownsScreen) end
        end
    end

    if not ownsScreen or not webcam.IsRunning() then return end

    local budget = MaxKbps() * 1024
    local target = budget / TARGET_FPS

    if now >= nextCfgPush then
        nextCfgPush = now + 1
        PushCfg(true)
    end

    if now < nextSend then return end

    local data = webcam.GetNetFrame()
    if not data or data == false then return end
    local size = #data

    -- Quality first, then resolution. Multiplicative, so it converges in two or
    -- three frames instead of grinding down one step at a time.
    local ratio = size / target
    if ratio > 1.05 then
        netQ = math.max(30, math.floor(netQ / math.min(1.5, ratio)))
        if netQ <= 30 then netW = math.max(160, netW - 40) end
    elseif ratio < 0.7 then
        netQ = math.min(75, netQ + 5)
        if netQ >= 75 then netW = math.min(480, netW + 40) end
    end

    -- Pace strictly by the budget: bigger frames simply mean fewer per second,
    -- which is what keeps us under the server's cap instead of being dropped.
    local interval = math.max(1 / MAX_FPS, size / budget)
    lastNetFps = math.Clamp(math.ceil(1 / interval) + 1, 2, MAX_FPS)
    nextSend = now + interval

    -- Still shrinking towards the budget; skip rather than have the server
    -- silently bin it.
    if size > math.Clamp(budget, 1024, 32768) then return end

    net.Start("wc_frame")
        net.WriteUInt(curW, 16)
        net.WriteUInt(curH, 16)
        net.WriteUInt(size, 16)
        net.WriteData(data, size)
    net.SendToServer()
end)

-- ======================================================================
-- Receiving other players' streams
-- ======================================================================

net.Receive("wc_frame", function()
    local userid = net.ReadUInt(16)
    local w = net.ReadUInt(16)
    local h = net.ReadUInt(16)
    local n = net.ReadUInt(16)
    if n <= 0 then return end

    local data = net.ReadData(n)
    if userid == LocalKey() then return end

    PushFrame(userid, data, w, h)
end)

-- Sent by the server when you spawn a screen.
net.Receive("wc_hint", function()
    if not HAS_MODULE then
        chat.AddText(Color(255, 120, 120),
            "[Webcam] The webcam module isn't installed, so this screen won't show your camera.")
        return
    end

    if webcam.IsRunning() then return end

    RunConsoleCommand("webcam_start")
end)

-- ======================================================================
-- Material override support (paint the feed onto props)
-- ======================================================================

local RT = GetRenderTargetEx("webcam_feed", 1024, 1024, RT_SIZE_NO_CHANGE,
    MATERIAL_RT_DEPTH_NONE, 2, 0, IMAGE_FORMAT_RGBA8888)

CreateClientConVar("webcam_tex_scale", "1", true, false, "Texture scale on objects", 0.1, 10)
CreateClientConVar("webcam_tex_rotation", "0", true, false, "Texture rotation degrees", -180, 180)
CreateClientConVar("webcam_tex_offset_x", "0", true, false, "Texture X offset", -1, 1)
CreateClientConVar("webcam_tex_offset_y", "0", true, false, "Texture Y offset", -1, 1)
CreateClientConVar("webcam_tex_flip_h", "0", true, false, "Flip horizontally")
CreateClientConVar("webcam_tex_flip_v", "0", true, false, "Flip vertically")
CreateClientConVar("webcam_tex_tile", "1", true, false, "Enable texture tiling")

local function RotatePoint(x, y, cx, cy, ang)
    local r = math.rad(ang)
    local c, s = math.cos(r), math.sin(r)
    local dx, dy = x - cx, y - cy
    return cx + dx * c - dy * s, cy + dx * s + dy * c
end

hook.Add("PostRender", "WebcamRT", function()
    local mat, su0, sv0, su1, sv1 = WS.GetFeed(LocalPlayer())
    if not mat then return end

    local regU, regV = su1 - su0, sv1 - sv0

    local scale = GetConVar("webcam_tex_scale"):GetFloat()
    local rot = GetConVar("webcam_tex_rotation"):GetFloat()
    local offX = GetConVar("webcam_tex_offset_x"):GetFloat()
    local offY = GetConVar("webcam_tex_offset_y"):GetFloat()
    local flipH = GetConVar("webcam_tex_flip_h"):GetBool()
    local flipV = GetConVar("webcam_tex_flip_v"):GetBool()
    local tiling = GetConVar("webcam_tex_tile"):GetBool()

    if scale <= 0 then scale = 1 end

    local uvW, uvH = regU / scale, regV / scale
    local ucx = su0 + regU * 0.5 + offX * regU
    local vcy = sv0 + regV * 0.5 + offY * regV

    local u0, u1 = ucx - uvW * 0.5, ucx + uvW * 0.5
    local v0, v1 = vcy - uvH * 0.5, vcy + uvH * 0.5

    if flipH then u0, u1 = u1, u0 end
    if flipV then v0, v1 = v1, v0 end

    local cx, cy = 512, 512
    local x0, y0 = RotatePoint(0, 0, cx, cy, rot)
    local x1, y1 = RotatePoint(1024, 0, cx, cy, rot)
    local x2, y2 = RotatePoint(1024, 1024, cx, cy, rot)
    local x3, y3 = RotatePoint(0, 1024, cx, cy, rot)

    render.PushRenderTarget(RT)
    render.Clear(0, 0, 0, 0)
    render.SetViewPort(0, 0, 1024, 1024)
    cam.Start2D()
        render.SetMaterial(mat)

        if not tiling then
            render.OverrideDepthEnable(true, false)

            local clampU0 = math.Clamp(u0, su0, su1)
            local clampU1 = math.Clamp(u1, su0, su1)
            local clampV0 = math.Clamp(v0, sv0, sv1)
            local clampV1 = math.Clamp(v1, sv0, sv1)

            local fracL = (u1 ~= u0) and (clampU0 - u0) / (u1 - u0) or 0
            local fracR = (u1 ~= u0) and (clampU1 - u0) / (u1 - u0) or 1
            local fracT = (v1 ~= v0) and (clampV0 - v0) / (v1 - v0) or 0
            local fracB = (v1 ~= v0) and (clampV1 - v0) / (v1 - v0) or 1

            local function Lerp2D(fx, fy)
                local topX = x0 + (x1 - x0) * fx
                local topY = y0 + (y1 - y0) * fx
                local botX = x3 + (x2 - x3) * fx
                local botY = y3 + (y2 - y3) * fx
                return topX + (botX - topX) * fy, topY + (botY - topY) * fy
            end

            local px0, py0 = Lerp2D(fracL, fracT)
            local px1, py1 = Lerp2D(fracR, fracT)
            local px2, py2 = Lerp2D(fracR, fracB)
            local px3, py3 = Lerp2D(fracL, fracB)

            mesh.Begin(MATERIAL_QUADS, 1)
                mesh.Position(Vector(px0, py0, 0)) mesh.TexCoord(0, clampU0, clampV0) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
                mesh.Position(Vector(px1, py1, 0)) mesh.TexCoord(0, clampU1, clampV0) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
                mesh.Position(Vector(px2, py2, 0)) mesh.TexCoord(0, clampU1, clampV1) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
                mesh.Position(Vector(px3, py3, 0)) mesh.TexCoord(0, clampU0, clampV1) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
            mesh.End()

            render.OverrideDepthEnable(false)
        else
            mesh.Begin(MATERIAL_QUADS, 1)
                mesh.Position(Vector(x0, y0, 0)) mesh.TexCoord(0, u0, v0) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
                mesh.Position(Vector(x1, y1, 0)) mesh.TexCoord(0, u1, v0) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
                mesh.Position(Vector(x2, y2, 0)) mesh.TexCoord(0, u1, v1) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
                mesh.Position(Vector(x3, y3, 0)) mesh.TexCoord(0, u0, v1) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
            mesh.End()
        end
    cam.End2D()
    render.SetViewPort(0, 0, ScrW(), ScrH())
    render.PopRenderTarget()
end)

-- ======================================================================
-- Commands and menu
-- ======================================================================

concommand.Add("webcam_start", function(_, _, args)
    if not HAS_MODULE then
        print("[Webcam] gmcl_webcam module not installed - you can watch others, but not stream.")
        return
    end

    local port = tonumber(args[1]) or 27099
    local url = "http://127.0.0.1:" .. port

    EnsurePanel()
    webcam.Start(port)
    PushCfg(ownsScreen)

    SetClipboardText(url)
    chat.AddText(Color(120, 220, 160), "[Webcam] ", color_white,
        "Open ", Color(150, 200, 255), url, color_white,
        " in your browser and allow the camera. (Copied to clipboard.)")
end)

concommand.Add("webcam_stop", function()
    if HAS_MODULE then
        webcam.SetNetConfig(netW, netQ, lastNetFps, false)
        webcam.Stop()
    end
    print("[Webcam] Stopped")
end)

concommand.Add("webcam_status", function()
    if not HAS_MODULE then
        print("[Webcam] Module: NOT INSTALLED (you can watch others, but not stream)")
        return
    end

    local connected, frames, drops, reason = webcam.IsCameraConnected()

    print("[Webcam] Capture server : " .. (webcam.IsRunning() and ("running on port " .. webcam.GetPort()) or "stopped"))
    print("[Webcam] Browser page   : " .. (connected and "connected" or "NOT connected - open the page and allow the camera"))
    print("[Webcam] Frames received: " .. (frames or 0))
    print("[Webcam] Disconnects    : " .. (drops or 0) .. (drops and drops > 0 and (" - last: " .. tostring(reason)) or ""))
    print("[Webcam] Owns a screen  : " .. tostring(ownsScreen))
    print("[Webcam] Sharing at     : " .. netW .. "px quality " .. netQ .. " @ " .. lastNetFps .. " fps")
    print("[Webcam] Server cap     : " .. MaxKbps() .. " KB/s")

    local active = {}
    for i = 0, MAX_SLOTS - 1 do
        if slots[i] then active[#active + 1] = i end
    end
    print("[Webcam] Active feeds   : " .. (#active > 0 and table.concat(active, ", ") or "none"))
end)

local showHUD = false
concommand.Add("webcam_hud", function() showHUD = not showHUD end)

hook.Add("HUDPaint", "WebcamHUD", function()
    if not showHUD then return end

    local mat, u0, v0, u1, v1, w, h = WS.GetFeed(LocalPlayer())
    if not mat then return end

    if not w or w <= 0 then w = 640 end
    if not h or h <= 0 then h = 480 end

    local dw = 320
    local dh = dw * (h / w)

    surface.SetMaterial(mat)
    surface.SetDrawColor(255, 255, 255, 255)
    surface.DrawTexturedRectUV(ScrW() - dw - 10, 10, dw, dh, u0, v0, u1, v1)
end)

hook.Add("PopulateToolMenu", "WebcamSettings", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "webcam_texture_settings", "Webcam", "", "", function(panel)
        panel:ClearControls()

        panel:Help("Spawn a Webcam Screen from the Webcam category. Whoever spawns it is the one it shows.")
        panel:Button("Start / open capture page", "webcam_start")
        panel:Button("Stop capture", "webcam_stop")

        local cv = GetConVar("sv_webcam_max_kbps")
        panel:Help("Server bandwidth limit: " .. (cv and cv:GetInt() or 48) ..
            " KB/s per streamer. Change it with sv_webcam_max_kbps on the server. " ..
            "Quality and frame rate follow it automatically.")

        panel:Help("Texture settings (for painting the feed onto props with the material tool):")
        panel:NumSlider("Scale", "webcam_tex_scale", 0.1, 10, 2)
        panel:NumSlider("Rotation", "webcam_tex_rotation", -180, 180, 1)
        panel:NumSlider("Offset X", "webcam_tex_offset_x", -1, 1, 3)
        panel:NumSlider("Offset Y", "webcam_tex_offset_y", -1, 1, 3)
        panel:CheckBox("Flip Horizontal", "webcam_tex_flip_h")
        panel:CheckBox("Flip Vertical", "webcam_tex_flip_v")
        panel:CheckBox("Tiling (repeat texture)", "webcam_tex_tile")

        panel:Button("Reset texture settings").DoClick = function()
            RunConsoleCommand("webcam_tex_scale", "1")
            RunConsoleCommand("webcam_tex_rotation", "0")
            RunConsoleCommand("webcam_tex_offset_x", "0")
            RunConsoleCommand("webcam_tex_offset_y", "0")
            RunConsoleCommand("webcam_tex_flip_h", "0")
            RunConsoleCommand("webcam_tex_flip_v", "0")
            RunConsoleCommand("webcam_tex_tile", "1")
        end
    end)
end)

-- Backwards compatible shim for anything that used the old API.
webcam_texture = webcam_texture or {}
function webcam_texture.GetMaterial() return (WS.GetFeed(LocalPlayer())) end
function webcam_texture.GetSize() return curW, curH end
function webcam_texture.GetUV()
    local _, _, _, u1, v1 = WS.GetFeed(LocalPlayer())
    return u1 or 1, v1 or 1
end
