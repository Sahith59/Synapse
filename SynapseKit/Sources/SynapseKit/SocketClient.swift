// Sources/SynapseKit/SocketClient.swift
// ────────────────────────────────────
// Low-level Unix domain socket client.
//
// Design notes:
//   • Uses POSIX socket() API directly (Foundation's FileHandle doesn't
//     expose AF_UNIX address binding in a clean way on macOS 15)
//   • One connection per request — matches the server's stateless model
//   • Thread-safe: each call opens and closes its own socket fd
//   • Newline-delimited JSON over /tmp/synapse.sock
//   • Timeout: 5 seconds (prevents UI hang if daemon crashes)

import Foundation

/// Socket path must match the Python server's SOCKET_PATH constant.
let kSocketPath = "/tmp/synapse.sock"

/// Max response size: 256 KB (handles large result sets gracefully)
let kMaxResponseBytes = 262_144

/// Send a JSON-encodable request and receive a JSON-decodable response.
/// Runs synchronously — call from a background Task.
func sendRequest<Req: Encodable, Res: Decodable>(
    request: Req,
    responseType: Res.Type
) throws -> Res {
    // ── 1. Encode request ─────────────────────────────────────────────────────
    var requestData: Data
    do {
        requestData = try JSONEncoder().encode(request)
        requestData.append(0x0A) // newline delimiter
    } catch {
        throw SynapseError.socketError("Failed to encode request: \(error)")
    }

    // ── 2. Open Unix domain socket ────────────────────────────────────────────
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw SynapseError.daemonNotRunning
    }
    defer { close(fd) }

    // Set 5-second receive timeout
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // ── 3. Connect ─────────────────────────────────────────────────────────────
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(kSocketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        throw SynapseError.socketError("Socket path too long")
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cStr in
            for (i, byte) in pathBytes.enumerated() {
                cStr[i] = CChar(bitPattern: byte)
            }
            cStr[pathBytes.count] = 0
        }
    }

    let connectResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        throw SynapseError.daemonNotRunning
    }

    // ── 4. Send request ────────────────────────────────────────────────────────
    let sendResult = requestData.withUnsafeBytes { ptr in
        send(fd, ptr.baseAddress!, requestData.count, 0)
    }
    guard sendResult == requestData.count else {
        throw SynapseError.socketError("Failed to send request")
    }

    // ── 5. Read response (until newline) ──────────────────────────────────────
    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    outer: while responseData.count < kMaxResponseBytes {
        let bytesRead = recv(fd, &buffer, buffer.count, 0)
        if bytesRead <= 0 { break }
        responseData.append(contentsOf: buffer[0..<bytesRead])
        for byte in buffer[0..<bytesRead] {
            if byte == 0x0A { break outer }  // newline → done
        }
    }

    guard !responseData.isEmpty else {
        throw SynapseError.socketError("Empty response from daemon")
    }

    // ── 6. Decode response ────────────────────────────────────────────────────
    do {
        let decoded = try JSONDecoder().decode(responseType, from: responseData)
        return decoded
    } catch {
        let preview = String(data: responseData.prefix(200), encoding: .utf8) ?? "<binary>"
        throw SynapseError.decodingError("Failed to decode response: \(error)\nRaw: \(preview)")
    }
}

/// Lightweight request wrapper for encoding to JSON.
struct SynapseRequest: Encodable {
    let action: String
    let text: String?
    let source: String?
    let intent: String?
    let topK: Int?

    enum CodingKeys: String, CodingKey {
        case action, text, source, intent
        case topK = "top_k"
    }

    init(
        action: String,
        text: String? = nil,
        source: String? = nil,
        intent: String? = nil,
        topK: Int? = nil
    ) {
        self.action = action
        self.text   = text
        self.source = source
        self.intent = intent
        self.topK   = topK
    }
}
