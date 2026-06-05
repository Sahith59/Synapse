#!/usr/bin/env python3
"""
synapse/store.py
──────────────
FAISS vector store + SQLite metadata layer.

Architecture fix (v2):
  • Uses IndexIDMap wrapping IndexFlatIP so FAISS labels = SQLite ROWIDs.
    This eliminates the positional-sync problem that caused Resource Deadlock
    crashes when the index fell behind the DB (e.g. after a crash mid-write).
  • Atomic disk writes: index is written to a .tmp file then os.replace'd —
    no partial write can corrupt the on-disk index.
  • Batch flushing: index is persisted every FLUSH_INTERVAL mutations (not
    on every single add) to keep the observer thread from thrashing the disk.

SQLite schema unchanged — backward-compatible.
"""

from __future__ import annotations

import os
import sqlite3
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import faiss
import numpy as np

PROJECT_ROOT = Path(__file__).parent.parent
INDEX_PATH   = PROJECT_ROOT / "data" / "synapse.index"
DB_PATH      = PROJECT_ROOT / "data" / "synapse.db"
EMBED_DIM    = 384

# Flush the FAISS index to disk every N mutations.
# Reduces disk I/O contention while bounding potential data-loss window.
FLUSH_INTERVAL = 20


def _split_tags(raw) -> list[str]:
    """Parse the comma-joined tags column into a list."""
    if not raw:
        return []
    return [t for t in str(raw).split(",") if t]


@dataclass
class QueryResult:
    id: int
    text: str
    source: str
    similarity: float
    timestamp: float
    tags: list[str] = field(default_factory=list)


class SynapseStore:
    """Thread-safe FAISS (IndexIDMap) + SQLite store."""

    def __init__(self):
        INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
        DB_PATH.parent.mkdir(parents=True, exist_ok=True)

        self._lock          = threading.RLock()
        self._pending       = 0         # mutations since last flush
        self._init_db()
        self._load_index()

    # ── SQLite ─────────────────────────────────────────────────────────────────

    def _init_db(self):
        self._db = sqlite3.connect(str(DB_PATH), check_same_thread=False)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("""
            CREATE TABLE IF NOT EXISTS snippets (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                text      TEXT    NOT NULL,
                source    TEXT    NOT NULL DEFAULT 'unknown',
                timestamp REAL    NOT NULL,
                active    INTEGER NOT NULL DEFAULT 1
            )
        """)
        # Migration: add tags column to pre-existing databases.
        cols = {row[1] for row in self._db.execute("PRAGMA table_info(snippets)")}
        if "tags" not in cols:
            self._db.execute("ALTER TABLE snippets ADD COLUMN tags TEXT NOT NULL DEFAULT ''")
        self._db.commit()

    # ── FAISS ─────────────────────────────────────────────────────────────────

    def _make_fresh_index(self) -> faiss.IndexIDMap:
        flat = faiss.IndexFlatIP(EMBED_DIM)
        return faiss.IndexIDMap(flat)

    def _load_index(self):
        if INDEX_PATH.exists():
            try:
                loaded = faiss.read_index(str(INDEX_PATH))
                # Accept both legacy IndexFlatIP and new IndexIDMap formats
                if isinstance(loaded, faiss.IndexIDMap):
                    self._index = loaded
                else:
                    # Legacy format: discard (data is in SQLite; rebuild will re-embed)
                    print(
                        "[Store] Legacy IndexFlatIP detected — discarding stale index. "
                        "Run store.rebuild_index() after embedder loads to re-index.",
                        flush=True,
                    )
                    self._index = self._make_fresh_index()
                print(
                    f"[Store] FAISS index ready — {self._index.ntotal} vectors",
                    flush=True,
                )
            except Exception as e:
                print(f"[Store] Failed to load index ({e}) — starting fresh.", flush=True)
                self._index = self._make_fresh_index()
        else:
            self._index = self._make_fresh_index()
            print("[Store] Created fresh IndexIDMap", flush=True)

    def _persist_index(self, force: bool = False):
        """Atomically flush FAISS index to disk (temp-file → os.replace)."""
        self._pending += 1
        if not force and self._pending < FLUSH_INTERVAL:
            return
        tmp = str(INDEX_PATH) + ".tmp"
        faiss.write_index(self._index, tmp)
        os.replace(tmp, str(INDEX_PATH))   # atomic on POSIX/macOS
        self._pending = 0

    # ── Public API ─────────────────────────────────────────────────────────────

    def add(self, text: str, vector: np.ndarray, source: str = "unknown",
            tags: list[str] | None = None) -> int:
        with self._lock:
            ts  = time.time()
            tag_str = ",".join(tags) if tags else ""
            cur = self._db.execute(
                "INSERT INTO snippets (text, source, timestamp, tags) VALUES (?, ?, ?, ?)",
                (text, source, ts, tag_str),
            )
            row_id = cur.lastrowid
            self._db.commit()

            vec = vector.reshape(1, EMBED_DIM).astype(np.float32)
            ids = np.array([row_id], dtype=np.int64)
            self._index.add_with_ids(vec, ids)
            self._persist_index()

            return row_id

    def search(self, query_vector: np.ndarray, top_k: int = 5) -> list[QueryResult]:
        with self._lock:
            if self._index.ntotal == 0:
                return []

            k = min(top_k * 3, self._index.ntotal)
            q = query_vector.reshape(1, EMBED_DIM).astype(np.float32)

            scores, ids = self._index.search(q, k)
            scores = scores[0]
            ids    = ids[0]

            # ids are SQLite ROWIDs directly (no +1 offset needed)
            valid_ids = [int(i) for i in ids if i >= 0]
            if not valid_ids:
                return []

            placeholders = ",".join("?" * len(valid_ids))
            rows = self._db.execute(
                f"SELECT id, text, source, timestamp, tags "
                f"FROM snippets WHERE id IN ({placeholders}) AND active=1",
                valid_ids,
            ).fetchall()

            meta = {r[0]: r for r in rows}

            results = []
            for score, fid in zip(scores, ids):
                if fid < 0:
                    continue
                sql_id = int(fid)
                if sql_id not in meta:
                    continue
                row = meta[sql_id]
                results.append(QueryResult(
                    id=row[0], text=row[1], source=row[2],
                    similarity=float(score), timestamp=row[3],
                    tags=_split_tags(row[4]),
                ))

            results.sort(key=lambda r: r.similarity, reverse=True)
            return results[:top_k]

    def text_for(self, snippet_id: int) -> Optional[str]:
        """Return the raw text for a memory id (used to re-embed for k-NN)."""
        with self._lock:
            row = self._db.execute(
                "SELECT text FROM snippets WHERE id=? AND active=1", (int(snippet_id),)
            ).fetchone()
            return row[0] if row else None

    def index_size_bytes(self) -> int:
        """On-disk size of the FAISS index file, for the stats panel."""
        try:
            return INDEX_PATH.stat().st_size if INDEX_PATH.exists() else 0
        except Exception:
            return 0

    def get_latest(self) -> Optional[QueryResult]:
        with self._lock:
            row = self._db.execute(
                "SELECT id, text, source, timestamp, tags "
                "FROM snippets WHERE active=1 ORDER BY id DESC LIMIT 1"
            ).fetchone()
            if not row:
                return None
            return QueryResult(id=row[0], text=row[1], source=row[2],
                               similarity=1.0, timestamp=row[3],
                               tags=_split_tags(row[4]))

    def delete(self, snippet_id: int) -> bool:
        with self._lock:
            cur = self._db.execute(
                "UPDATE snippets SET active=0 WHERE id=? AND active=1",
                (snippet_id,),
            )
            self._db.commit()
            if cur.rowcount > 0:
                # Remove from FAISS index
                remove_ids = np.array([snippet_id], dtype=np.int64)
                self._index.remove_ids(remove_ids)
                self._persist_index(force=True)
                return True
            return False

    def count(self) -> dict:
        with self._lock:
            total = self._db.execute(
                "SELECT COUNT(*) FROM snippets WHERE active=1"
            ).fetchone()[0]
            return {
                "active_snippets": total,
                "faiss_vectors":   self._index.ntotal,
            }

    def list_snippets(
        self,
        limit: int = 100,
        offset: int = 0,
        source: Optional[str] = None,
    ) -> list[QueryResult]:
        with self._lock:
            if source:
                rows = self._db.execute(
                    "SELECT id, text, source, timestamp, tags FROM snippets "
                    "WHERE active=1 AND source=? ORDER BY id DESC LIMIT ? OFFSET ?",
                    (source, limit, offset),
                ).fetchall()
            else:
                rows = self._db.execute(
                    "SELECT id, text, source, timestamp, tags FROM snippets "
                    "WHERE active=1 ORDER BY id DESC LIMIT ? OFFSET ?",
                    (limit, offset),
                ).fetchall()
            return [
                QueryResult(id=r[0], text=r[1], source=r[2],
                            similarity=1.0, timestamp=r[3], tags=_split_tags(r[4]))
                for r in rows
            ]

    def needs_rebuild(self) -> bool:
        """True if FAISS index is missing >10% of active SQLite snippets."""
        with self._lock:
            sqlite_count = self._db.execute(
                "SELECT COUNT(*) FROM snippets WHERE active=1"
            ).fetchone()[0]
            if sqlite_count == 0:
                return False
            return self._index.ntotal < sqlite_count * 0.9

    def rebuild_index(self, embed_fn) -> int:
        """
        Re-embed all active SQLite snippets and rebuild the FAISS index.
        Call once from daemon.py after the embedder is loaded, if needs_rebuild().
        Returns the number of vectors rebuilt.
        """
        with self._lock:
            rows = self._db.execute(
                "SELECT id, text FROM snippets WHERE active=1 ORDER BY id"
            ).fetchall()

        flat      = faiss.IndexFlatIP(EMBED_DIM)
        new_index = faiss.IndexIDMap(flat)
        rebuilt   = 0

        for row_id, text in rows:
            try:
                result = embed_fn(text)
                vec    = result.vector.reshape(1, EMBED_DIM).astype(np.float32)
                ids    = np.array([row_id], dtype=np.int64)
                new_index.add_with_ids(vec, ids)
                rebuilt += 1
                if rebuilt % 100 == 0:
                    print(f"[Store] Rebuild: {rebuilt}/{len(rows)} …", flush=True)
            except Exception as e:
                print(f"[Store] Rebuild: skip id={row_id}: {e}", flush=True)

        with self._lock:
            self._index   = new_index
            self._pending = 0
            tmp = str(INDEX_PATH) + ".tmp"
            faiss.write_index(self._index, tmp)
            os.replace(tmp, str(INDEX_PATH))

        print(f"[Store] Rebuild complete — {rebuilt} vectors indexed.", flush=True)
        return rebuilt

    def close(self):
        with self._lock:
            self._persist_index(force=True)
            self._db.close()
