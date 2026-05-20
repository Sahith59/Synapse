#!/usr/bin/env python3
"""
synapse/daemon.py
───────────────
Synapse daemon — orchestrates embedder + store + server.

Usage:
    python synapse/daemon.py [--no-warmup]

Lifecycle:
    1. Initialize store (load FAISS index + SQLite)
    2. Initialize embedder (load Core ML model)
    3. Warmup ANE (3 dummy inferences to trigger ANE compilation)
    4. Start server (blocks until SIGTERM / SIGINT)
    5. Graceful shutdown: persist index, close DB

Signal handling:
    SIGTERM → graceful shutdown (used by setup.sh start/stop)
    SIGINT  → same (Ctrl+C during development)
"""

import os

# Pin OpenMP/BLAS to a single thread BEFORE any numpy/torch/faiss import.
# PyTorch and FAISS each bundle libomp; two live OpenMP runtimes corrupt each
# other's thread pool → SIGSEGV in __kmp_*. Single-threading prevents the crash.
os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")

import argparse
import signal
import sys
import time
import threading
from pathlib import Path

# ── Project path setup ─────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from synapse.embedder import embed, warmup
from synapse.server import SynapseServer
from synapse.store import SynapseStore
from synapse.observer import Observer


def main():
    parser = argparse.ArgumentParser(description="Synapse semantic memory daemon")
    parser.add_argument(
        "--no-warmup",
        action="store_true",
        help="Skip ANE warmup (faster start, higher first-request latency)",
    )
    args = parser.parse_args()

    print("=" * 56, flush=True)
    print("  Synapse Daemon — on-device semantic memory for macOS", flush=True)
    print("=" * 56, flush=True)
    print(f"  Project root: {PROJECT_ROOT}", flush=True)
    print(flush=True)

    # ── 1. Store ───────────────────────────────────────────────────────────────
    print("[Daemon] Initializing store ...", flush=True)
    store = SynapseStore()
    counts = store.count()
    print(
        f"[Daemon] Store ready — "
        f"{counts['active_snippets']} snippets, "
        f"{counts['faiss_vectors']} FAISS vectors",
        flush=True,
    )

    # ── 2. Embedder ────────────────────────────────────────────────────────────
    print("[Daemon] Loading Core ML model ...", flush=True)
    test_result = embed("Synapse startup check")
    print(
        f"[Daemon] Embedder ready — first embed: {test_result.latency_ms:.1f}ms",
        flush=True,
    )

    # ── 2b. Index rebuild if out of sync ───────────────────────────────────────
    if store.needs_rebuild():
        faiss_n = store._index.ntotal
        sqlite_n = store.count()["active_snippets"]
        print(
            f"[Daemon] Index out of sync ({faiss_n} FAISS vs {sqlite_n} SQLite). "
            f"Rebuilding — this may take a minute ...",
            flush=True,
        )
        rebuilt = store.rebuild_index(embed)
        print(f"[Daemon] Rebuild complete — {rebuilt} vectors indexed.", flush=True)
    else:
        print("[Daemon] Index in sync — skipping rebuild.", flush=True)

    # ── 3. ANE Warmup ─────────────────────────────────────────────────────────
    if not args.no_warmup:
        print("[Daemon] Warming up ANE (3 inferences) ...", flush=True)
        warmup(n=3)
    else:
        print("[Daemon] Warmup skipped (--no-warmup)", flush=True)

    # ── 4. Observer ───────────────────────────────────────────────────────────
    print("[Daemon] Starting Screen Observer background thread ...", flush=True)
    observer_thread = threading.Thread(target=Observer().start, daemon=True)
    observer_thread.start()

    # ── 5. Server ─────────────────────────────────────────────────────────────
    server = SynapseServer(embedder_fn=embed, store=store)

    # ── 6. Signal handlers ────────────────────────────────────────────────────
    def shutdown(signum, frame):
        print(f"\n[Daemon] Received signal {signum} — shutting down ...", flush=True)
        server.stop()
        store.close()
        print("[Daemon] Goodbye.", flush=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    print("\n[Daemon] Ready — press Ctrl+C to stop\n", flush=True)
    server.start()  # blocks


if __name__ == "__main__":
    main()
