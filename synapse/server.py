#!/usr/bin/env python3
"""
synapse/server.py
───────────────
Unix domain socket server — JSON over /tmp/synapse.sock

Protocol (newline-delimited JSON):
  Store request:
    {"action": "store", "text": "...", "source": "Notes"}
    → {"ok": true, "id": 42}

  Query request:
    {"action": "query", "intent": "...", "top_k": 5}
    → {"ok": true, "results": [{"id":1,"text":"...","source":"Notes","similarity":0.91,"timestamp":1716000000.0}, ...]}

  Count request:
    {"action": "count"}
    → {"ok": true, "active_snippets": 1234, "faiss_vectors": 1250}

  Ping (health check):
    {"action": "ping"}
    → {"ok": true, "pong": true}

Design:
  • Each client connection is handled in a dedicated thread
  • Connection closes after one request/response (stateless)
  • Max message size: 64 KB (sufficient for any realistic snippet)
  • Error responses: {"ok": false, "error": "reason"}
"""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time
import traceback
from pathlib import Path
from typing import Callable, Any

from synapse.store import SynapseStore
from synapse.llm import rag_engine

SOCKET_PATH = "/tmp/synapse.sock"
MAX_MSG_BYTES = 65_536      # 64 KB
BACKLOG = 32                # max pending connections

# all-MiniLM-L6-v2 cosine scores are compressed: a strong match sits around
# 0.45-0.6, a usable one around 0.30, and noise below ~0.20. We hide hits under
# the floor, and map the useful band onto a human-readable 0-100 relevance so
# the UI doesn't show a genuinely good match as "25%".
MIN_RELEVANCE = 0.20        # below this, a hit is not shown at all
DEDUP_WINDOW  = 600.0       # seconds: only dedup near-identical captures this recent
_REL_LOW  = 0.20            # maps to ~5%
_REL_HIGH = 0.62            # maps to ~99%


def _calibrate_relevance(cosine: float) -> int:
    """Map a raw cosine similarity onto a 0-100 relevance percentage."""
    if cosine <= _REL_LOW:
        return 5
    if cosine >= _REL_HIGH:
        return 99
    frac = (cosine - _REL_LOW) / (_REL_HIGH - _REL_LOW)
    return int(round(5 + frac * 94))


class SynapseServer:
    def __init__(self, embedder_fn, store):
        """
        Args:
            embedder_fn: callable(text: str) → EmbedResult
            store:       SynapseStore instance
        """
        self._embed = embedder_fn
        self._store = store
        self._sock: socket.socket | None = None
        self._running = False

    # ── Lifecycle ──────────────────────────────────────────────────────────────

    def start(self):
        """Start listening. Blocks until stop() is called."""
        # Clean up stale socket file
        sock_path = Path(SOCKET_PATH)
        if sock_path.exists():
            sock_path.unlink()

        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(SOCKET_PATH)
        self._sock.listen(BACKLOG)
        # 0.5s timeout avoids indefinitely-blocking accept() (macOS 26 SIGSEGV)
        # while keeping connection sockets in normal blocking mode for handlers
        self._sock.settimeout(0.5)
        self._running = True

        print(f"[Server] Listening on {SOCKET_PATH}", flush=True)

        while self._running:
            try:
                conn, _ = self._sock.accept()
                t = threading.Thread(
                    target=self._handle,
                    args=(conn,),
                    daemon=True,
                )
                t.start()
            except socket.timeout:
                continue   # no connection in 0.5s — loop to check _running
            except OSError as e:
                if not self._running:
                    break
                print(f"[Server] accept() OSError (continuing): {e}", flush=True)

    def stop(self):
        """Gracefully shut down the server."""
        self._running = False
        if self._sock:
            self._sock.close()
        sock_path = Path(SOCKET_PATH)
        if sock_path.exists():
            sock_path.unlink()
        print("[Server] Stopped.", flush=True)

    # ── Request handler ────────────────────────────────────────────────────────

    def _handle(self, conn: socket.socket):
        """Handle one client connection: read request, dispatch, write response."""
        try:
            raw = self._recv_message(conn)
            if raw is None:
                return
            response = self._dispatch(raw)
        except Exception as e:
            response = {"ok": False, "error": f"Internal error: {e}"}
            traceback.print_exc()
        finally:
            try:
                self._send_message(conn, response)
            except Exception:
                pass
            conn.close()

    def _dispatch(self, raw: bytes) -> dict:
        """Parse JSON request and route to the appropriate handler."""
        try:
            req = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as e:
            return {"ok": False, "error": f"Invalid JSON: {e}"}

        action = req.get("action", "")

        if action == "ping":
            return {"ok": True, "pong": True}

        elif action == "store":
            text   = req.get("text", "").strip()
            source = req.get("source", "unknown")
            if not text:
                return {"ok": False, "error": "text is required for store"}
            result = self._embed(text)

            # Server-side semantic dedup, scoped to a RECENT time window. We only
            # suppress a near-identical memory (cosine >= 0.96) if it was captured
            # within the last DEDUP_WINDOW seconds. Revisiting the same page later
            # creates a fresh, timestamped memory — so the store reflects activity
            # over time and the count grows as you work, instead of looking frozen.
            existing = self._store.search(result.vector, top_k=1)
            if existing and existing[0].similarity >= 0.96:
                age = time.time() - existing[0].timestamp
                if age < DEDUP_WINDOW:
                    return {
                        "ok": True,
                        "id": existing[0].id,
                        "duplicate": True,
                        "latency_ms": round(result.latency_ms, 2),
                    }

            vid = self._store.add(text, result.vector, source)
            return {"ok": True, "id": vid, "latency_ms": round(result.latency_ms, 2)}

        elif action == "query":
            intent = req.get("intent", "").strip()
            top_k  = int(req.get("top_k", 5))
            if not intent:
                return {"ok": False, "error": "intent is required for query"}
            result = self._embed(intent)
            hits   = self._store.search(result.vector, top_k=top_k)
            # Drop matches below the relevance floor so weak/noise hits don't show
            hits = [h for h in hits if h.similarity >= MIN_RELEVANCE]
            return {
                "ok": True,
                "results": [
                    {
                        "id":         h.id,
                        "text":       h.text,
                        "source":     h.source,
                        "similarity": round(h.similarity, 4),
                        "relevance":  _calibrate_relevance(h.similarity),
                        "timestamp":  h.timestamp,
                    }
                    for h in hits
                ],
                "embed_latency_ms": round(result.latency_ms, 2),
            }

        elif action == "count":
            counts = self._store.count()
            return {"ok": True, **counts}

        elif action == "delete":
            snippet_id = req.get("id")
            if not isinstance(snippet_id, int):
                return {"ok": False, "error": "id must be an integer"}
            deleted = self._store.delete(snippet_id)
            return {"ok": True, "deleted": deleted}

        elif action == "latest":
            latest = self._store.get_latest()
            if latest:
                return {"ok": True, "latest": {
                    "id": latest.id,
                    "text": latest.text,
                    "source": latest.source,
                    "timestamp": latest.timestamp
                }}
            return {"ok": True, "latest": None}
            
        elif action == "ask":
            query = req.get("query", "")
            top_k = req.get("top_k", 3)

            if not query:
                return {"ok": False, "error": "query cannot be empty"}

            # 1. Retrieve — embed returns EmbedResult; pass .vector to search
            embed_result = self._embed(query)
            hits = self._store.search(embed_result.vector, top_k=top_k)
            context_snippets = [hit.text for hit in hits]

            # 2. Generate
            try:
                answer = rag_engine.ask(query, context_snippets)
                return {"ok": True, "answer": answer}
            except Exception as e:
                return {"ok": False, "error": f"RAG generation failed: {str(e)}"}

        elif action == "list":
            limit  = min(int(req.get("limit", 100)), 500)
            offset = int(req.get("offset", 0))
            source = req.get("source")
            items  = self._store.list_snippets(limit=limit, offset=offset, source=source)
            counts = self._store.count()
            return {
                "ok":    True,
                "items": [
                    {"id": i.id, "text": i.text, "source": i.source, "timestamp": i.timestamp}
                    for i in items
                ],
                "total": counts["active_snippets"],
            }

        else:
            return {"ok": False, "error": f"Unknown action: {action!r}"}

    # ── Socket I/O ─────────────────────────────────────────────────────────────

    @staticmethod
    def _recv_message(conn: socket.socket) -> bytes | None:
        """Read until newline (max MAX_MSG_BYTES)."""
        chunks = []
        total = 0
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_MSG_BYTES:
                return None
            if b"\n" in chunk:
                break
        return b"".join(chunks).rstrip(b"\n")

    @staticmethod
    def _send_message(conn: socket.socket, data: dict):
        """Serialize dict to JSON and send with newline delimiter."""
        payload = json.dumps(data).encode("utf-8") + b"\n"
        conn.sendall(payload)
