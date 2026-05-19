#!/usr/bin/env bash
# setup.sh — Synapse one-shot setup
# Run: bash setup.sh
# Prerequisites: Python 3.12 (via Homebrew), Xcode CLI tools

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
PYTHON="$VENV/bin/python"
PIP="$VENV/bin/pip"

echo "╔══════════════════════════════════════════════════╗"
echo "║  Synapse Setup — On-Device Semantic Memory         ║"
echo "║  MacBook Pro M4 Pro · 38-TOPS ANE                ║"
echo "╚══════════════════════════════════════════════════╝"
echo

# ── 1. Python venv ────────────────────────────────────────────────────────────
if [ ! -d "$VENV" ]; then
    echo "[1/4] Creating Python 3.12 virtual environment ..."
    python3.12 -m venv "$VENV"
else
    echo "[1/4] Virtual environment already exists ✓"
fi

# ── 2. Dependencies ───────────────────────────────────────────────────────────
echo "[2/4] Installing Python dependencies ..."
"$PIP" install --upgrade pip --quiet
"$PIP" install -r "$SCRIPT_DIR/requirements.txt" --quiet
echo "      Done ✓"

# ── 3. Core ML model export ───────────────────────────────────────────────────
MODEL_PATH="$SCRIPT_DIR/models/SynapseEmbedder.mlpackage"
if [ -d "$MODEL_PATH" ]; then
    echo "[3/4] Core ML model already exported ✓"
    MODEL_SIZE=$(du -sh "$MODEL_PATH" | cut -f1)
    echo "      Size: $MODEL_SIZE"
else
    echo "[3/4] Exporting nomic-embed-text-v1.5 → Core ML (INT4) ..."
    echo "      ⚠️  This takes 20–40 minutes on first run"
    echo "      Coffee time ☕"
    echo
    "$PYTHON" "$SCRIPT_DIR/synapse/export_model.py"
fi

# ── 4. Data directories ───────────────────────────────────────────────────────
echo "[4/4] Creating data directories ..."
mkdir -p "$SCRIPT_DIR/data"
echo "      Done ✓"

echo
echo "╔══════════════════════════════════════════════════╗"
echo "║  Setup complete!                                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo
echo "Next steps:"
echo
echo "  # 1. Start the daemon (keep this terminal open)"
echo "  source .venv/bin/activate && python synapse/daemon.py"
echo
echo "  # 2. In another terminal — run benchmarks"
echo "  source .venv/bin/activate && python synapse/benchmark.py --quick"
echo
echo "  # 3. Build and run the SwiftUI demo"
echo "  open SynapseDemo/SynapseDemo.xcodeproj  (or open in Xcode manually)"
echo
echo "  # 4. Run the Swift tests (daemon must be running)"
echo "  cd SynapseKit && swift test"
echo
