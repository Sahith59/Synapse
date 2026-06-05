#!/usr/bin/env python3
"""
synapse/tagger.py
─────────────────
Zero-shot topical tagging for captured memories — no training, no labels file,
no extra model. Each candidate tag is described by a short natural-language
prompt; we embed those prompts once with the same MiniLM model used for search,
then tag a memory by cosine-comparing its embedding against the label vectors
and keeping the nearest ones above a confidence margin.

This is classic zero-shot classification in an embedding space: the model has
never seen these exact categories, yet it places semantically similar text near
the right label. It reuses the embedding the store already computes, so tagging
adds no extra inference cost at store time.
"""

from __future__ import annotations

import threading
import numpy as np

from synapse.embedder import embed

# Candidate tags. The key is the tag shown in the UI; the value is a short
# hypothesis sentence that describes the category for the embedder to match.
_LABEL_PROMPTS = {
    "work":      "work job career employment hiring resume application interview",
    "code":      "programming code software developer git api function bug terminal",
    "research":  "research article documentation reference learning study paper",
    "shopping":  "shopping product price buy cart store order checkout deal",
    "travel":    "travel flight trip hotel booking destination airport itinerary",
    "finance":   "finance money payment bank invoice budget billing transaction",
    "email":     "email inbox message reply sender subject correspondence",
    "social":    "social media chat message conversation post profile feed",
    "writing":   "writing note document draft journal essay outline",
    "health":    "health fitness workout exercise diet medical wellness",
}

_TAG_NAMES: list[str] = list(_LABEL_PROMPTS.keys())
_label_matrix: np.ndarray | None = None   # shape (num_labels, dim), L2-normalized
_lock = threading.Lock()

# A memory must beat this cosine score to receive a tag at all, and a second
# tag is only added if it's within MARGIN of the top tag. MiniLM cosine for a
# clear topical match on short keyword prompts sits around 0.06-0.20.
_MIN_SCORE = 0.045
_MARGIN = 0.035
_MAX_TAGS = 2


def _ensure_labels() -> np.ndarray:
    global _label_matrix
    if _label_matrix is not None:
        return _label_matrix
    with _lock:
        if _label_matrix is None:
            vecs = [embed(p).vector for p in _LABEL_PROMPTS.values()]
            _label_matrix = np.vstack(vecs).astype(np.float32)
    return _label_matrix


def tag_vector(vector: np.ndarray) -> list[str]:
    """Return up to _MAX_TAGS topical tags for an already-embedded memory."""
    labels = _ensure_labels()
    v = vector.astype(np.float32).reshape(-1)
    # Vectors are L2-normalized, so the dot product is cosine similarity.
    scores = labels @ v
    order = np.argsort(scores)[::-1]
    top = order[0]
    if scores[top] < _MIN_SCORE:
        return []
    tags = [_TAG_NAMES[top]]
    for idx in order[1:]:
        if len(tags) >= _MAX_TAGS:
            break
        if scores[idx] >= _MIN_SCORE and (scores[top] - scores[idx]) <= _MARGIN:
            tags.append(_TAG_NAMES[idx])
    return tags


def all_tags() -> list[str]:
    return list(_TAG_NAMES)
