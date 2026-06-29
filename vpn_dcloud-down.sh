#!/usr/bin/env bash
#
# vpn_dcloud-down.sh — cleanly disconnect the dCloud VPN started by
#                      vpn_dcloud-up.sh
#
#   Usage: sudo ./vpn_dcloud-down.sh
#
# Sends SIGTERM so OpenConnect tears down its routes/DNS via vpn-slice.
#
set -euo pipefail

PID_FILE="/run/openconnect.pid"

[ "$(id -u)" -eq 0 ] || { echo "Error: must be run as root (use sudo)." >&2; exit 1; }

wait_for_exit() {  # $1 = pid
  for _ in $(seq 1 20); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.3
  done
  return 1
}

if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE")"
  if kill -0 "$PID" 2>/dev/null; then
    echo "Disconnecting VPN (pid $PID)..."
    kill "$PID"
    if wait_for_exit "$PID"; then
      echo "Disconnected cleanly."
    else
      echo "Process didn't exit; forcing." >&2
      kill -9 "$PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  else
    echo "Stale pid file (no process $PID). Cleaning up."
    rm -f "$PID_FILE"
  fi
elif pgrep -x openconnect >/dev/null; then
  echo "No pid file found, but openconnect is running. Stopping it..."
  pkill -TERM -x openconnect
  echo "Sent stop signal."
else
  echo "VPN is not running."
fi
