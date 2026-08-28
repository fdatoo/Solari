#!/usr/bin/env bash
# Run the local Solari build against an isolated config, so the Homebrew
# Sunshine install and its pairing state stay untouched.
#
#   ./scripts/solari-dev.sh start|stop|restart|status|log|probe|permissions

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/build/Sunshine.app"
BIN="$APP/Contents/MacOS/Sunshine"
CONFIG="$HOME/.config/solari/solari.conf"
LOG="$HOME/.config/solari/solari.log"
PROBE="$REPO/build/solari_input_probe"

is_running() {
  pgrep -f "Sunshine.app/Contents/MacOS/Sunshine" >/dev/null 2>&1
}

stop_server() {
  if is_running; then
    pkill -f "Sunshine.app/Contents/MacOS/Sunshine" || true
    sleep 1
    echo "stopped"
  else
    echo "not running"
  fi
}

start_server() {
  if is_running; then
    echo "already running (use restart)"
    return 0
  fi

  if [[ ! -x "$BIN" ]]; then
    echo "no build at $BIN - run: cmake --build build --parallel" >&2
    exit 1
  fi

  # Re-sign after every rebuild. The signature is what macOS ties the Screen
  # Recording and Accessibility grants to, and a rebuild invalidates it.
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

  open "$APP" --args "$CONFIG"
  sleep 4

  if is_running; then
    echo "started, web UI at https://localhost:47990"
  else
    echo "failed to start, last lines of the log:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
}

case "${1:-status}" in
  start)
    start_server
    ;;
  stop)
    stop_server
    ;;
  restart)
    stop_server
    start_server
    ;;
  status)
    if is_running; then
      echo "running (pid $(pgrep -f 'Sunshine.app/Contents/MacOS/Sunshine' | head -1))"
    else
      echo "not running"
    fi

    echo
    echo "permissions:"
    if grep -q "No screen capture permission" "$LOG" 2>/dev/null; then
      echo "  screen recording: DENIED"
    else
      echo "  screen recording: ok"
    fi
    if grep -q "No accessibility permission" "$LOG" 2>/dev/null; then
      echo "  accessibility:    DENIED (input will be ignored)"
    elif grep -q "Accessibility permission granted" "$LOG" 2>/dev/null; then
      echo "  accessibility:    ok"
    else
      echo "  accessibility:    not reached yet"
    fi

    echo
    echo "encoder:"
    grep -E "Using encoder|Video failed to find working encoder" "$LOG" 2>/dev/null | tail -2 || echo "  (nothing logged)"
    ;;
  log)
    tail -f "$LOG"
    ;;
  probe)
    # Record what a game would actually receive. Hold a modifier during a stream:
    # a correct backend reports one down transition, not one per repeat.
    shift || true
    "$PROBE" "$@"
    ;;
  permissions)
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    sleep 1
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ;;
  *)
    echo "usage: $0 start|stop|restart|status|log|probe|permissions" >&2
    exit 2
    ;;
esac
