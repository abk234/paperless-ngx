#!/usr/bin/env bash
set -euo pipefail
CONF="${HOME}/Library/Application Support/Syncthing"
SYNBIN="/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing"
LOG="${CONF}/syncthing-standalone.log"
PIDFILE="${CONF}/syncthing-standalone.pid"

cmd="${1:-status}"

is_up() {
  curl -sk --connect-timeout 1 -o /dev/null https://127.0.0.1:8384/ 2>/dev/null
}

case "$cmd" in
  start)
    if is_up; then
      echo "Syncthing already running → https://127.0.0.1:8384/"
      exit 0
    fi
    # Avoid GUI wrapper fighting the engine
    osascript -e 'quit app "Syncthing"' >/dev/null 2>&1 || true
    killall Syncthing syncthing >/dev/null 2>&1 || true
    sleep 1
    rm -f "${CONF}/syncthing.lock"
    mkdir -p "$CONF"
    nohup "$SYNBIN" --home="$CONF" --no-upgrade --no-browser >>"$LOG" 2>&1 &
    echo $! >"$PIDFILE"
    for i in 1 2 3 4 5 6 7 8 9 10; do
      is_up && break
      sleep 0.5
    done
    if is_up; then
      echo "Syncthing started → https://127.0.0.1:8384/"
      echo "Login user: attic"
    else
      echo "error: Syncthing did not become ready; see $LOG" >&2
      exit 1
    fi
    ;;
  stop)
    osascript -e 'quit app "Syncthing"' >/dev/null 2>&1 || true
    killall Syncthing syncthing >/dev/null 2>&1 || true
    rm -f "$PIDFILE" "${CONF}/syncthing.lock"
    echo "Syncthing stopped"
    ;;
  status)
    if is_up; then
      echo "running → https://127.0.0.1:8384/"
    else
      echo "stopped (run: ./scripts/syncthing-mac.sh start)"
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|status}" >&2
    exit 1
    ;;
esac
