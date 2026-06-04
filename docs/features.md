# Synapse Features Tracker

This document tracks all implemented and planned features for the Synapse project. It serves as a historical record of our phase-by-phase implementation.

## ✅ Phase 1-3: The Foundation & IDE Stabilization
- **CLI Compilation**: Re-architected project from broken Xcode IDE state to CLI-first `xcodegen` and `xcodebuild` workflow for perfect stability.
- **Native SwiftUI Architecture**: Rewrote the broken UI into a beautiful, native macOS 3-column `NavigationSplitView`.
- **System Daemon Integration**: Implemented a robust `launchd` plist (`com.synapse.daemon.plist`) and a bash CLI tool to manage the vector engine as a true background macOS system service.
- **Testing Framework**: Built a comprehensive Python `pytest` integration suite that tests Unix Socket IPC, concurrency safety, and semantic retrieval accuracy.
- **Delete Node IPC**: Integrated end-to-end soft deletion, connecting the Swift UI context menu directly to the FAISS/SQLite database.

## ✅ Phase 4-6: Screen-Aware Autonomous Memory
- **AppleScript Observer Daemon**: Created a background Python thread that continuously polls native macOS Accessibility APIs.
- **Deep Extraction**: Automatically extracts the inner body text of Safari, Chrome, and Apple Notes without any user interaction.
- **Live Context Streaming**: Built a dedicated `LiveContextPanel` in SwiftUI that polls the daemon via IPC to display what the AI is "seeing" in real-time.
- **Zero-Click Retrieval**: The Swift UI automatically queries the FAISS vector database whenever the active screen context changes, surfacing relevant memories instantly.

## ✅ Phase 7-9: Universal Deep Extraction & OCR
- **Expanded Native Hooks**: Deep AppleScript extraction for Microsoft Word, Excel, Apple Pages, and Mail.
- **CoreGraphics Window Capture**: Mathematical targeting of the active window frame to capture invisible, background `CGImage` screenshots.
- **Vision Framework OCR**: Fallback pipeline that routes the screenshot through Apple's native `Vision` ML framework on the Apple Neural Engine to extract text from highly-sandboxed Electron apps (Slack, Discord, VSCode).

## ✅ Phase 10-12: Generative RAG Synthesis (Apple MLX)
- **Apple MLX LLM Integration**: Implemented a lazy-loading mechanism in the Python daemon to dynamically mount `mlx-community/Phi-3-mini-4k-instruct-4bit` onto the Unified Memory/GPU only when needed.
- **On-Device RAG Pipeline**: Upgraded the Unix Socket `server.py` with an `ask` endpoint that automatically pipes top-k FAISS vector results into a custom generative prompt.
- **"Apple Intelligence" UI**: Redesigned the SwiftUI QueryPanel to feature a native "Synthesis Card" that streams human-like, natural language answers generated locally by the MLX model, eliminating the need to read raw text snippets.
