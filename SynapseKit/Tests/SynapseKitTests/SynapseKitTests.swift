// Tests/SynapseKitTests/SynapseKitTests.swift
// ─────────────────────────────────────────
// XCTest suite for SynapseKit round-trip correctness.
//
// Prerequisites: The Synapse daemon must be running before running these tests.
//   Start: python synapse/daemon.py
//   Test:  swift test (in SynapseKit/ directory)
//
// These tests verify:
//   1. Daemon is reachable (ping)
//   2. Store returns a valid positive integer ID
//   3. Query returns results containing the stored snippet
//   4. Top result is semantically correct (not random)
//   5. Similarity scores are in [0, 1]

import XCTest
@testable import SynapseKit

final class SynapseKitTests: XCTestCase {

    // ── Helpers ───────────────────────────────────────────────────────────────

    func assertDaemonRunning() async throws {
        let running = await SynapseKit.isDaemonRunning()
        guard running else {
            throw XCTSkip("Synapse daemon is not running — start it first: python synapse/daemon.py")
        }
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    func testDaemonPing() async throws {
        let running = await SynapseKit.isDaemonRunning()
        XCTAssertTrue(running, "Daemon should be running")
    }

    func testStoreReturnsPositiveID() async throws {
        try await assertDaemonRunning()
        let id = try await SynapseKit.store(
            "Alice has a dentist appointment on Thursday at 2pm",
            source: "Calendar"
        )
        XCTAssertGreaterThan(id, 0, "Store should return a positive integer ID")
    }

    func testQueryReturnsSemanticallyRelevantResult() async throws {
        try await assertDaemonRunning()

        // Store a distinctive snippet
        let uniquePhrase = "Synapse test snippet \(UUID().uuidString)"
        let storedID = try await SynapseKit.store(uniquePhrase, source: "TestApp")

        // Query with a semantically similar phrase
        let results = try await SynapseKit.query("Synapse test snippet", topK: 50)

        XCTAssertFalse(results.isEmpty, "Query should return at least one result")

        let foundIDs = results.map { $0.id }
        XCTAssertTrue(
            foundIDs.contains(storedID),
            "Stored snippet ID \(storedID) should appear in query results"
        )
    }

    func testSimilarityScoresAreNormalized() async throws {
        try await assertDaemonRunning()

        let results = try await SynapseKit.query("Apple Silicon machine learning", topK: 5)
        for result in results {
            XCTAssertGreaterThanOrEqual(result.similarity, 0.0, "Similarity must be >= 0")
            XCTAssertLessThanOrEqual(result.similarity, 1.01, "Similarity must be <= 1")
        }
    }

    func testTopResultIsMoreRelevantThanBottom() async throws {
        try await assertDaemonRunning()

        // Store two clearly different snippets
        try await SynapseKit.store("Machine learning inference on Apple Neural Engine", source: "Notes")
        try await SynapseKit.store("Buy apples and oranges from the grocery store", source: "Reminders")

        let results = try await SynapseKit.query("on-device ML inference Apple Silicon", topK: 5)

        guard results.count >= 2 else { return }

        XCTAssertGreaterThan(
            results[0].similarity,
            results[results.count - 1].similarity,
            "First result should be more similar than last result"
        )
    }

    func testStoreAndQueryRoundTrip() async throws {
        try await assertDaemonRunning()

        let snippets = [
            ("Meeting with the design team about the new Synapse SwiftUI interface", "Notes"),
            ("Buy ingredients for pasta: spaghetti, tomatoes, garlic, basil", "Reminders"),
            ("WWDC session: Understanding Core ML compute units and ANE routing", "Safari"),
            ("Call mom this weekend — her birthday is coming up soon", "Contacts"),
            ("Gym session: 5x5 squats, 3x10 deadlifts, 20min rowing", "Fitness"),
        ]

        var storedIDs: [Int] = []
        for (text, source) in snippets {
            let id = try await SynapseKit.store(text, source: source)
            storedIDs.append(id)
        }

        // Query for the ML-related snippet
        let mlResults = try await SynapseKit.query("Core ML ANE WWDC Apple Silicon", topK: 20)
        let mlTexts = mlResults.map { $0.text }
        let foundMLSnippet = mlTexts.contains(where: { $0.contains("WWDC") || $0.contains("Core ML") })
        XCTAssertTrue(foundMLSnippet, "ML-related query should surface the WWDC snippet")

        // Query for the food snippet
        let foodResults = try await SynapseKit.query("grocery food shopping list", topK: 20)
        let foodTexts = foodResults.map { $0.text }
        let foundFoodSnippet = foodTexts.contains(where: { $0.contains("pasta") || $0.contains("tomatoes") })
        XCTAssertTrue(foundFoodSnippet, "Food query should surface the pasta snippet")
    }

    func testCountIncreases() async throws {
        try await assertDaemonRunning()

        let before = try await SynapseKit.count()
        try await SynapseKit.store("A brand new snippet for count test", source: "Test")
        let after = try await SynapseKit.count()

        XCTAssertEqual(after, before + 1, "Count should increase by 1 after storing a snippet")
    }
}
