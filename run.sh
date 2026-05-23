#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# Synapse — start the on-device semantic memory daemon.
#   ./run.sh           start daemon (foreground)
#   ./run.sh bg        start daemon (background, logs to /tmp/synapse.log)
#   ./run.sh stop      stop the daemon
#   ./run.sh status    show status
# ─────────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"

VENV="${SYNAPSE_VENV:-$HOME/.synapse-venv}"
PY="$VENV/bin/python"
LOG="/tmp/synapse.log"

if [ ! -x "$PY" ]; then
  echo "Virtualenv not found at $VENV"
  echo "Create it with:  python3.12 -m venv $VENV && $VENV/bin/pip install -r requirements.txt"
  exit 1
fi

cmd="${1:-start}"
case "$cmd" in
  stop)
    pkill -TERM -f "synapse/daemon.py" 2>/dev/null && echo "Stopped." || echo "Not running."
    rm -f /tmp/synapse.sock
    ;;
  status)
    if pgrep -f "synapse/daemon.py" >/dev/null; then
      echo "Daemon RUNNING (pid $(pgrep -f 'synapse/daemon.py'))"
    else
      echo "Daemon NOT running"
    fi
    ;;
  bg)
    pkill -TERM -f "synapse/daemon.py" 2>/dev/null || true
    sleep 1; rm -f /tmp/synapse.sock
    nohup "$PY" -u synapse/daemon.py > "$LOG" 2>&1 &
    echo "Daemon started in background (pid $!). Logs: $LOG"
    ;;
  start|*)
    rm -f /tmp/synapse.sock
    exec "$PY" -u synapse/daemon.py
    ;;
esac
