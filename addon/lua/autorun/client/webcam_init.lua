require("webcam")

local WebcamPanel = nil
local panelReady = false
local lastUpdate = 0
local curW, curH = 640, 480
local WebcamMat = nil

local function InitPanel()
    if IsValid(WebcamPanel) then WebcamPanel:Remove() end
    panelReady = false
    WebcamMat = nil
    WebcamPanel = vgui.Create("DHTML")
    WebcamPanel:SetSize(640, 480)
    WebcamPanel:SetVisible(false)
    WebcamPanel:SetHTML([[<html><body style="margin:0;background:transparent">
<img id="f" style="width:100%;height:100%">
<script>
var t=0;
function F(){document.getElementById('f').src='asset://garrysmod/data/webcam_frame.dat?t='+(t++);setTimeout(F,16);}
F();
</script></body></html>]])
    timer.Simple(0.5, function()
        if IsValid(WebcamPanel) then panelReady = true end
    end)
end

hook.Add("Think", "WebcamUpdate", function()
    if not IsValid(WebcamPanel) then return end
    if not panelReady then return end
    if not webcam.IsRunning() then return end
    if RealTime() - lastUpdate < 0.016 then return end
    lastUpdate = RealTime()

    local data, w, h = webcam.GetFrame()
    if not data then return end
    if w > 0 and h > 0 then curW, curH = w, h end

    file.Write("webcam_frame.dat", data)
    WebcamPanel:UpdateHTMLTexture()
    WebcamMat = nil
end)

local RT = GetRenderTargetEx("webcam_feed", 1024, 1024, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 2, 0, IMAGE_FORMAT_RGBA8888)

-- Texture transform settings (saved between sessions)
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
    if not IsValid(WebcamPanel) then return end
    local htmlMat = WebcamPanel:GetHTMLMaterial()
    if not htmlMat then return end
    local tex = htmlMat:GetTexture("$basetexture")
    if not tex then return end
    local texW, texH = tex:Width(), tex:Height()
    local baseU = 640 / texW
    local baseV = 480 / texH

    local scale = GetConVar("webcam_tex_scale"):GetFloat()
    local rot = GetConVar("webcam_tex_rotation"):GetFloat()
    local offX = GetConVar("webcam_tex_offset_x"):GetFloat()
    local offY = GetConVar("webcam_tex_offset_y"):GetFloat()
    local flipH = GetConVar("webcam_tex_flip_h"):GetBool()
    local flipV = GetConVar("webcam_tex_flip_v"):GetBool()
    local tiling = GetConVar("webcam_tex_tile"):GetBool()

    -- Scale: larger value = texture appears bigger on the object = sample less UV range
    local uvW = baseU / scale
    local uvH = baseV / scale
    local ucx = baseU * 0.5 + offX * baseU
    local vcy = baseV * 0.5 + offY * baseV
    local u0, u1 = ucx - uvW * 0.5, ucx + uvW * 0.5
    local v0, v1 = vcy - uvH * 0.5, vcy + uvH * 0.5

    if flipH then u0, u1 = u1, u0 end
    if flipV then v0, v1 = v1, v0 end

    -- When tiling is off, we only draw the portion with valid UVs
    -- (the RT is already cleared to transparent, so the rest stays empty)

    -- Rotate quad corners around center
    local cx, cy = 512, 512
    local x0, y0 = RotatePoint(0, 0, cx, cy, rot)
    local x1, y1 = RotatePoint(1024, 0, cx, cy, rot)
    local x2, y2 = RotatePoint(1024, 1024, cx, cy, rot)
    local x3, y3 = RotatePoint(0, 1024, cx, cy, rot)

    render.PushRenderTarget(RT)
    render.Clear(0, 0, 0, 0)
    render.SetViewPort(0, 0, 1024, 1024)
    cam.Start2D()
        render.SetMaterial(htmlMat)

        if not tiling then
            render.OverrideDepthEnable(true, false)
            -- Clamp: only draw the portion where UVs are within valid range
            -- This effectively makes texture show once with no repeat
            local clampU0 = math.Clamp(u0, 0, baseU)
            local clampU1 = math.Clamp(u1, 0, baseU)
            local clampV0 = math.Clamp(v0, 0, baseV)
            local clampV1 = math.Clamp(v1, 0, baseV)

            -- Map clamped UVs back to screen positions
            local fracL = (u1 ~= u0) and (clampU0 - u0) / (u1 - u0) or 0
            local fracR = (u1 ~= u0) and (clampU1 - u0) / (u1 - u0) or 1
            local fracT = (v1 ~= v0) and (clampV0 - v0) / (v1 - v0) or 0
            local fracB = (v1 ~= v0) and (clampV1 - v0) / (v1 - v0) or 1

            -- Interpolate rotated corners
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

-- Settings panel
local function OpenSettings()
    if IsValid(webcam_settings_frame) then webcam_settings_frame:Remove() end

    local f = vgui.Create("DFrame")
    f:SetTitle("Webcam Texture Settings")
    f:SetSize(340, 320)
    f:Center()
    f:MakePopup()
    f:SetDeleteOnClose(true)
    webcam_settings_frame = f

    local list = vgui.Create("DScrollPanel", f)
    list:Dock(FILL)

    local function AddSlider(label, convar, min, max, decimals)
        local s = vgui.Create("DNumSlider", list)
        s:Dock(TOP)
        s:DockMargin(0, 0, 0, 2)
        s:SetText(label)
        s:SetMin(min)
        s:SetMax(max)
        s:SetDecimals(decimals)
        s:SetConVar(convar)
        return s
    end

    AddSlider("Scale", "webcam_tex_scale", 0.1, 10, 2)
    AddSlider("Rotation", "webcam_tex_rotation", -180, 180, 1)
    AddSlider("Offset X", "webcam_tex_offset_x", -1, 1, 3)
    AddSlider("Offset Y", "webcam_tex_offset_y", -1, 1, 3)

    local flipH = vgui.Create("DCheckBoxLabel", list)
    flipH:Dock(TOP)
    flipH:DockMargin(0, 6, 0, 0)
    flipH:SetText("Flip Horizontal")
    flipH:SetConVar("webcam_tex_flip_h")

    local flipV = vgui.Create("DCheckBoxLabel", list)
    flipV:Dock(TOP)
    flipV:DockMargin(0, 4, 0, 0)
    flipV:SetText("Flip Vertical")
    flipV:SetConVar("webcam_tex_flip_v")

    local tile = vgui.Create("DCheckBoxLabel", list)
    tile:Dock(TOP)
    tile:DockMargin(0, 4, 0, 0)
    tile:SetText("Tiling (repeat texture)")
    tile:SetConVar("webcam_tex_tile")

    local reset = vgui.Create("DButton", list)
    reset:Dock(TOP)
    reset:DockMargin(0, 12, 0, 0)
    reset:SetText("Reset to Defaults")
    reset.DoClick = function()
        RunConsoleCommand("webcam_tex_scale", "1")
        RunConsoleCommand("webcam_tex_rotation", "0")
        RunConsoleCommand("webcam_tex_offset_x", "0")
        RunConsoleCommand("webcam_tex_offset_y", "0")
        RunConsoleCommand("webcam_tex_flip_h", "0")
        RunConsoleCommand("webcam_tex_flip_v", "0")
        RunConsoleCommand("webcam_tex_tile", "1")
    end
end
concommand.Add("webcam_settings", OpenSettings)

-- Public API
webcam_texture = webcam_texture or {}
function webcam_texture.GetMaterial()
    if not IsValid(WebcamPanel) then return nil end
    if not WebcamMat then WebcamMat = WebcamPanel:GetHTMLMaterial() end
    return WebcamMat
end
function webcam_texture.GetSize() return curW, curH end
function webcam_texture.GetUV()
    if not IsValid(WebcamPanel) then return 1, 1 end
    local mat = WebcamPanel:GetHTMLMaterial()
    if not mat then return 1, 1 end
    local tex = mat:GetTexture("$basetexture")
    if not tex then return 1, 1 end
    return 640 / tex:Width(), 480 / tex:Height()
end

-- Commands
concommand.Add("webcam_start", function(_, _, args)
    local port = tonumber(args[1]) or 27099
    InitPanel()
    webcam.Start(port)
    print("[Webcam] Started - open http://127.0.0.1:" .. port .. " in your browser")
end)

concommand.Add("webcam_stop", function()
    webcam.Stop()
    if IsValid(WebcamPanel) then WebcamPanel:Remove() end
    WebcamPanel, WebcamMat = nil, nil
    panelReady = false
    print("[Webcam] Stopped")
end)

-- HUD preview
local showHUD = false
concommand.Add("webcam_hud", function() showHUD = not showHUD end)
hook.Add("HUDPaint", "WebcamHUD", function()
    if not showHUD then return end
    local mat = webcam_texture.GetMaterial()
    if not mat then return end
    surface.SetMaterial(mat)
    surface.SetDrawColor(255, 255, 255)
    local scale = 320 / curW
    surface.DrawTexturedRect(ScrW() - curW * scale - 10, 10, curW * scale, curH * scale)
end)
