#pragma once
#include <vector>
#include <string>
#include <cstring>
#include <cstdint>

#ifdef _WIN32
#include <winsock2.h>
typedef SOCKET socket_t;
#define WS_RECV(s,b,l) recv(s,(char*)b,l,0)
#define WS_SEND(s,b,l) send(s,(const char*)b,l,0)
#else
#include <sys/socket.h>
#include <unistd.h>
typedef int socket_t;
#define WS_RECV(s,b,l) recv(s,b,l,0)
#define WS_SEND(s,b,l) send(s,b,l,0)
#endif

// Minimal SHA-1 for WebSocket handshake
static void sha1(const unsigned char* data, size_t len, unsigned char out[20]) {
    uint32_t h0=0x67452301,h1=0xEFCDAB89,h2=0x98BADCFE,h3=0x10325476,h4=0xC3D2E1F0;
    uint64_t bits = len * 8;
    std::vector<unsigned char> msg(data, data + len);
    msg.push_back(0x80);
    while (msg.size() % 64 != 56) msg.push_back(0);
    for (int i = 7; i >= 0; i--) msg.push_back((bits >> (i * 8)) & 0xFF);

    for (size_t i = 0; i < msg.size(); i += 64) {
        uint32_t w[80];
        for (int j = 0; j < 16; j++)
            w[j] = (msg[i+j*4]<<24)|(msg[i+j*4+1]<<16)|(msg[i+j*4+2]<<8)|msg[i+j*4+3];
        for (int j = 16; j < 80; j++) {
            uint32_t t = w[j-3]^w[j-8]^w[j-14]^w[j-16];
            w[j] = (t<<1)|(t>>31);
        }
        uint32_t a=h0,b=h1,c=h2,d=h3,e=h4;
        for (int j = 0; j < 80; j++) {
            uint32_t f,k;
            if(j<20){f=(b&c)|((~b)&d);k=0x5A827999;}
            else if(j<40){f=b^c^d;k=0x6ED9EBA1;}
            else if(j<60){f=(b&c)|(b&d)|(c&d);k=0x8F1BBCDC;}
            else{f=b^c^d;k=0xCA62C1D6;}
            uint32_t t=((a<<5)|(a>>27))+f+e+k+w[j];
            e=d;d=c;c=(b<<30)|(b>>2);b=a;a=t;
        }
        h0+=a;h1+=b;h2+=c;h3+=d;h4+=e;
    }
    for(int i=0;i<4;i++){out[i]=h0>>(24-i*8);out[4+i]=h1>>(24-i*8);out[8+i]=h2>>(24-i*8);out[12+i]=h3>>(24-i*8);out[16+i]=h4>>(24-i*8);}
}

static const char b64chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static std::string base64_encode(const unsigned char* data, size_t len) {
    std::string r;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t n = (data[i] << 16) | (i+1<len?data[i+1]<<8:0) | (i+2<len?data[i+2]:0);
        r += b64chars[(n>>18)&63];
        r += b64chars[(n>>12)&63];
        r += (i+1<len) ? b64chars[(n>>6)&63] : '=';
        r += (i+2<len) ? b64chars[n&63] : '=';
    }
    return r;
}

// Perform WebSocket upgrade handshake (server side)
static bool ws_handshake(socket_t sock) {
    char buf[2048];
    int n = WS_RECV(sock, buf, sizeof(buf) - 1);
    if (n <= 0) return false;
    buf[n] = 0;

    // Find Sec-WebSocket-Key
    const char* keyHeader = strstr(buf, "Sec-WebSocket-Key: ");
    if (!keyHeader) return false;
    keyHeader += 19;
    const char* keyEnd = strstr(keyHeader, "\r\n");
    if (!keyEnd) return false;

    std::string key(keyHeader, keyEnd - keyHeader);
    key += "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    unsigned char hash[20];
    sha1((const unsigned char*)key.c_str(), key.size(), hash);
    std::string accept = base64_encode(hash, 20);

    std::string response = "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Accept: " + accept + "\r\n\r\n";

    WS_SEND(sock, response.c_str(), (int)response.size());
    return true;
}

// Read a WebSocket frame. Returns opcode (0x1=text, 0x2=binary, 0x8=close, -1=error)
static int ws_read_frame(socket_t sock, std::vector<unsigned char>& payload) {
    unsigned char header[2];
    if (WS_RECV(sock, header, 2) != 2) return -1;

    int opcode = header[0] & 0x0F;
    bool masked = (header[1] & 0x80) != 0;
    uint64_t len = header[1] & 0x7F;

    if (len == 126) {
        unsigned char ext[2];
        if (WS_RECV(sock, ext, 2) != 2) return -1;
        len = (ext[0] << 8) | ext[1];
    } else if (len == 127) {
        unsigned char ext[8];
        if (WS_RECV(sock, ext, 8) != 8) return -1;
        len = 0;
        for (int i = 0; i < 8; i++) len = (len << 8) | ext[i];
    }

    unsigned char mask[4] = {0};
    if (masked) {
        if (WS_RECV(sock, mask, 4) != 4) return -1;
    }

    payload.resize((size_t)len);
    size_t received = 0;
    while (received < len) {
        int r = WS_RECV(sock, payload.data() + received, (int)(len - received));
        if (r <= 0) return -1;
        received += r;
    }

    if (masked) {
        for (size_t i = 0; i < len; i++) payload[i] ^= mask[i % 4];
    }

    return opcode;
}
