include("shared.lua")

function ENT:Draw()
    self:DrawModel()

    if not webcam or not webcam.IsRunning or not webcam.IsRunning() then return end

    local s = self:GetScreenScale()
    if s <= 0 then s = 1 end

    local mat = webcam_texture and webcam_texture.GetMaterial and webcam_texture.GetMaterial()
    if not mat then return end

    local camW, camH = 640, 480
    if webcam_texture.GetSize then
        camW, camH = webcam_texture.GetSize()
    end
    if camW <= 0 then camW = 640 end
    if camH <= 0 then camH = 480 end

    local aspect = camW / camH
    local halfW = 40 * s
    local halfH = halfW / aspect

    local pos = self:GetPos()
    local ang = self:GetAngles()

    local drawPos = pos + ang:Forward() * self:GetOffsetY() + ang:Right() * self:GetOffsetX() + ang:Up() * self:GetOffsetZ()

    local surfAng = Angle(ang.p, ang.y, ang.r)
    surfAng:RotateAroundAxis(surfAng:Up(), self:GetRotY())
    surfAng:RotateAroundAxis(surfAng:Right(), self:GetRotX())
    surfAng:RotateAroundAxis(surfAng:Forward(), self:GetRotZ())

    cam.Start3D2D(drawPos, surfAng, 1)
        surface.SetMaterial(mat)
        surface.SetDrawColor(255, 255, 255)
        local u, v = 1, 1
        if webcam_texture.GetUV then u, v = webcam_texture.GetUV() end
        surface.DrawTexturedRectUV(-halfW, -halfH, halfW * 2, halfH * 2, 0, 0, u, v)
    cam.End3D2D()
end

function ENT:GetOverlayText()
    return "Webcam Screen"
end
