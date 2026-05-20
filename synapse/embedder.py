#!/usr/bin/env python3
"""
synapse/embedder.py
─────────────────
Sentence embedding via all-MiniLM-L6-v2, run directly in PyTorch.

Design decisions:
  • Model loaded once at startup (lazy singleton) — avoids repeated disk I/O
  • Pure PyTorch inference (CPU) — no CoreML/ANE dependency, no fragile export
    step, no macOS-26 ANE resetAfterLingering: crash. ~15ms/embed after warmup.
  • Mean-pooled, L2-normalized output (384-dim) → FAISS inner product = cosine
  • All inference serialized with _lock — torch CPU inference is thread-safe but
    we keep a single lock for deterministic latency under the daemon's threads
"""

from __future__ import annotations

import os
import time
import threading
from dataclasses import dataclass
from pathlib import Path

import numpy as np

# FAISS and PyTorch each bundle their own libomp. Two live OpenMP runtimes
# corrupt each other's thread-pool state → SIGSEGV in __kmp_* on macOS.
# Pin every OpenMP/BLAS backend to a single thread BEFORE torch/faiss import
# so no conflicting worker threads are ever spawned.
os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")

_tokenizer = None
_model = None
_torch = None
_lock = threading.Lock()

MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
SEQ_LEN = 128
EMBED_DIM = 384


@dataclass
class EmbedResult:
    vector: np.ndarray   # shape: (384,), float32, L2-normalized
    latency_ms: float


def _load_once():
    """Load tokenizer + model (called only on first use)."""
    global _tokenizer, _model, _torch

    with _lock:
        if _model is not None:
            return

        import torch
        from transformers import AutoTokenizer, AutoModel

        _torch = torch
        print("[Embedder] Loading tokenizer + model ...", flush=True)
        t0 = time.perf_counter()
        try:
            _tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME, local_files_only=True)
            _model = AutoModel.from_pretrained(MODEL_NAME, local_files_only=True)
        except Exception:
            # Cache miss — allow one network fetch
            _tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
            _model = AutoModel.from_pretrained(MODEL_NAME)
        _model.eval()
        torch.set_num_threads(1)  # single thread — avoids libomp double-runtime crash
        load_ms = (time.perf_counter() - t0) * 1000
        print(f"[Embedder] Model ready in {load_ms:.0f}ms", flush=True)


def embed(text: str) -> EmbedResult:
    """Embed a single text string → 384-dim L2-normalized float32 vector."""
    _load_once()

    with _lock:
        t0 = time.perf_counter()
        enc = _tokenizer(
            text,
            max_length=SEQ_LEN,
            padding=True,
            truncation=True,
            return_tensors="pt",
        )
        with _torch.no_grad():
            out = _model(**enc)
        hidden = out.last_hidden_state                       # (1, seq, 384)
        mask = enc["attention_mask"].unsqueeze(-1).float()   # (1, seq, 1)
        pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        pooled = _torch.nn.functional.normalize(pooled, p=2, dim=-1)
        vector = pooled[0].numpy().astype(np.float32)
        latency_ms = (time.perf_counter() - t0) * 1000

    return EmbedResult(vector=vector, latency_ms=latency_ms)


def embed_batch(texts: list[str]) -> list[EmbedResult]:
    """Embed multiple texts (sequential)."""
    return [embed(t) for t in texts]


def warmup(n: int = 3):
    """Run n warmup inferences to stabilize latency. Call once at daemon startup."""
    dummy = "warmup " * 10
    latencies = []
    for i in range(n):
        r = embed(dummy)
        latencies.append(r.latency_ms)
        print(f"[Embedder] Warmup {i+1}/{n}: {r.latency_ms:.1f}ms", flush=True)
    print(
        f"[Embedder] Warmup done — "
        f"avg {sum(latencies)/len(latencies):.1f}ms, last {latencies[-1]:.1f}ms",
        flush=True,
    )
