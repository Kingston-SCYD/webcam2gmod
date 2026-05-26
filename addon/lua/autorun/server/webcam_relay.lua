if SERVER then
    require("webcam")

    hook.Add("Initialize", "WebcamRelayStart", function()
        local port = GetConVar("hostport"):GetInt()
        webcam_relay.Start(port)
        print("[Webcam Relay] Started on TCP port " .. port)
    end)

    hook.Add("ShutDown", "WebcamRelayStop", function()
        webcam_relay.Stop()
    end)
end
