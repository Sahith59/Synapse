// Sources/SynapseKit/Models.swift
// ─────────────────────────────
// Data models for the SynapseKit public API.
// These are the types returned by SynapseKit.query().

import Foundation

/// A single result from a semantic query.
///
/// Results are returned ranked by cosine similarity (highest first).
/// The `similarity` score is a float in [0, 1] — vectors are L2-normalized
/// before storage, so inner product equals cosine similarity.
public struct SynapseResult: Identifiable, Decodable, Sendable {
    /// Unique identifier assigned at store time.
    public let id: Int

    /// The original text snippet that was stored.
    public let text: String

    /// The source application tag (e.g. "Notes", "Calendar").
    public let source: String

    /// Cosine similarity score [0, 1]. Higher = more semantically similar.
    public let similarity: Double

    /// Unix timestamp of when the snippet was stored.
    public let timestamp: TimeInterval

    /// Human-readable date from the timestamp.
    public var date: Date {
        Date(timeIntervalSince1970: timestamp)
    }
}

/// Response from a store operation.
struct StoreResponse: Decodable {
    let ok: Bool
    let id: Int?
    let latencyMs: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, id, error
        case latencyMs = "latency_ms"
    }
}

/// Response from a query operation.
struct QueryResponse: Decodable {
    let ok: Bool
    let results: [SynapseResult]?
    let embedLatencyMs: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, results, error
        case embedLatencyMs = "embed_latency_ms"
    }
}

/// Response from a count operation.
struct CountResponse: Decodable {
    let ok: Bool
    let activeSnippets: Int?
    let faissVectors: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok, error
        case activeSnippets = "active_snippets"
        case faissVectors   = "faiss_vectors"
    }
}

/// Synapse errors surfaced to the caller.
public enum SynapseError: LocalizedError, Sendable {
    case daemonNotRunning
    case socketError(String)
    case serverError(String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Synapse daemon is not running. Start it with: python synapse/daemon.py"
        case .socketError(let msg):
            return "Socket error: \(msg)"
        case .serverError(let msg):
            return "Server error: \(msg)"
        case .decodingError(let msg):
            return "Response decoding error: \(msg)"
        }
    }
}
