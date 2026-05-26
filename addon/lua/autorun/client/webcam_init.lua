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

hook.Add("PostRender", "WebcamRT", function()
    if not IsValid(WebcamPanel) then return end
    local htmlMat = WebcamPanel:GetHTMLMaterial()
    if not htmlMat then return end
    local tex = htmlMat:GetTexture("$basetexture")
    if not tex then return end
    local texW, texH = tex:Width(), tex:Height()
    local u = 640 / texW
    local v = 480 / texH

    render.PushRenderTarget(RT)
    render.Clear(0, 0, 0, 0)
    render.SetViewPort(0, 0, 1024, 1024)
    cam.Start2D()
        render.SetMaterial(htmlMat)
        mesh.Begin(MATERIAL_QUADS, 1)
            mesh.Position(Vector(0, 0, 0))       mesh.TexCoord(0, 0, 0) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
            mesh.Position(Vector(1024, 0, 0))    mesh.TexCoord(0, u, 0) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
            mesh.Position(Vector(1024, 1024, 0)) mesh.TexCoord(0, u, v) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
            mesh.Position(Vector(0, 1024, 0))    mesh.TexCoord(0, 0, v) mesh.Color(255,255,255,255) mesh.AdvanceVertex()
        mesh.End()
    cam.End2D()
    render.SetViewPort(0, 0, ScrW(), ScrH())
    render.PopRenderTarget()
end)

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
