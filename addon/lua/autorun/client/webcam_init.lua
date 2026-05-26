require("webcam")

local WebcamPanel = nil
local panelReady = false
local lastUpdate = 0
local PANEL_W, PANEL_H = 640, 480

-- RT name matches the VMT $basetexture so "webcam" appears in material browser
local RT = GetRenderTargetEx("webcam_feed", 1024, 1024, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 2, 0, IMAGE_FORMAT_RGBA8888)

local function InitPanel()
    if IsValid(WebcamPanel) then WebcamPanel:Remove() end
    panelReady = false
    WebcamPanel = vgui.Create("DHTML")
    WebcamPanel:SetSize(PANEL_W, PANEL_H)
    WebcamPanel:SetVisible(false)
    WebcamPanel:SetHTML([[<html><body style="margin:0;overflow:hidden;background:#000">
<canvas id="c" width="]] .. PANEL_W .. [[" height="]] .. PANEL_H .. [["></canvas>
<script>var c=document.getElementById("c"),ctx=c.getContext("2d");
var img=new Image();
img.onload=function(){ctx.drawImage(img,0,0,]] .. PANEL_W .. [[,]] .. PANEL_H .. [[);};
function F(d){img.src="data:image/jpeg;base64,"+d;}
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

    local b64 = util.Base64Encode(data)
    b64 = string.gsub(b64, "%s", "")
    WebcamPanel:RunJavascript("F('" .. b64 .. "')")
    WebcamPanel:UpdateHTMLTexture()
end)

hook.Add("PostRender", "WebcamRT", function()
    if not IsValid(WebcamPanel) then return end
    local htmlMat = WebcamPanel:GetHTMLMaterial()
    if not htmlMat then return end

    local tex = htmlMat:GetTexture("$basetexture")
    if not tex then return end

    local texW, texH = tex:Width(), tex:Height()
    local u = PANEL_W / texW
    local v = PANEL_H / texH

    render.PushRenderTarget(RT)
    render.Clear(0, 0, 0, 255)
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
    return WebcamPanel:GetHTMLMaterial()
end
function webcam_texture.GetSize() return PANEL_W, PANEL_H end
function webcam_texture.GetUV()
    if not IsValid(WebcamPanel) then return 1, 1 end
    local mat = WebcamPanel:GetHTMLMaterial()
    if not mat then return 1, 1 end
    local tex = mat:GetTexture("$basetexture")
    if not tex then return 1, 1 end
    return PANEL_W / tex:Width(), PANEL_H / tex:Height()
end

-- Commands
concommand.Add("webcam_start", function(_, _, args)
    local port = tonumber(args[1]) or 27099
    InitPanel()
    webcam.Start(port)
    print("[Webcam] Started - open http://127.0.0.1:" .. port .. " in your browser")
    print("[Webcam] Use material 'webcam' in the toolgun")
end)

concommand.Add("webcam_stop", function()
    webcam.Stop()
    if IsValid(WebcamPanel) then WebcamPanel:Remove() end
    WebcamPanel = nil
    panelReady = false
    print("[Webcam] Stopped")
end)

-- HUD preview
local showHUD = false
concommand.Add("webcam_hud", function() showHUD = not showHUD end)
hook.Add("HUDPaint", "WebcamHUD", function()
    if not showHUD then return end
    local mat = Material("webcam")
    surface.SetMaterial(mat)
    surface.SetDrawColor(255, 255, 255)
    surface.DrawTexturedRect(ScrW() - 330, 10, 320, 240)
end)
