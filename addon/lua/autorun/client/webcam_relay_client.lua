-- Multiplayer webcam relay client
-- Auto-connects to server's TCP relay and exchanges frames

local relayConnected = false
local remotePlayerMats = {}

local function ConnectToRelay()
    if not webcam or not webcam.RelayConnect then return end
    if webcam.RelayIsConnected() then return end

    local serverIP = game.GetIPAddress()
    if not serverIP or serverIP == "" or serverIP == "loopback" then return end

    local ip, port = string.match(serverIP, "(.+):(%d+)")
    if not ip or not port then return end

    local steamid = LocalPlayer():SteamID64()
    if webcam.RelayConnect(ip, tonumber(port), steamid) then
        relayConnected = true
        print("[Webcam Relay] Connected to " .. ip .. ":" .. port)
    end
end

-- Auto-connect when joining a server
hook.Add("InitPostEntity", "WebcamRelayConnect", function()
    timer.Simple(3, ConnectToRelay)
end)

-- Send our frame to relay periodically
local lastRelaySend = 0
hook.Add("Think", "WebcamRelaySend", function()
    if not relayConnected then return end
    if not webcam.IsRunning() then return end
    if not webcam.RelayIsConnected() then
        relayConnected = false
        return
    end
    if RealTime() - lastRelaySend < 0.05 then return end -- 20fps to relay
    lastRelaySend = RealTime()

    local steamid = LocalPlayer():SteamID64()
    webcam.RelaySendFrame(steamid)
end)

-- Receive remote frames and write to per-player files
hook.Add("Think", "WebcamRelayRecv", function()
    if not relayConnected then return end
    if not webcam.RelayIsConnected() then return end

    for _, ply in ipairs(player.GetAll()) do
        if ply ~= LocalPlayer() then
            local sid = ply:SteamID64()
            local frame = webcam.RelayGetFrame(sid)
            if frame then
                file.Write("webcam_remote_" .. sid .. ".dat", frame)
            end
        end
    end
end)

-- Public API for getting remote player materials
webcam_remote = webcam_remote or {}

function webcam_remote.GetPanel(steamid64)
    if not remotePlayerMats[steamid64] then
        local panel = vgui.Create("DHTML")
        panel:SetSize(640, 480)
        panel:SetVisible(false)
        panel:SetHTML([[<html><body style="margin:0;background:#000">
<img id="f" style="width:100%;height:100%">
<script>var t=0;function F(){document.getElementById('f').src='asset://garrysmod/data/webcam_remote_]] .. steamid64 .. [[.dat?t='+(t++);setTimeout(F,50);}F();</script>
</body></html>]])
        remotePlayerMats[steamid64] = panel
    end
    return remotePlayerMats[steamid64]
end

function webcam_remote.GetMaterial(steamid64)
    local panel = webcam_remote.GetPanel(steamid64)
    if not IsValid(panel) then return nil end
    return panel:GetHTMLMaterial()
end

-- Cleanup
hook.Add("ShutDown", "WebcamRelayDisconnect", function()
    if webcam and webcam.RelayDisconnect then
        webcam.RelayDisconnect()
    end
    for _, panel in pairs(remotePlayerMats) do
        if IsValid(panel) then panel:Remove() end
    end
end)
