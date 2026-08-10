#include "GarrysMod/Lua/Interface.h"
#include <mutex>
#include <thread>
#include <atomic>
#include <vector>
#include <string>
#include <cstring>
#include <cstdint>
#include <map>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
typedef SOCKET socket_t;
#define CLOSESOCKET closesocket
#define SOCKET_ERROR_VAL INVALID_SOCKET
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <arpa/inet.h>
typedef int socket_t;
#define CLOSESOCKET close
#define SOCKET_ERROR_VAL (-1)
#define INVALID_SOCKET (-1)
#endif

#include "httplib.h"
#include "websocket.h"

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

using namespace GarrysMod::Lua;

static httplib::Server* g_server = nullptr;
static std::thread g_serverThread;
static std::thread g_wsThread;
static std::atomic<bool> g_running(false);
static std::mutex g_frameMutex;
static std::vector<unsigned char> g_frameData;
static std::vector<unsigned char> g_rgbaData;
static int g_frameWidth = 0, g_frameHeight = 0;
static int g_port = 27099;
static socket_t g_wsListenSock = INVALID_SOCKET;

// Chroma key settings
static std::atomic<bool> g_chromaEnabled(false);
static std::atomic<int> g_chromaR(0), g_chromaG(255), g_chromaB(0);
static std::atomic<int> g_chromaThreshold(80);

// Embedded HTML page (served at /)
static const char* HTML_PAGE = R"HTML(
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>GMod Webcam</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:#111;color:#eee;font-family:system-ui;display:flex;flex-direction:column;align-items:center;padding:20px;gap:12px}
canvas{border:2px solid #333;border-radius:4px;max-width:100%;display:none;background:repeating-conic-gradient(#808080 0% 25%,#404040 0% 50%) 50%/16px 16px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:center}
select,button{background:#222;color:#eee;border:1px solid #444;padding:8px 16px;border-radius:4px;cursor:pointer;font-size:14px}
button{background:#1a7;font-weight:bold}
button:hover{background:#2b8}
#status{padding:6px 14px;border-radius:4px;font-size:13px}
.on{background:#1a7;color:#fff}.off{background:#a33;color:#fff}.wait{background:#a80;color:#fff}
</style></head><body>
<h2>GMod Webcam Stream</h2>
<button id="camBtn" style="font-size:18px;padding:12px 24px">Allow Camera Access</button>
<canvas id="c"></canvas>
<div class="row" id="controls" style="display:none">
<label>Res: <select id="res">
<option value="640x480">480p</option>
<option value="1280x720">720p</option>
<option value="1920x1080">1080p</option>
</select></label>
<label>FPS: <select id="fps">
<option value="10">10</option>
<option value="15">15</option>
<option value="20">20</option>
<option value="30" selected>30</option>
</select></label>
<label>Quality: <input type="range" id="qual" min="10" max="100" value="75" style="width:80px"><span id="qualVal">75%</span></label>
</div>
<div class="row" id="chromaRow" style="display:none">
<label>Chroma Key: <input type="checkbox" id="chromaOn"></label>
<label>Color: <span id="colorSwatch" style="display:inline-block;width:20px;height:20px;background:#00ff00;border:1px solid #fff;vertical-align:middle"></span> <button id="pickBtn">Pick from preview</button></label>
<label>Threshold: <input type="range" id="chromaThr" min="10" max="200" value="80" style="width:80px"><span id="thrVal">80</span></label>
</div>
<div id="status" class="off">Click the button above to start</div>
<video id="v" autoplay playsinline style="display:none"></video>
<script>
var C=document.getElementById('c'),X=C.getContext('2d'),V=document.getElementById('v');
var S=document.getElementById('status'),camBtn=document.getElementById('camBtn');
var controls=document.getElementById('controls');
var ws=null,timer=null,streaming=false,jpegQuality=0.75;

function log(msg,cls){S.textContent=msg;S.className=cls||'off';}

function wsConnect(){
  var port=parseInt(location.port)+1;
  var url='ws://127.0.0.1:'+port;
  log('Connecting to GMod...','wait');
  try{ws=new WebSocket(url);}catch(e){log('WebSocket error: '+e.message,'off');return;}
  ws.binaryType='arraybuffer';
  ws.onopen=function(){
    log('Connected - Streaming '+V.videoWidth+'x'+V.videoHeight,'on');
    ws.send(V.videoWidth+'x'+V.videoHeight);
    startSend();
  };
  ws.onclose=function(){
    log('Disconnected - retrying...','off');
    stopSend();
    setTimeout(wsConnect,2000);
  };
  ws.onerror=function(){try{ws.close();}catch(e){}};
}

function startSend(){
  stopSend();
  var fps=parseInt(document.getElementById('fps').value)||30;
  timer=setInterval(function(){
    if(!ws||ws.readyState!==1||V.readyState<2)return;
    X.drawImage(V,0,0,C.width,C.height);
    if(document.getElementById('chromaOn').checked){
      var id=X.getImageData(0,0,C.width,C.height);
      var d=id.data,thr2=document.getElementById('chromaThr').value*document.getElementById('chromaThr').value;
      for(var i=0;i<d.length;i+=4){
        var dr=d[i]-chromaR,dg=d[i+1]-chromaG,db=d[i+2]-chromaB;
        if(dr*dr+dg*dg+db*db<thr2)d[i+3]=0;
      }
      X.putImageData(id,0,0);
    }
    var fmt=document.getElementById('chromaOn').checked?'image/webp':'image/jpeg';
    var q=document.getElementById('chromaOn').checked?0.75:jpegQuality;
    C.toBlob(function(b){
      if(!b||!ws||ws.readyState!==1)return;
      if(b.arrayBuffer){b.arrayBuffer().then(function(a){if(ws&&ws.readyState===1)ws.send(a);});}
      else{var r=new FileReader();r.onload=function(){if(ws&&ws.readyState===1)ws.send(r.result);};r.readAsArrayBuffer(b);}
    },fmt,q);
  },Math.floor(1000/fps));
}

function stopSend(){if(timer){clearInterval(timer);timer=null;}}

camBtn.onclick=async function(){
  try{
    stopSend();
    if(ws){try{ws.onclose=null;ws.close();}catch(e){}ws=null;}
    log('Requesting camera...','wait');
    if(V.srcObject)V.srcObject.getTracks().forEach(function(t){t.stop();});
    var r=document.getElementById('res').value.split('x');
    var stream=await navigator.mediaDevices.getUserMedia({video:{width:{ideal:parseInt(r[0])},height:{ideal:parseInt(r[1])}}});
    V.srcObject=stream;
    await V.play();
    C.width=V.videoWidth;
    C.height=V.videoHeight;
    C.style.display='block';
    controls.style.display='flex';
    document.getElementById('chromaRow').style.display='flex';
    camBtn.textContent='Restart Camera';
    streaming=true;
    log('Camera active: '+V.videoWidth+'x'+V.videoHeight+' - connecting...','wait');
    wsConnect();
  }catch(e){
    log('Camera denied or error: '+e.message,'off');
  }
};

document.getElementById('res').onchange=function(){if(streaming)camBtn.onclick();};
document.getElementById('fps').onchange=function(){startSend();};
document.getElementById('qual').oninput=function(){jpegQuality=this.value/100;document.getElementById('qualVal').textContent=this.value+'%';};
function sendChroma(){
  if(!ws||ws.readyState!==1)return;
  var on=document.getElementById('chromaOn').checked;
  var t=document.getElementById('chromaThr').value;
  ws.send('chroma:'+on+':'+chromaR+':'+chromaG+':'+chromaB+':'+t);
}
var chromaR=0,chromaG=255,chromaB=0,picking=false;
document.getElementById('chromaOn').onchange=sendChroma;
document.getElementById('chromaThr').oninput=function(){document.getElementById('thrVal').textContent=this.value;sendChroma();};
document.getElementById('pickBtn').onclick=function(){picking=true;C.style.cursor='crosshair';};
C.onclick=function(e){
  if(!picking)return;
  picking=false;C.style.cursor='default';
  var rect=C.getBoundingClientRect();
  var x=Math.floor((e.clientX-rect.left)*(C.width/rect.width));
  var y=Math.floor((e.clientY-rect.top)*(C.height/rect.height));
  var p=X.getImageData(x,y,1,1).data;
  chromaR=p[0];chromaG=p[1];chromaB=p[2];
  document.getElementById('colorSwatch').style.background='rgb('+chromaR+','+chromaG+','+chromaB+')';
  sendChroma();
};
</script></body></html>
)HTML";

// WebSocket server thread - accepts one client and receives binary frames
static void WebSocketThread() {
    g_wsListenSock = socket(AF_INET, SOCK_STREAM, 0);
    if (g_wsListenSock == INVALID_SOCKET) return;

    int opt = 1;
    setsockopt(g_wsListenSock, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(g_port + 1);

    if (bind(g_wsListenSock, (sockaddr*)&addr, sizeof(addr)) < 0) {
        CLOSESOCKET(g_wsListenSock);
        g_wsListenSock = INVALID_SOCKET;
        return;
    }
    listen(g_wsListenSock, 2);

    while (g_running) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(g_wsListenSock, &fds);
        timeval tv{1, 0};
        if (select((int)g_wsListenSock + 1, &fds, nullptr, nullptr, &tv) <= 0) continue;

        socket_t client = accept(g_wsListenSock, nullptr, nullptr);
        if (client == INVALID_SOCKET) continue;

        if (!ws_handshake(client)) {
            CLOSESOCKET(client);
            continue;
        }

        // Read frames
        while (g_running) {
            std::vector<unsigned char> payload;
            int opcode = ws_read_frame(client, payload);
            if (opcode < 0) break;
            if (opcode == 0x8) break;
            if (opcode == 0x2 && !payload.empty()) {
                int w = 0, h = 0, channels = 0;
                unsigned char* pixels = stbi_load_from_memory(
                    payload.data(), (int)payload.size(), &w, &h, &channels, 4);
                if (pixels) {
                    // Apply chroma key if enabled
                    if (g_chromaEnabled) {
                        int kr = g_chromaR, kg = g_chromaG, kb = g_chromaB;
                        int thr2 = g_chromaThreshold * g_chromaThreshold;
                        for (int i = 0; i < w * h * 4; i += 4) {
                            int dr = pixels[i] - kr;
                            int dg = pixels[i+1] - kg;
                            int db = pixels[i+2] - kb;
                            if (dr*dr + dg*dg + db*db < thr2)
                                pixels[i+3] = 0;
                        }
                    }
                    std::lock_guard<std::mutex> lock(g_frameMutex);
                    g_frameWidth = w;
                    g_frameHeight = h;
                    g_rgbaData.assign(pixels, pixels + w * h * 4);
                    g_frameData = std::move(payload);
                    stbi_image_free(pixels);
                } else {
                    std::lock_guard<std::mutex> lock(g_frameMutex);
                    g_frameData = std::move(payload);
                }
            }
            if (opcode == 0x1 && !payload.empty()) {
                std::string msg(payload.begin(), payload.end());
                if (msg.rfind("chroma:", 0) == 0) {
                    // chroma:true:R:G:B:threshold
                    auto parts = msg.substr(7);
                    bool enabled = parts.rfind("true", 0) == 0;
                    g_chromaEnabled = enabled;
                    if (enabled) {
                        size_t p1 = parts.find(':', 0);
                        size_t p2 = parts.find(':', p1+1);
                        size_t p3 = parts.find(':', p2+1);
                        size_t p4 = parts.find(':', p3+1);
                        size_t p5 = parts.find(':', p4+1);
                        if (p5 != std::string::npos) {
                            g_chromaR = std::stoi(parts.substr(p2+1, p3-p2-1));
                            g_chromaG = std::stoi(parts.substr(p3+1, p4-p3-1));
                            g_chromaB = std::stoi(parts.substr(p4+1, p5-p4-1));
                            g_chromaThreshold = std::stoi(parts.substr(p5+1));
                        }
                    }
                } else {
                    auto x = msg.find('x');
                    if (x != std::string::npos) {
                        std::lock_guard<std::mutex> lock(g_frameMutex);
                        g_frameWidth = std::stoi(msg.substr(0, x));
                        g_frameHeight = std::stoi(msg.substr(x + 1));
                    }
                }
            }
        }
        CLOSESOCKET(client);
    }

    CLOSESOCKET(g_wsListenSock);
    g_wsListenSock = INVALID_SOCKET;
}

// webcam.Start(port?) -> bool
LUA_FUNCTION(Webcam_Start) {
    if (g_running) { LUA->PushBool(true); return 1; }

    if (LUA->IsType(1, GarrysMod::Lua::Type::Number))
        g_port = (int)LUA->GetNumber(1);

#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif

    g_running = true;

    // Start HTTP server
    g_server = new httplib::Server();
    g_server->Get("/", [](const httplib::Request&, httplib::Response& res) {
        res.set_content(HTML_PAGE, "text/html");
    });

    g_serverThread = std::thread([] {
        g_server->listen("0.0.0.0", g_port);
    });

    // Start WebSocket server on port+1
    g_wsThread = std::thread(WebSocketThread);

    LUA->PushBool(true);
    return 1;
}

// webcam.Stop()
LUA_FUNCTION(Webcam_Stop) {
    g_running = false;
    if (g_server) { g_server->stop(); }
    if (g_wsListenSock != INVALID_SOCKET) {
        CLOSESOCKET(g_wsListenSock);
        g_wsListenSock = INVALID_SOCKET;
    }
    if (g_serverThread.joinable()) g_serverThread.join();
    if (g_wsThread.joinable()) g_wsThread.join();
    delete g_server; g_server = nullptr;

    std::lock_guard<std::mutex> lock(g_frameMutex);
    g_frameData.clear();

#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}

// webcam.GetFrame() -> string|false, width, height
LUA_FUNCTION(Webcam_GetFrame) {
    std::lock_guard<std::mutex> lock(g_frameMutex);
    if (g_frameData.empty()) { LUA->PushBool(false); return 1; }
    LUA->PushString((const char*)g_frameData.data(), g_frameData.size());
    LUA->PushNumber(g_frameWidth);
    LUA->PushNumber(g_frameHeight);
    return 3;
}

// webcam.GetPixels() -> string|false, width, height (raw RGBA)
LUA_FUNCTION(Webcam_GetPixels) {
    std::lock_guard<std::mutex> lock(g_frameMutex);
    if (g_rgbaData.empty()) { LUA->PushBool(false); return 1; }
    LUA->PushString((const char*)g_rgbaData.data(), g_rgbaData.size());
    LUA->PushNumber(g_frameWidth);
    LUA->PushNumber(g_frameHeight);
    return 3;
}

// webcam.IsRunning() -> bool
LUA_FUNCTION(Webcam_IsRunning) {
    LUA->PushBool(g_running.load());
    return 1;
}

// webcam.GetPort() -> number
LUA_FUNCTION(Webcam_GetPort) {
    LUA->PushNumber(g_port);
    return 1;
}

// webcam.WriteFrame(path) -> bool (writes current RGBA as TGA)
LUA_FUNCTION(Webcam_WriteFrame) {
    const char* path = LUA->CheckString(1);
    std::lock_guard<std::mutex> lock(g_frameMutex);
    if (g_rgbaData.empty() || g_frameWidth == 0) { LUA->PushBool(false); return 1; }

    FILE* f = fopen(path, "wb");
    if (!f) { LUA->PushBool(false); return 1; }

    // TGA header - 32-bit RGBA, uncompressed, top-left origin
    unsigned char header[18] = {0};
    header[2] = 2; // uncompressed true-color
    header[12] = g_frameWidth & 0xFF;
    header[13] = (g_frameWidth >> 8) & 0xFF;
    header[14] = g_frameHeight & 0xFF;
    header[15] = (g_frameHeight >> 8) & 0xFF;
    header[16] = 32; // bits per pixel
    header[17] = 0x28; // top-left origin + 8 alpha bits
    fwrite(header, 1, 18, f);

    // TGA uses BGRA, convert from RGBA
    int total = g_frameWidth * g_frameHeight * 4;
    for (int i = 0; i < total; i += 4) {
        unsigned char bgra[4] = {g_rgbaData[i+2], g_rgbaData[i+1], g_rgbaData[i], g_rgbaData[i+3]};
        fwrite(bgra, 1, 4, f);
    }
    fclose(f);
    LUA->PushBool(true);
    return 1;
}

// webcam.SetChromaKey(enabled, r, g, b, threshold)
LUA_FUNCTION(Webcam_SetChromaKey) {
    g_chromaEnabled = LUA->GetBool(1);
    if (LUA->IsType(2, GarrysMod::Lua::Type::Number)) {
        g_chromaR = (int)LUA->GetNumber(2);
        g_chromaG = (int)LUA->GetNumber(3);
        g_chromaB = (int)LUA->GetNumber(4);
    }
    if (LUA->IsType(5, GarrysMod::Lua::Type::Number))
        g_chromaThreshold = (int)LUA->GetNumber(5);
    return 0;
}

// === RELAY CLIENT ===
static socket_t g_relaySock = INVALID_SOCKET;
static std::thread g_relayRecvThread;
static std::atomic<bool> g_relayConnected(false);
static std::mutex g_remoteFramesMutex;
static std::map<uint64_t, std::vector<unsigned char>> g_remoteFrames;

static bool relaySendAll(const char* data, int len) {
    int sent = 0;
    while (sent < len) {
        int r = send(g_relaySock, data + sent, len - sent, 0);
        if (r <= 0) return false;
        sent += r;
    }
    return true;
}

static bool relayRecvAll(char* data, int len) {
    int got = 0;
    while (got < len) {
        int r = recv(g_relaySock, data + got, len - got, 0);
        if (r <= 0) return false;
        got += r;
    }
    return true;
}

static void RelayRecvThread() {
    while (g_relayConnected) {
        uint32_t msgLen = 0;
        if (!relayRecvAll((char*)&msgLen, 4)) break;
        if (msgLen < 9 || msgLen > 1024 * 1024) break;

        std::vector<char> buf(msgLen);
        if (!relayRecvAll(buf.data(), msgLen)) break;

        uint8_t type = (uint8_t)buf[0];
        if (type == 0x02 && msgLen > 9) {
            uint64_t steamid;
            memcpy(&steamid, buf.data() + 1, 8);
            std::vector<unsigned char> jpeg(buf.begin() + 9, buf.end());
            std::lock_guard<std::mutex> lock(g_remoteFramesMutex);
            g_remoteFrames[steamid] = std::move(jpeg);
        }
    }
    g_relayConnected = false;
}

// webcam.RelayConnect(ip, port, steamid64) -> bool
LUA_FUNCTION(Webcam_RelayConnect) {
    const char* ip = LUA->CheckString(1);
    int port = (int)LUA->CheckNumber(2);
    const char* steamid_str = LUA->CheckString(3);
    uint64_t steamid = strtoull(steamid_str, nullptr, 10);

#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif

    g_relaySock = socket(AF_INET, SOCK_STREAM, 0);
    if (g_relaySock == INVALID_SOCKET) { LUA->PushBool(false); return 1; }

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);

    if (connect(g_relaySock, (sockaddr*)&addr, sizeof(addr)) < 0) {
        CLOSESOCKET(g_relaySock);
        g_relaySock = INVALID_SOCKET;
        LUA->PushBool(false);
        return 1;
    }

    g_relayConnected = true;

    // Send hello
    uint32_t helloLen = 9;
    char hello[13];
    memcpy(hello, &helloLen, 4);
    hello[4] = 0x03;
    memcpy(hello + 5, &steamid, 8);
    relaySendAll(hello, 13);

    g_relayRecvThread = std::thread(RelayRecvThread);
    LUA->PushBool(true);
    return 1;
}

// webcam.RelayDisconnect()
LUA_FUNCTION(Webcam_RelayDisconnect) {
    g_relayConnected = false;
    if (g_relaySock != INVALID_SOCKET) {
        CLOSESOCKET(g_relaySock);
        g_relaySock = INVALID_SOCKET;
    }
    if (g_relayRecvThread.joinable()) g_relayRecvThread.join();
    std::lock_guard<std::mutex> lock(g_remoteFramesMutex);
    g_remoteFrames.clear();
    return 0;
}

// webcam.RelaySendFrame() -> bool (sends current local frame to relay)
LUA_FUNCTION(Webcam_RelaySendFrame) {
    if (!g_relayConnected) { LUA->PushBool(false); return 1; }
    std::lock_guard<std::mutex> lock(g_frameMutex);
    if (g_frameData.empty()) { LUA->PushBool(false); return 1; }

    const char* steamid_str = LUA->CheckString(1);
    uint64_t steamid = strtoull(steamid_str, nullptr, 10);

    uint32_t msgLen = 1 + 8 + (uint32_t)g_frameData.size();
    std::vector<char> msg(4 + msgLen);
    memcpy(msg.data(), &msgLen, 4);
    msg[4] = 0x01;
    memcpy(msg.data() + 5, &steamid, 8);
    memcpy(msg.data() + 13, g_frameData.data(), g_frameData.size());

    bool ok = relaySendAll(msg.data(), (int)msg.size());
    LUA->PushBool(ok);
    return 1;
}

// webcam.RelayGetFrame(steamid64) -> string|false
LUA_FUNCTION(Webcam_RelayGetFrame) {
    const char* steamid_str = LUA->CheckString(1);
    uint64_t steamid = strtoull(steamid_str, nullptr, 10);

    std::lock_guard<std::mutex> lock(g_remoteFramesMutex);
    auto it = g_remoteFrames.find(steamid);
    if (it == g_remoteFrames.end() || it->second.empty()) {
        LUA->PushBool(false);
        return 1;
    }
    LUA->PushString((const char*)it->second.data(), it->second.size());
    return 1;
}

// webcam.RelayIsConnected() -> bool
LUA_FUNCTION(Webcam_RelayIsConnected) {
    LUA->PushBool(g_relayConnected.load());
    return 1;
}

GMOD_MODULE_OPEN() {
    LUA->PushSpecial(SPECIAL_GLOB);
    LUA->CreateTable();
        LUA->PushCFunction(Webcam_Start);    LUA->SetField(-2, "Start");
        LUA->PushCFunction(Webcam_Stop);     LUA->SetField(-2, "Stop");
        LUA->PushCFunction(Webcam_GetFrame); LUA->SetField(-2, "GetFrame");
        LUA->PushCFunction(Webcam_GetPixels);LUA->SetField(-2, "GetPixels");
        LUA->PushCFunction(Webcam_IsRunning);LUA->SetField(-2, "IsRunning");
        LUA->PushCFunction(Webcam_GetPort);  LUA->SetField(-2, "GetPort");
        LUA->PushCFunction(Webcam_WriteFrame); LUA->SetField(-2, "WriteFrame");
        LUA->PushCFunction(Webcam_SetChromaKey); LUA->SetField(-2, "SetChromaKey");
        LUA->PushCFunction(Webcam_RelayConnect); LUA->SetField(-2, "RelayConnect");
        LUA->PushCFunction(Webcam_RelayDisconnect); LUA->SetField(-2, "RelayDisconnect");
        LUA->PushCFunction(Webcam_RelaySendFrame); LUA->SetField(-2, "RelaySendFrame");
        LUA->PushCFunction(Webcam_RelayGetFrame); LUA->SetField(-2, "RelayGetFrame");
        LUA->PushCFunction(Webcam_RelayIsConnected); LUA->SetField(-2, "RelayIsConnected");
    LUA->SetField(-2, "webcam");
    LUA->Pop();
    return 0;
}

GMOD_MODULE_CLOSE() {
    g_running = false;
    g_relayConnected = false;
    if (g_server) g_server->stop();
    if (g_wsListenSock != INVALID_SOCKET) CLOSESOCKET(g_wsListenSock);
    if (g_relaySock != INVALID_SOCKET) CLOSESOCKET(g_relaySock);
    if (g_serverThread.joinable()) g_serverThread.join();
    if (g_wsThread.joinable()) g_wsThread.join();
    if (g_relayRecvThread.joinable()) g_relayRecvThread.join();
    delete g_server; g_server = nullptr;
#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}
