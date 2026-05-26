ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Webcam Screen"
ENT.Category = "Webcam"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.Editable = true

function ENT:SetupDataTables()
    self:NetworkVar("Float", 0, "ScreenScale", {
        KeyName = "screen_scale",
        Edit = { type = "Float", order = 1, min = 0.25, max = 10, title = "Size" }
    })
    self:NetworkVar("Float", 1, "OffsetX", {
        KeyName = "offset_x",
        Edit = { type = "Float", order = 2, min = -50, max = 50, title = "Offset X" }
    })
    self:NetworkVar("Float", 2, "OffsetY", {
        KeyName = "offset_y",
        Edit = { type = "Float", order = 3, min = -50, max = 50, title = "Offset Y (Fwd)" }
    })
    self:NetworkVar("Float", 3, "OffsetZ", {
        KeyName = "offset_z",
        Edit = { type = "Float", order = 4, min = -50, max = 50, title = "Offset Z (Up)" }
    })
    self:NetworkVar("Float", 4, "RotX", {
        KeyName = "rot_x",
        Edit = { type = "Float", order = 5, min = -180, max = 180, title = "Rotation Pitch" }
    })
    self:NetworkVar("Float", 5, "RotY", {
        KeyName = "rot_y",
        Edit = { type = "Float", order = 6, min = -180, max = 180, title = "Rotation Yaw" }
    })
    self:NetworkVar("Float", 6, "RotZ", {
        KeyName = "rot_z",
        Edit = { type = "Float", order = 7, min = -180, max = 180, title = "Rotation Roll" }
    })
end
