#pragma once
#include <vector>
#include <string>
#include <cstring>
#include <cstdint>
#include <cerrno>

#ifdef _WIN32
#include <winsock2.h>
typedef SOCKET socket_t;
#define WS_RECV(s,b,l) recv(s,(char*)b,l,0)
#define WS_SEND(s,b,l) send(s,(const char*)b,l,0)
#else
#include <sys/socket.h>
#include <unistd.h>
typedef int socket_t;
#define WS_RECV(s,b,l) recv(s,(char*)b,l,0)
#define WS_SEND(s,b,l) send(s,(const char*)b,l,0)
#endif

// Minimal SHA-1 for WebSocket handshake
static void sha1(const unsigned char* data, size_t len, unsigned char out[20]) {
    uint32_t h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    uint64_t bits = len * 8;
    std::vector<unsigned char> msg(data, data + len);
    msg.push_back(0x80);
    while (msg.size() % 64 != 56) msg.push_back(0);
    for (int i = 7; i >= 0; i--) msg.push_back((bits >> (i * 8)) & 0xFF);

    for (size_t i = 0; i < msg.size(); i += 64) {
        uint32_t w[80];
        for (int j = 0; j < 16; j++)
            w[j] = (msg[i + j * 4] << 24) | (msg[i + j * 4 + 1] << 16) | (msg[i + j * 4 + 2] << 8) | msg[i + j * 4 + 3];
        for (int j = 16; j < 80; j++) {
            uint32_t t = w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16];
            w[j] = (t << 1) | (t >> 31);
        }
        uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
        for (int j = 0; j < 80; j++) {
            uint32_t f, k;
            if (j < 20) { f = (b & c) | ((~b) & d);k = 0x5A827999; }
            else if (j < 40) { f = b ^ c ^ d;k = 0x6ED9EBA1; }
            else if (j < 60) { f = (b & c) | (b & d) | (c & d);k = 0x8F1BBCDC; }
            else { f = b ^ c ^ d;k = 0xCA62C1D6; }
            uint32_t t = ((a << 5) | (a >> 27)) + f + e + k + w[j];
            e = d;d = c;c = (b << 30) | (b >> 2);b = a;a = t;
        }
        h0 += a;h1 += b;h2 += c;h3 += d;h4 += e;
    }
    for (int i = 0;i < 4;i++) { out[i] = h0 >> (24 - i * 8);out[4 + i] = h1 >> (24 - i * 8);out[8 + i] = h2 >> (24 - i * 8);out[12 + i] = h3 >> (24 - i * 8);out[16 + i] = h4 >> (24 - i * 8); }
}

static const char b64chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static std::string base64_encode(const unsigned char* data, size_t len) {
    std::string r;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t n = (data[i] << 16) | (i + 1 < len ? data[i + 1] << 8 : 0) | (i + 2 < len ? data[i + 2] : 0);
        r += b64chars[(n >> 18) & 63];
        r += b64chars[(n >> 12) & 63];
        r += (i + 1 < len) ? b64chars[(n >> 6) & 63] : '=';
        r += (i + 2 < len) ? b64chars[n & 63] : '=';
    }
    return r;
}

// Result of a read: 1 = ok, 0 = peer closed cleanly, -1 = socket error.
// Knowing which of these happened is the difference between "the browser hung
// up" and "the link broke", so it is reported rather than collapsed into false.
static int ws_last_error = 0;

static int ws_socket_error() {
#ifdef _WIN32
    return WSAGetLastError();
#else
    return errno;
#endif
}

static int ws_recv_all(socket_t sock, void* buf, int len) {
    unsigned char* p = (unsigned char*)buf;
    int got = 0;
    while (got < len) {
        int r = WS_RECV(sock, p + got, len - got);
        if (r == 0) { ws_last_error = 0; return 0; }
        if (r < 0) { ws_last_error = ws_socket_error(); return -1; }
        got += r;
    }
    return 1;
}

static bool ws_send_all(socket_t sock, const unsigned char* data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        int r = WS_SEND(sock, data + sent, (int)(len - sent));
        if (r <= 0) return false;
        sent += (size_t)r;
    }
    return true;
}

// Server -> client frame (never masked)
static bool ws_send_frame(socket_t sock, int opcode, const unsigned char* data, size_t len) {
    std::vector<unsigned char> out;
    out.push_back((unsigned char)(0x80 | (opcode & 0x0F)));

    if (len < 126) {
        out.push_back((unsigned char)len);
    }
    else if (len <= 0xFFFF) {
        out.push_back(126);
        out.push_back((unsigned char)((len >> 8) & 0xFF));
        out.push_back((unsigned char)(len & 0xFF));
    }
    else {
        out.push_back(127);
        for (int i = 7; i >= 0; i--)
            out.push_back((unsigned char)((len >> (i * 8)) & 0xFF));
    }

    if (data && len) out.insert(out.end(), data, data + len);
    return ws_send_all(sock, out.data(), out.size());
}

// Perform WebSocket upgrade handshake (server side)
static bool ws_handshake(socket_t sock) {
    // Headers can arrive split across packets, so read until the header block ends.
    std::string req;
    char buf[2048];

    for (int i = 0; i < 32; i++) {
        int n = WS_RECV(sock, buf, (int)sizeof(buf) - 1);
        if (n <= 0) return false;
        req.append(buf, n);
        if (req.find("\r\n\r\n") != std::string::npos) break;
        if (req.size() > 32768) return false;
    }

    size_t keyPos = req.find("Sec-WebSocket-Key:");
    if (keyPos == std::string::npos) {
        keyPos = req.find("sec-websocket-key:");
        if (keyPos == std::string::npos) return false;
    }

    keyPos = req.find(':', keyPos) + 1;
    while (keyPos < req.size() && (req[keyPos] == ' ' || req[keyPos] == '\t')) keyPos++;

    size_t keyEnd = req.find("\r\n", keyPos);
    if (keyEnd == std::string::npos) return false;

    std::string key = req.substr(keyPos, keyEnd - keyPos);
    key += "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    unsigned char hash[20];
    sha1((const unsigned char*)key.c_str(), key.size(), hash);

    std::string response = "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Accept: " + base64_encode(hash, 20) + "\r\n\r\n";

    return ws_send_all(sock, (const unsigned char*)response.c_str(), response.size());
}

static const uint64_t WS_MAX_PAYLOAD = 32ull * 1024ull * 1024ull;

// Read one complete message, reassembling fragments and answering pings.
// Returns the message opcode (0x1 = text, 0x2 = binary, 0x8 = close, -1 = error)
static int ws_read_frame(socket_t sock, std::vector<unsigned char>& payload) {
    payload.clear();
    int messageOpcode = -1;

    for (;;) {
        unsigned char header[2];
        int r = ws_recv_all(sock, header, 2);
        if (r == 0) return -2;          // browser hung up cleanly
        if (r < 0) return -1;           // socket error, see ws_last_error

        bool fin = (header[0] & 0x80) != 0;
        int opcode = header[0] & 0x0F;
        bool masked = (header[1] & 0x80) != 0;
        uint64_t len = header[1] & 0x7F;

        if (len == 126) {
            unsigned char ext[2];
            if (ws_recv_all(sock, ext, 2) != 1) return -1;
            len = ((uint64_t)ext[0] << 8) | (uint64_t)ext[1];
        }
        else if (len == 127) {
            unsigned char ext[8];
            if (ws_recv_all(sock, ext, 8) != 1) return -1;
            len = 0;
            for (int i = 0; i < 8; i++) len = (len << 8) | (uint64_t)ext[i];
        }

        if (len > WS_MAX_PAYLOAD || (uint64_t)payload.size() + len > WS_MAX_PAYLOAD) return -1;

        unsigned char mask[4] = { 0 };
        if (masked && ws_recv_all(sock, mask, 4) != 1) return -1;

        std::vector<unsigned char> chunk((size_t)len);
        if (len && ws_recv_all(sock, chunk.data(), (int)len) != 1) return -1;
        if (masked) {
            for (size_t i = 0; i < chunk.size(); i++) chunk[i] ^= mask[i % 4];
        }

        // Control frames may be interleaved with a fragmented message
        if (opcode == 0x8) return 0x8;                                  // close
        if (opcode == 0x9) {                                            // ping -> pong
            ws_send_frame(sock, 0xA, chunk.data(), chunk.size());
            continue;
        }
        if (opcode == 0xA) continue;                                    // pong

        if (opcode != 0x0) messageOpcode = opcode;                      // start of message
        payload.insert(payload.end(), chunk.begin(), chunk.end());

        if (fin) return messageOpcode;
    }
}