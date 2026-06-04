// Sources/SynapseKit/SynapseKit.swift
// ────────────────────────────────
// Public API — two functions that are all any app needs.
//
// Usage:
//   import SynapseKit
//
//   // Store a snippet from Notes
//   try await SynapseKit.store("Meeting with Alice at 3pm", source: "Notes")
//
//   // Query from Reminders
//   let results = try await SynapseKit.query("Alice meeting tomorrow", topK: 5)
//   for r in results {
//       print("\(r.source): \(r.text)  [\(r.similarity)]")
//   }
//
// Threading model:
//   All methods are async — they run the socket I/O on a background
//   executor so the calling actor (e.g. MainActor in SwiftUI) is not blocked.

import Foundation

/// The primary namespace for all Synapse operations.
public enum SynapseKit {

    // ── Store ─────────────────────────────────────────────────────────────────

    /// Store a text snippet in the Synapse semantic memory index.
    ///
    /// - Parameters:
    ///   - snippet: The text to embed and store (max ~90 words / 128 tokens).
    ///   - source:  A tag identifying the originating app (e.g. "Notes", "Calendar").
    ///
    /// - Returns: The integer ID assigned to this snippet.
    ///
    /// - Throws: ``SynapseError`` if the daemon is not running or I/O fails.
    @discardableResult
    public static func store(_ snippet: String, source: String = "unknown") async throws -> Int {
        let response: StoreResponse = try await Task.detached(priority: .userInitiated) {
            let req = SynapseRequest(action: "store", text: snippet, source: source)
            return try sendRequest(request: req, responseType: StoreResponse.self)
        }.value

        guard response.ok, let id = response.id else {
            throw SynapseError.serverError(response.error ?? "Unknown store error")
        }
        return id
    }

    // ── Query ─────────────────────────────────────────────────────────────────

    /// Query the Synapse semantic memory index for snippets related to an intent.
    ///
    /// - Parameters:
    ///   - intent: Natural language query (e.g. "dentist appointment").
    ///   - topK:   Number of results to return (default 5, max 50).
    ///
    /// - Returns: Array of ``SynapseResult`` ranked by cosine similarity (highest first).
    ///
    /// - Throws: ``SynapseError`` if the daemon is not running or I/O fails.
    public static func query(_ intent: String, topK: Int = 5) async throws -> [SynapseResult] {
        let response: QueryResponse = try await Task.detached(priority: .userInitiated) {
            let req = SynapseRequest(action: "query", intent: intent, topK: topK)
            return try sendRequest(request: req, responseType: QueryResponse.self)
        }.value

        guard response.ok else {
            throw SynapseError.serverError(response.error ?? "Unknown query error")
        }
        return response.results ?? []
    }

    // ── Health ────────────────────────────────────────────────────────────────

    /// Returns true if the Synapse daemon is running and accepting connections.
    ///
    /// Use this to show an appropriate UI state before attempting store/query.
    public static func isDaemonRunning() async -> Bool {
        do {
            struct PingReq: Encodable { let action = "ping" }
            struct PingRes: Decodable { let ok: Bool; let pong: Bool? }
            let res: PingRes = try await Task.detached {
                try sendRequest(request: PingReq(), responseType: PingRes.self)
            }.value
            return res.ok && (res.pong == true)
        } catch {
            return false
        }
    }

    /// Returns the current number of active snippets in the index.
    public static func count() async throws -> Int {
        struct CountReq: Encodable { let action = "count" }
        let res: CountResponse = try await Task.detached {
            try sendRequest(request: CountReq(), responseType: CountResponse.self)
        }.value
        guard res.ok else {
            throw SynapseError.serverError(res.error ?? "Unknown count error")
        }
        return res.activeSnippets ?? 0
    }
}
