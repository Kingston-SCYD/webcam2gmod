include("shared.lua")

local DRAW_RANGE_SQR = 4000 * 4000

function ENT:RenderScreen()
    -- The engine may call both Draw and DrawTranslucent for this entity
    -- depending on render mode, so make sure we only run once per frame.
    if self._lastRenderFrame == FrameNumber() then return end
    self._lastRenderFrame = FrameNumber()

    self:DrawModel()

    local pos = self:GetPos()
    if pos:DistToSqr(EyePos()) > DRAW_RANGE_SQR then return end

    local streamer = self:GetStreamer()
    if not IsValid(streamer) then return end
    if not webcam_screens then return end

    local s = self:GetScreenScale()
    if s <= 0 then s = 1 end

    local ang = self:GetAngles()
    local drawPos = pos
        + ang:Forward() * self:GetOffsetY()
        + ang:Right() * self:GetOffsetX()
        + ang:Up() * self:GetOffsetZ()

    local surfAng = Angle(ang.p, ang.y, ang.r)
    surfAng:RotateAroundAxis(surfAng:Up(), self:GetRotY())
    surfAng:RotateAroundAxis(surfAng:Right(), self:GetRotX())
    surfAng:RotateAroundAxis(surfAng:Forward(), self:GetRotZ())

    local mat, u0, v0, u1, v1, camW, camH = webcam_screens.GetFeed(streamer)

    if not mat then
        -- Only nag the owner, so they know their own screen has no signal.
        if streamer ~= LocalPlayer() then return end

        cam.Start3D2D(drawPos, surfAng, 0.1 * s)
            draw.SimpleText("No webcam signal - type webcam_start in console",
                "DermaLarge", 0, 0, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        cam.End3D2D()
        return
    end

    if not camW or camW <= 0 then camW = 640 end
    if not camH or camH <= 0 then camH = 480 end

    local halfW = 40 * s
    local halfH = halfW / (camW / camH)

    cam.Start3D2D(drawPos, surfAng, 1)
        surface.SetMaterial(mat)
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRectUV(-halfW, -halfH, halfW * 2, halfH * 2, u0, v0, u1, v1)
    cam.End3D2D()
end

function ENT:Draw()
    self:RenderScreen()
end

function ENT:DrawTranslucent()
    self:RenderScreen()
end

function ENT:GetOverlayText()
    return "Webcam Screen (" .. self:GetStreamerName() .. ")"
end
