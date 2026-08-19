--[[--------------------------------------------------------------------------
    Webcam Screen - in-game settings menu

    Spawnmenu > Utilities > Webcam Screen.

    Client settings are plain client convars. The three that describe the
    outgoing feed (width/quality/fps) are pushed down to the capture page over
    the module's websocket, so you don't have to alt-tab to the browser to
    change them. The page's own controls still work; whichever was touched last
    wins, and the game re-pushes whenever a page connects.

    Server settings are read and written over a net message, guarded by IsAdmin.
--]]--------------------------------------------------------------------------

if SERVER then AddCSLuaFile() end

local MSG_ADMIN_GET = "webcam_screen_admin_get"
local MSG_ADMIN_VAL = "webcam_screen_admin_val"
local MSG_ADMIN_SET = "webcam_screen_admin_set"

-- name -> default, shared so both realms agree on what "reset" means
local SERVER_CVARS = {
    { name = "webcam_screen_enabled",  default = 1,     min = 0,    max = 1 },
    { name = "webcam_screen_range",    default = 2000,  min = 0,    max = 32768 },
    { name = "webcam_screen_fps",      default = 5,     min = 1,    max = 30 },
    { name = "webcam_screen_maxframe", default = 32000, min = 8000, max = 262144 },
    { name = "webcam_screen_maxrate",  default = 90000, min = 4000, max = 1000000 },
}

--[[==========================================================================
    SERVER
==========================================================================]]--

if SERVER then

util.AddNetworkString(MSG_ADMIN_GET)
util.AddNetworkString(MSG_ADMIN_VAL)
util.AddNetworkString(MSG_ADMIN_SET)

local function SendValues(ply)
    net.Start(MSG_ADMIN_VAL)
        for _, c in ipairs(SERVER_CVARS) do
            local cv = GetConVar(c.name)
            net.WriteUInt(cv and math.Clamp(cv:GetInt(), c.min, c.max) or c.default, 32)
        end
    net.Send(ply)
end

net.Receive(MSG_ADMIN_GET, function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    SendValues(ply)
end)

net.Receive(MSG_ADMIN_SET, function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then
        if IsValid(ply) then ply:ChatPrint("[Webcam] Admins only.") end
        return
    end

    for _, c in ipairs(SERVER_CVARS) do
        local v = math.Clamp(net.ReadUInt(32), c.min, c.max)
        local cv = GetConVar(c.name)
        if cv then cv:SetInt(v) end
    end

    ply:ChatPrint("[Webcam] Server settings updated.")
    SendValues(ply)
end)

end -- SERVER

--[[==========================================================================
    CLIENT
==========================================================================]]--

if CLIENT then

local CLIENT_CVARS = {
    { name = "webcam_screen_mp_width",         default = 320 },
    { name = "webcam_screen_mp_quality",       default = 45 },
    { name = "webcam_screen_mp_fps",           default = 5 },
    { name = "webcam_screen_chroma",           default = 0 },
    { name = "webcam_screen_chroma_r",         default = 0 },
    { name = "webcam_screen_chroma_g",         default = 255 },
    { name = "webcam_screen_chroma_b",         default = 0 },
    { name = "webcam_screen_chroma_threshold", default = 80 },
    { name = "webcam_screen_drawdistance",     default = 3000 },
    { name = "webcam_screen_maxstreams",       default = 4 },
}

CreateClientConVar("webcam_screen_mp_width", "320", true, false,
    "Width of the video sent to other players", 128, 640)
CreateClientConVar("webcam_screen_mp_quality", "45", true, false,
    "Compression quality of the video sent to other players", 10, 90)
CreateClientConVar("webcam_screen_mp_fps", "5", true, false,
    "How many frames per second to send to other players", 1, 15)
CreateClientConVar("webcam_screen_chroma", "0", true, false,
    "Key out a background colour")
CreateClientConVar("webcam_screen_chroma_r", "0", true, false, "Key colour red", 0, 255)
CreateClientConVar("webcam_screen_chroma_g", "255", true, false, "Key colour green", 0, 255)
CreateClientConVar("webcam_screen_chroma_b", "0", true, false, "Key colour blue", 0, 255)
CreateClientConVar("webcam_screen_chroma_threshold", "80", true, false,
    "How close a pixel must be to the key colour to be cut out", 10, 200)

-- These two are also created by their own files; CreateClientConVar just hands
-- back the existing one, so load order doesn't matter.
CreateClientConVar("webcam_screen_drawdistance", "3000", true, false,
    "Stop drawing webcam screens past this distance (0 = no limit)", 0, 16384)
CreateClientConVar("webcam_screen_maxstreams", "4", true, false,
    "How many remote camera feeds to decode at once", 1, 8)

--[[--------------------------------------------------------------------
    Pushing settings down to the capture page.
--]]--------------------------------------------------------------------

local function PushConfig()
    if not webcam or not webcam.SendToPage then return end
    if not webcam.IsRunning or not webcam.IsRunning() then return end

    webcam.SendToPage(string.format("netcfg:%d:%d:%d",
        GetConVar("webcam_screen_mp_width"):GetInt(),
        GetConVar("webcam_screen_mp_quality"):GetInt(),
        GetConVar("webcam_screen_mp_fps"):GetInt()))

    webcam.SendToPage(string.format("chromacfg:%d:%d:%d:%d:%d",
        GetConVar("webcam_screen_chroma"):GetBool() and 1 or 0,
        GetConVar("webcam_screen_chroma_r"):GetInt(),
        GetConVar("webcam_screen_chroma_g"):GetInt(),
        GetConVar("webcam_screen_chroma_b"):GetInt(),
        GetConVar("webcam_screen_chroma_threshold"):GetInt()))
end

-- Coalesce bursts of changes (dragging a slider fires the callback constantly).
local pushQueued = false
local function QueuePush()
    if pushQueued then return end
    pushQueued = true
    timer.Simple(0.15, function()
        pushQueued = false
        PushConfig()
    end)
end

for _, c in ipairs(CLIENT_CVARS) do
    if c.name ~= "webcam_screen_drawdistance" and c.name ~= "webcam_screen_maxstreams" then
        cvars.AddChangeCallback(c.name, QueuePush, "WebcamScreenMenuPush")
    end
end

-- Re-push whenever the browser page (re)connects, so opening it later still
-- picks up whatever the sliders say.
local pageWasConnected = false
timer.Create("WebcamScreenPagePoll", 1, 0, function()
    local connected = webcam and webcam.PageConnected and webcam.PageConnected() or false
    if connected and not pageWasConnected then PushConfig() end
    pageWasConnected = connected
end)

--[[--------------------------------------------------------------------
    The menu.
--]]--------------------------------------------------------------------

local function ResetClientDefaults()
    for _, c in ipairs(CLIENT_CVARS) do
        RunConsoleCommand(c.name, tostring(c.default))
    end
end

local function BuildAdminSection(panel)
    panel:Help("")
    panel:ControlHelp("Server settings (admin)")

    local rows = {}
    for _, c in ipairs(SERVER_CVARS) do
        local slider = panel:NumSlider(
            c.name:gsub("^webcam_screen_", ""):gsub("_", " "), "", c.min, c.max, 0)
        slider:SetValue(c.default)
        rows[#rows + 1] = { cvar = c, slider = slider }
    end

    local status = panel:ControlHelp("Requesting current values...")

    local function Send()
        net.Start(MSG_ADMIN_SET)
            for _, r in ipairs(rows) do
                net.WriteUInt(math.Clamp(math.floor(r.slider:GetValue()), r.cvar.min, r.cvar.max), 32)
            end
        net.SendToServer()
    end

    local apply = panel:Button("Apply to server")
    apply.DoClick = Send

    local reset = panel:Button("Reset server to defaults")
    reset.DoClick = function()
        for _, r in ipairs(rows) do r.slider:SetValue(r.cvar.default) end
        Send()
    end

    net.Receive(MSG_ADMIN_VAL, function()
        for _, r in ipairs(rows) do
            if IsValid(r.slider) then r.slider:SetValue(net.ReadUInt(32)) end
        end
        if IsValid(status) then status:SetText("Live server values.") end
    end)

    net.Start(MSG_ADMIN_GET)
    net.SendToServer()
end

hook.Add("PopulateToolMenu", "WebcamScreenSettings", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "webcam_screen_settings",
        "Webcam Screen", "", "", function(panel)
            panel:ClearControls()

            panel:Help("Your outgoing feed. These are pushed straight to the capture page, "
                .. "so there's no need to alt-tab to change them.")
            panel:NumSlider("Feed width", "webcam_screen_mp_width", 128, 640, 0)
            panel:NumSlider("Feed quality", "webcam_screen_mp_quality", 10, 90, 0)
            panel:NumSlider("Feed FPS", "webcam_screen_mp_fps", 1, 15, 0)

            panel:Help("Chroma key")
            panel:CheckBox("Key out a background colour", "webcam_screen_chroma")

            local mixer = vgui.Create("DColorMixer")
            mixer:SetTall(150)
            mixer:SetPalette(true)
            mixer:SetAlphaBar(false)
            mixer:SetWangs(true)
            mixer:SetConVarR("webcam_screen_chroma_r")
            mixer:SetConVarG("webcam_screen_chroma_g")
            mixer:SetConVarB("webcam_screen_chroma_b")
            mixer:SetColor(Color(
                GetConVar("webcam_screen_chroma_r"):GetInt(),
                GetConVar("webcam_screen_chroma_g"):GetInt(),
                GetConVar("webcam_screen_chroma_b"):GetInt()))
            panel:AddItem(mixer)

            panel:NumSlider("Key threshold", "webcam_screen_chroma_threshold", 10, 200, 0)
            panel:ControlHelp("Higher cuts more of the background - and more of you.")

            panel:Help("Viewing")
            panel:NumSlider("Draw distance", "webcam_screen_drawdistance", 0, 16384, 0)
            panel:NumSlider("Max remote feeds", "webcam_screen_maxstreams", 1, 8, 0)

            panel:Help("")
            local reset = panel:Button("Reset my settings to defaults")
            reset.DoClick = function()
                ResetClientDefaults()
                timer.Simple(0.1, function()
                    if IsValid(mixer) then
                        mixer:SetColor(Color(0, 255, 0))
                    end
                end)
            end

            local status = panel:Button("Show stream status in console")
            status.DoClick = function() RunConsoleCommand("webcam_stream_status") end

            if LocalPlayer():IsAdmin() then
                BuildAdminSection(panel)
            end
        end)
end)

concommand.Add("webcam_screen_reset", function()
    ResetClientDefaults()
    MsgN("[Webcam] Settings reset to defaults.")
end)

end -- CLIENT
