#!/usr/bin/env python3
"""
tests/test_integration.py
──────────────────────────
Black-box integration tests for the Synapse daemon.

Each test starts with the daemon already running (or uses the module-level
fixture that starts/stops it). Tests talk over the real Unix socket at
/tmp/synapse.sock — identical to how SynapseKit and SynapseDemo do it.

Run:
    # Daemon must be running first:
    python synapse/daemon.py &
    # Then:
    python -m pytest tests/test_integration.py -v
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

# ── Project path ───────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

SOCKET_PATH = "/tmp/synapse.sock"
PYTHON      = sys.executable


# ── Transport helper ───────────────────────────────────────────────────────────

def send(payload: dict, timeout: float = 5.0) -> dict:
    """Send one JSON request to the daemon, return parsed response."""
    fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    fd.settimeout(timeout)
    try:
        fd.connect(SOCKET_PATH)
        msg = json.dumps(payload).encode() + b"\n"
        fd.sendall(msg)

        buf = b""
        while b"\n" not in buf:
            chunk = fd.recv(8192)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.strip())
    finally:
        fd.close()


def store_text(text: str, source: str = "Test") -> int:
    """Helper: store a snippet, return its ID."""
    r = send({"action": "store", "text": text, "source": source})
    assert r["ok"], f"store failed: {r}"
    return r["id"]


def query_text(intent: str, top_k: int = 5) -> list[dict]:
    """Helper: run a query, return result list."""
    r = send({"action": "query", "intent": intent, "top_k": top_k})
    assert r["ok"], f"query failed: {r}"
    return r["results"]


# ── Fixtures ───────────────────────────────────────────────────────────────────

@pytest.fixture(scope="session", autouse=True)
def daemon():
    """
    Session-scoped fixture.
    If the daemon is already running (socket exists), use it.
    Otherwise, start it and shut it down after all tests.
    """
    socket_exists = Path(SOCKET_PATH).exists()

    if socket_exists:
        # Verify it's actually alive
        try:
            r = send({"action": "ping"}, timeout=2.0)
            if r.get("ok"):
                yield  # daemon is running externally
                return
        except Exception:
            pass  # socket file exists but daemon is dead — start fresh

    # Start daemon as subprocess
    proc = subprocess.Popen(
        [PYTHON, str(PROJECT_ROOT / "synapse" / "daemon.py"), "--no-warmup"],
        cwd=str(PROJECT_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    # Wait up to 20 seconds for socket to appear
    deadline = time.time() + 20
    while time.time() < deadline:
        if Path(SOCKET_PATH).exists():
            try:
                r = send({"action": "ping"}, timeout=2.0)
                if r.get("ok"):
                    break
            except Exception:
                pass
        time.sleep(0.25)
    else:
        proc.terminate()
        out, _ = proc.communicate(timeout=5)
        pytest.fail(f"Daemon failed to start. Output:\n{out.decode()}")

    yield

    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


# ── Tests ──────────────────────────────────────────────────────────────────────

class TestProtocol:
    """Verify the basic IPC protocol works correctly."""

    def test_ping(self):
        r = send({"action": "ping"})
        assert r["ok"] is True
        assert r["pong"] is True

    def test_unknown_action_returns_error(self):
        r = send({"action": "frobnicate"})
        assert r["ok"] is False
        assert "error" in r

    def test_store_empty_text_returns_error(self):
        r = send({"action": "store", "text": "   ", "source": "Test"})
        assert r["ok"] is False

    def test_query_empty_intent_returns_error(self):
        r = send({"action": "query", "intent": "", "top_k": 5})
        assert r["ok"] is False

    def test_malformed_json_returns_error(self):
        fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        fd.settimeout(5.0)
        try:
            fd.connect(SOCKET_PATH)
            fd.sendall(b"not valid json\n")
            buf = b""
            while b"\n" not in buf:
                chunk = fd.recv(4096)
                if not chunk:
                    break
                buf += chunk
            r = json.loads(buf.strip())
            assert r["ok"] is False
        finally:
            fd.close()


class TestStore:
    """Verify the store action works correctly."""

    def test_store_returns_positive_id(self):
        sid = store_text("Integration test snippet — store positive ID check")
        assert isinstance(sid, int)
        assert sid > 0

    def test_store_returns_monotonically_increasing_ids(self):
        id1 = store_text("Integration test — first monotonic snippet")
        id2 = store_text("Integration test — second monotonic snippet")
        assert id2 > id1

    def test_store_includes_latency(self):
        r = send({"action": "store", "text": "Latency check snippet", "source": "Test"})
        assert r["ok"]
        assert "latency_ms" in r
        assert r["latency_ms"] >= 0

    def test_count_increases_after_store(self):
        r1 = send({"action": "count"})
        before = r1["active_snippets"]
        store_text("Count check — before/after")
        r2 = send({"action": "count"})
        after = r2["active_snippets"]
        assert after == before + 1


class TestQuery:
    """Verify semantic retrieval works correctly."""

    def test_exact_text_is_top_result(self):
        unique = f"Synapse unique test string {time.time_ns()}"
        sid = store_text(unique, source="TestQuery")
        results = query_text(unique, top_k=5)
        assert results, "Query returned no results"
        assert results[0]["id"] == sid, (
            f"Stored ID {sid} was not the top result. Got: {results[0]}"
        )

    def test_semantic_match_across_paraphrase(self):
        """'doctor visit' should surface 'dentist appointment'."""
        store_text("Alice has a dentist appointment on Thursday at 2pm", source="Calendar")
        results = query_text("doctor visit appointment", top_k=10)
        texts = [r["text"] for r in results]
        assert any("dentist" in t.lower() for t in texts), (
            f"Expected dentist-related result. Got: {texts}"
        )

    def test_results_sorted_by_similarity_descending(self):
        store_text("Apple Neural Engine benchmarks for Core ML", source="Notes")
        store_text("A recipe for spaghetti carbonara with pancetta", source="Reminders")
        results = query_text("Apple Silicon machine learning performance", top_k=5)
        sims = [r["similarity"] for r in results]
        assert sims == sorted(sims, reverse=True), "Results not sorted by similarity"

    def test_similarity_scores_in_valid_range(self):
        store_text("Similarity range check snippet", source="Test")
        results = query_text("Similarity range check", top_k=3)
        for r in results:
            assert -1.0 <= r["similarity"] <= 1.0, (
                f"Similarity {r['similarity']} out of [-1, 1]"
            )

    def test_results_have_required_fields(self):
        store_text("Field presence test", source="Test")
        results = query_text("field presence", top_k=1)
        assert results
        r = results[0]
        for field in ("id", "text", "source", "similarity", "timestamp"):
            assert field in r, f"Missing field: {field}"


class TestDelete:
    """Verify soft-delete removes snippets from future queries."""

    def test_delete_hides_snippet_from_query(self):
        unique = f"Delete-me test {time.time_ns()}"
        sid = store_text(unique, source="Test")

        # Confirm it's retrievable
        before = query_text(unique, top_k=5)
        assert any(r["id"] == sid for r in before), "Snippet not found before delete"

        # Delete it
        r = send({"action": "delete", "id": sid})
        assert r["ok"], f"Delete failed: {r}"
        assert r.get("deleted") is True

        # Should no longer appear
        after = query_text(unique, top_k=10)
        assert not any(r["id"] == sid for r in after), (
            "Snippet still appears after delete"
        )

    def test_delete_nonexistent_returns_deleted_false(self):
        r = send({"action": "delete", "id": 999_999_999})
        assert r["ok"] is True
        assert r["deleted"] is False

    def test_count_decreases_after_delete(self):
        sid = store_text("Count decrease check", source="Test")
        before = send({"action": "count"})["active_snippets"]
        send({"action": "delete", "id": sid})
        after = send({"action": "count"})["active_snippets"]
        assert after == before - 1


class TestConcurrency:
    """Verify the daemon handles concurrent requests without corruption."""

    def test_concurrent_stores_no_corruption(self):
        """20 threads store simultaneously — all IDs must be unique."""
        ids = []
        errors = []
        lock = threading.Lock()

        def worker(i: int):
            try:
                sid = store_text(f"Concurrent store thread {i} at {time.time_ns()}")
                with lock:
                    ids.append(sid)
            except Exception as e:
                with lock:
                    errors.append(str(e))

        threads = [threading.Thread(target=worker, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=15)

        assert not errors, f"Concurrent store errors: {errors}"
        assert len(ids) == 20, f"Expected 20 IDs, got {len(ids)}"
        assert len(set(ids)) == 20, f"Duplicate IDs detected: {sorted(ids)}"

    def test_concurrent_queries_no_crash(self):
        """10 threads query simultaneously — all must succeed."""
        store_text("Concurrent query baseline snippet", source="Test")
        errors = []
        lock = threading.Lock()

        def worker():
            try:
                results = query_text("concurrent query baseline", top_k=3)
                assert isinstance(results, list)
            except Exception as e:
                with lock:
                    errors.append(str(e))

        threads = [threading.Thread(target=worker) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=15)

        assert not errors, f"Concurrent query errors: {errors}"
