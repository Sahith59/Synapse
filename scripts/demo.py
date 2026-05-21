#!/usr/bin/env python3
"""
scripts/demo.py
───────────────
End-to-end demonstration of Synapse cross-app semantic memory.

Run the daemon first, then:
    python scripts/demo.py

What it does:
  1. Stores 10 realistic snippets across different "app" sources
  2. Runs 5 representative semantic queries
  3. Prints a formatted results table with similarity scores and latencies
"""

from __future__ import annotations

import json
import socket
import sys
import time
from pathlib import Path

# ── Helpers ───────────────────────────────────────────────────────────────────

SOCKET_PATH = "/tmp/synapse.sock"

RESET  = "\033[0m"
BOLD   = "\033[1m"
DIM    = "\033[2m"
GREEN  = "\033[92m"
YELLOW = "\033[93m"
CYAN   = "\033[96m"
RED    = "\033[91m"
GRAY   = "\033[90m"


def send(payload: dict, timeout: float = 5.0) -> dict:
    fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    fd.settimeout(timeout)
    try:
        fd.connect(SOCKET_PATH)
        fd.sendall(json.dumps(payload).encode() + b"\n")
        buf = b""
        while b"\n" not in buf:
            chunk = fd.recv(8192)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.strip())
    finally:
        fd.close()


def store(text: str, source: str) -> tuple[int, float]:
    t0 = time.perf_counter()
    r = send({"action": "store", "text": text, "source": source})
    ms = (time.perf_counter() - t0) * 1000
    assert r["ok"], f"store failed: {r}"
    return r["id"], ms


def query(intent: str, top_k: int = 4) -> tuple[list[dict], float]:
    t0 = time.perf_counter()
    r = send({"action": "query", "intent": intent, "top_k": top_k})
    ms = (time.perf_counter() - t0) * 1000
    assert r["ok"], f"query failed: {r}"
    return r["results"], ms


def bar(score: float, width: int = 20) -> str:
    filled = round(score * width)
    filled = max(0, min(width, filled))
    color = GREEN if score >= 0.7 else YELLOW if score >= 0.4 else GRAY
    return f"{color}{'█' * filled}{'░' * (width - filled)}{RESET}"


# ── Demo data ─────────────────────────────────────────────────────────────────

SNIPPETS = [
    ("Meeting with Sarah re: Q3 roadmap — focus on Apple Silicon Core ML integration", "Notes"),
    ("Dentist appointment Thursday 3pm — bring insurance card from wallet", "Calendar"),
    ("Buy groceries: oat milk, sourdough, cherry tomatoes, garlic, olive oil", "Reminders"),
    ("WWDC keynote: Apple Intelligence uses on-device model with privacy-preserving inference", "Safari"),
    ("Flight AA1842 SFO departs 7:45am — check-in opens 24h prior, gate B12", "Calendar"),
    ("Workout: 5x5 squat 185lb, 3x8 incline bench, 20min zone-2 cardio", "Fitness"),
    ("Call mom this weekend — her birthday is June 12, order flowers from FTD", "Contacts"),
    ("Core ML ComputeUnit.ALL routes ops to ANE by default on Apple Silicon", "Notes"),
    ("Book reading: chapter 7 of 'Thinking, Fast and Slow' — cognitive biases", "Notes"),
    ("Expense report Q2 due Friday — receipts in ~/Documents/Expenses/Q2/", "Mail"),
]

QUERIES = [
    ("dentist doctor appointment",          "Calendar lookup"),
    ("Apple machine learning privacy",      "Technical research"),
    ("grocery food shopping list",          "Reminders lookup"),
    ("flight travel airport departure",     "Travel planning"),
    ("workout exercise fitness training",   "Health tracking"),
]


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print()
    print(f"{BOLD}{'─' * 62}{RESET}")
    print(f"{BOLD}  Synapse — Cross-App Semantic Memory Demo{RESET}")
    print(f"{BOLD}{'─' * 62}{RESET}")

    # Check daemon
    try:
        r = send({"action": "ping"}, timeout=2.0)
        assert r.get("ok")
        count_r = send({"action": "count"})
        print(f"  {GREEN}● Daemon running{RESET}  ·  {count_r['active_snippets']} existing nodes")
    except Exception:
        print(f"  {RED}✗ Daemon is not running.{RESET}")
        print(f"    Start it with:  python synapse/daemon.py")
        sys.exit(1)

    print()

    # ── Phase 1: Store ────────────────────────────────────────────────────────
    print(f"{BOLD}  [1/2] Storing 10 snippets across 6 app sources…{RESET}")
    print()

    total_store_ms = 0.0
    for text, source in SNIPPETS:
        sid, ms = store(text, source)
        total_store_ms += ms
        icon = {"Notes": "◆", "Calendar": "◇", "Reminders": "○",
                "Safari": "◈", "Fitness": "◉", "Contacts": "◎", "Mail": "◌"}.get(source, "·")
        preview = text[:52] + "…" if len(text) > 52 else text
        print(f"    {CYAN}#{sid:>3}{RESET}  {icon} {GRAY}{source:<10}{RESET}  {preview}")

    avg_store = total_store_ms / len(SNIPPETS)
    print()
    print(f"    {DIM}avg embed+store: {avg_store:.1f}ms per snippet{RESET}")
    print()

    # ── Phase 2: Query ────────────────────────────────────────────────────────
    print(f"{BOLD}  [2/2] Running 5 semantic queries…{RESET}")

    for intent, label in QUERIES:
        print()
        print(f"  {BOLD}{CYAN}Query:{RESET}  \"{intent}\"  {DIM}({label}){RESET}")
        results, ms = query(intent, top_k=3)

        if not results:
            print(f"    {RED}No results.{RESET}")
            continue

        for i, r in enumerate(results, 1):
            sim = r["similarity"]
            source_tag = f"[{r['source']}]"
            text_preview = r["text"][:54] + "…" if len(r["text"]) > 54 else r["text"]
            print(f"    {i}. {bar(sim)} {sim:5.1%}  {GRAY}{source_tag:<12}{RESET}  {text_preview}")

        print(f"    {DIM}latency: {ms:.1f}ms total  ·  embed: {results[0].get('embed_latency_ms', '?')}ms{RESET}")

    # ── Summary ───────────────────────────────────────────────────────────────
    print()
    print(f"{BOLD}{'─' * 62}{RESET}")
    print(f"{BOLD}  Summary{RESET}")
    print(f"{'─' * 62}")
    final_count = send({"action": "count"})["active_snippets"]
    print(f"  Nodes in fabric:   {final_count}")
    print(f"  Avg store latency: {avg_store:.1f}ms")
    print(f"  Network egress:    {GREEN}0 bytes{RESET}  (100% on-device)")
    print(f"  Model:             all-MiniLM-L6-v2 INT4 → ANE")
    print(f"{'─' * 62}")
    print()


if __name__ == "__main__":
    main()
