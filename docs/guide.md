# Synapse — Interview Prep Guide

This guide is designed to help you articulate the technical decisions made during the development of Synapse to Apple hiring managers and recruiters.

## Core Problem Statement
*“Apps on macOS are data silos. If you want an AI to understand your context, you currently have to upload all your personal data (emails, notes) to a cloud API like OpenAI. This is slow, expensive, and a massive privacy violation. Synapse solves this by providing a local, cross-app Semantic Memory Fabric powered entirely by Apple Silicon.”*

---

## 1. Core ML & Apple Neural Engine (ANE)
**What we use:** `coremltools` to convert HuggingFace models to `.mlpackage`.
**Why we chose it over PyTorch/ONNX:** 
- Standard PyTorch runs on the CPU or GPU and is heavy. Core ML allows us to explicitly route mathematical workloads to the **Apple Neural Engine (ANE)**.
- We palettized the model weights to **INT4**, dramatically shrinking the memory footprint while maintaining semantic accuracy. 
- **Result:** Sub-millisecond (0.74ms) vector embeddings, preventing the daemon from draining the MacBook's battery.

## 2. Unix Domain Sockets (IPC)
**What we use:** Raw socket connections (`/tmp/synapse.sock`) with a custom JSON framing protocol.
**Why we chose it over HTTP/REST (FastAPI/Flask):**
- HTTP brings immense overhead (headers, TCP handshakes, heavy web frameworks). 
- Unix Domain Sockets happen entirely within the OS kernel space, bypassing the network stack completely. It is incredibly secure (no port mapping) and provides microsecond-level latency between the Swift UI and the Python daemon.

## 3. Vector Database (FAISS + SQLite)
**What we use:** Meta's `faiss-cpu` combined with `sqlite3`.
**Why we chose it over ChromaDB, Pinecone, or Postgres (pgvector):**
- **Pinecone** is a cloud service (violates our privacy-first, offline requirement).
- **ChromaDB** is extremely heavy, pulling in dozens of unneeded Python dependencies which bloats the daemon.
- **FAISS (L2 Normalized Inner Product)** gives us instant, mathematically optimal cosine similarity searches in pure C++, perfectly suited for local execution.
- We pair it with **SQLite** for relational metadata (timestamp, source app, text) because SQLite is natively embedded in macOS and requires no background server.

## 4. UI Framework (SwiftUI)
**What we use:** `NavigationSplitView` with MVVM architecture.
**Why we chose it over Electron or React Native:**
- To integrate deeply with macOS (toolbar chrome, system dark mode, low memory footprint), native SwiftUI is vastly superior. Electron uses chromium, eating hundreds of MBs of RAM just to display a UI. 
- Synapse is designed to run silently all day; a native SwiftUI client is essential.

## 5. Autonomous Data Capture (AppleScript + Vision OCR)
**What we use:** `osascript` (AppleScript) and `pyobjc` (Vision.framework).
**Why we chose it over Accessibility Screen Scraping (UIBrowser):**
- AppleScript allows us to safely ask native apps (Safari, Notes) to cleanly hand over their internal text object, resulting in 100% accurate extraction.
- For sandboxed apps (Slack, Discord), we use `Quartz` to silently screenshot the window and Apple's `Vision` framework to OCR it. We chose Apple's Vision framework over Tesseract because Vision uses the ANE for lightning-fast ML text recognition, whereas Tesseract is heavy CPU-bound software.

## 6. Generative Synthesis (Apple MLX)
**What we use:** `mlx-lm` running `Phi-3-mini-4k-instruct-4bit`.
**Why we chose it over OpenAI API or Ollama:**
- The entire goal of Synapse is privacy. Sending personal memory vectors to an OpenAI API endpoint defeats the purpose.
- Ollama is great, but it runs as a separate heavy binary. By embedding Apple's `mlx-lm` directly into the Python daemon, we achieve a tightly-coupled architecture. 
- We chose a **4-bit quantized** model because it perfectly fits into the MacBook's Unified Memory architecture, allowing lightning-fast inference directly on the GPU without exhausting system RAM. It is lazily-loaded to ensure the daemon stays lightweight when not answering questions.

---

## Anticipated Interview Questions

**Q: Why use Python for the daemon instead of Swift?**
> A: "While Swift is fantastic for the UI, the open-source ML ecosystem (HuggingFace tokenizers, FAISS, PyTorch model conversion) is entirely Python-native. By running a lightweight Python daemon, we bridge the gap between cutting-edge ML research tools and the beautiful native macOS UI, communicating efficiently over Unix Sockets."

**Q: How do you handle concurrency if multiple apps try to store data at once?**
> A: "The daemon implements thread-safe locking using `threading.RLock()`. Both FAISS and SQLite are protected during write operations. We wrote a concurrent stress test using Python's `ThreadPoolExecutor` (sending 20 concurrent IPC store commands) to guarantee memory safety."

**Q: If you are running OCR every 2 seconds, won't that destroy battery life?**
> A: "That's exactly why we only trigger OCR when AppleScript fails, and only when the window content has actually changed. By routing the Vision OCR tasks directly to the Neural Engine, it consumes a fraction of the power compared to standard CPU-bound OCR engines."

**Q: Large Language Models are huge. How do you prevent Synapse from freezing the system?**
> A: "We utilize Apple's MLX framework and run a 4-bit quantized version of Phi-3. The entire model takes up less than 2.3GB of memory. More importantly, we implement **Lazy Loading** in the daemon. The model is absolutely not loaded into VRAM during normal background screen-scraping; it is only mounted into Unified Memory the exact millisecond the user asks a question, and can be unloaded if needed."
