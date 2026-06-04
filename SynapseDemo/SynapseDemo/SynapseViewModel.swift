import SwiftUI

@MainActor
class SynapseViewModel: ObservableObject {

    // MARK: - Intelligence tab

    @Published var queryText: String = ""
    @Published var isQuerying: Bool = false
    @Published var isGenerating: Bool = false
    @Published var ragAnswer: String = ""
    @Published var results: [ResultItem] = []
    @Published var queryLatencyMs: Double = 0

    // MARK: - Observer (live context)

    @Published var activeContext: ResultItem?
    private var liveContextTask: Task<Void, Never>?

    // MARK: - Daemon status

    @Published var daemonRunning: Bool = false
    @Published var totalSnippets: Int = 0

    // MARK: - Memory tab

    @Published var memoryNodes: [MemoryNode] = []
    @Published var isLoadingMemory: Bool = false

    // MARK: - Models

    struct ResultItem: Identifiable {
        let id: Int
        let text: String
        let source: String
        let similarity: Double
        let timestamp: Double
    }

    struct MemoryNode: Identifiable {
        let id: Int
        let text: String
        let source: String
        let timestamp: Double
    }

    // MARK: - Source icons

    static func sourceIconStatic(_ source: String) -> String {
        switch source.lowercased() {
        case "notes":      return "note.text"
        case "calendar":   return "calendar"
        case "reminders":  return "checklist"
        case "safari":     return "safari"
        case "chrome":     return "safari"
        case "contacts":   return "person.crop.circle"
        case "fitness":    return "figure.run"
        case "mail":       return "envelope"
        case "messages":   return "message"
        case "pages":      return "doc.richtext"
        case "word":       return "doc.richtext"
        case "excel":      return "tablecells"
        case "electron":   return "laptopcomputer"
        case "terminal":   return "terminal"
        case "xcode":      return "hammer"
        default:           return "app"
        }
    }

    // MARK: - Daemon check

    func checkDaemon() async {
        let (running, count) = await rawPingAndCount()
        withAnimation { daemonRunning = running; totalSnippets = count }
    }

    // MARK: - Live context streaming

    func startLiveContextStreaming() {
        liveContextTask?.cancel()
        liveContextTask = Task {
            while !Task.isCancelled {
                if let latest = await rawLatest() {
                    if activeContext?.id != latest.id {
                        await MainActor.run {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                activeContext = latest
                            }
                            // NOTE: Do NOT auto-populate queryText or trigger query().
                            // The observer pane is display-only. Search is user-initiated.
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopLiveContextStreaming() {
        liveContextTask?.cancel()
        liveContextTask = nil
    }

    // MARK: - Query + RAG

    func query() async {
        guard !queryText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        withAnimation { isQuerying = true; isGenerating = true; results = []; ragAnswer = "" }

        let t0 = Date()
        let hits = await rawQuery(intent: queryText, topK: 8)
        let elapsed = Date().timeIntervalSince(t0) * 1000

        withAnimation(.easeOut(duration: 0.2)) {
            queryLatencyMs = elapsed
            results = hits.map {
                ResultItem(id: $0.id, text: $0.text, source: $0.source,
                           similarity: $0.similarity, timestamp: $0.timestamp)
            }
            isQuerying = false
        }

        // RAG synthesis runs separately with a long timeout
        let answer = await rawAsk(query: queryText, topK: 3)
        withAnimation(.easeOut(duration: 0.25)) {
            ragAnswer = answer ?? ""
            isGenerating = false
        }
    }

    // MARK: - Delete

    func delete(id: Int) async {
        guard let data = await rawSend(json: ["action": "delete", "id": id]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true else { return }
        withAnimation {
            results.removeAll { $0.id == id }
            memoryNodes.removeAll { $0.id == id }
            totalSnippets = max(0, totalSnippets - 1)
        }
    }

    // MARK: - Memory tab

    func loadMemory() async {
        withAnimation { isLoadingMemory = true }
        guard let data = await rawSend(json: ["action": "list", "limit": 300]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let items = json["items"] as? [[String: Any]] else {
            withAnimation { isLoadingMemory = false }
            return
        }

        let nodes: [MemoryNode] = items.compactMap { item in
            guard let id  = item["id"]        as? Int,
                  let txt = item["text"]      as? String,
                  let src = item["source"]    as? String,
                  let ts  = item["timestamp"] as? Double else { return nil }
            return MemoryNode(id: id, text: txt, source: src, timestamp: ts)
        }

        withAnimation {
            memoryNodes = nodes
            if let total = json["total"] as? Int { totalSnippets = total }
            isLoadingMemory = false
        }
    }

    // MARK: - Raw socket transport

    /// Send a JSON request over /tmp/synapse.sock and return the raw response Data.
    /// - Parameter timeout: seconds. Use 120 for LLM calls.
    func rawSend(json payload: [String: Any], timeout: Int = 10) async -> Data? {
        await Task.detached {
            guard let body = try? JSONSerialization.data(withJSONObject: payload),
                  var msg = String(data: body, encoding: .utf8) else { return nil }
            msg += "\n"

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var tv = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array("/tmp/synapse.sock".utf8)
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cstr in
                    for (i, b) in pathBytes.enumerated() { cstr[i] = CChar(bitPattern: b) }
                    cstr[pathBytes.count] = 0
                }
            }

            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { return nil }

            let msgData = msg.data(using: .utf8)!
            _ = msgData.withUnsafeBytes { send(fd, $0.baseAddress!, msgData.count, 0) }

            var resp = Data()
            var buf  = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                resp.append(contentsOf: buf[0..<n])
                if buf[0..<n].contains(0x0A) { break }
            }
            return resp.isEmpty ? nil : resp
        }.value
    }

    // MARK: - Private helpers

    private func rawPingAndCount() async -> (Bool, Int) {
        guard let d = await rawSend(json: ["action": "ping"]),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              j["ok"] as? Bool == true else { return (false, 0) }
        if let cd = await rawSend(json: ["action": "count"]),
           let cj = try? JSONSerialization.jsonObject(with: cd) as? [String: Any],
           let n  = cj["active_snippets"] as? Int { return (true, n) }
        return (true, 0)
    }

    private func rawLatest() async -> ResultItem? {
        guard let d  = await rawSend(json: ["action": "latest"]),
              let j  = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              j["ok"] as? Bool == true,
              let lt = j["latest"] as? [String: Any],
              let id = lt["id"]        as? Int,
              let tx = lt["text"]      as? String,
              let sr = lt["source"]    as? String,
              let ts = lt["timestamp"] as? Double else { return nil }
        return ResultItem(id: id, text: tx, source: sr, similarity: 1.0, timestamp: ts)
    }

    private func rawQuery(intent: String, topK: Int) async
        -> [(id: Int, text: String, source: String, similarity: Double, timestamp: Double)]
    {
        guard let d   = await rawSend(json: ["action": "query", "intent": intent, "top_k": topK]),
              let j   = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              j["ok"] as? Bool == true,
              let arr = j["results"] as? [[String: Any]] else { return [] }
        return arr.compactMap {
            guard let id  = $0["id"]         as? Int,
                  let tx  = $0["text"]       as? String,
                  let src = $0["source"]     as? String,
                  let sim = $0["similarity"] as? Double,
                  let ts  = $0["timestamp"]  as? Double else { return nil }
            return (id, tx, src, sim, ts)
        }
    }

    private func rawAsk(query: String, topK: Int) async -> String? {
        // LLM can take 30-90 s to load + generate on first call; use a 120 s timeout.
        guard let d   = await rawSend(json: ["action": "ask", "query": query, "top_k": topK], timeout: 120),
              let j   = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              j["ok"] as? Bool == true,
              let ans = j["answer"] as? String else { return nil }
        return ans
    }
}
