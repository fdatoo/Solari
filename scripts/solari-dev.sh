#!/usr/bin/env bash
# Run the local Solari build against an isolated config, so the Homebrew
# Sunshine install and its pairing state stay untouched.
#
#   ./scripts/solari-dev.sh start|stop|restart|status|log|probe|permissions

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/build/Solari.app"
BIN="$APP/Contents/MacOS/Solari"
CONFIG="$HOME/.config/solari/solari.conf"
LOG="$HOME/.config/solari/solari.log"
PROBE="$REPO/build/solari_input_probe"

is_running() {
  pgrep -f "Solari.app/Contents/MacOS/Solari" >/dev/null 2>&1
}

# A rebuild changes the binary, and macOS ties Screen Recording and Accessibility
# grants for an ad-hoc signed app to that exact binary, so every rebuild silently
# revokes them. Signing with a real certificate instead ties the grants to the
# certificate, which survives rebuilds. Set SOLARI_SIGN_ID to one of the identities
# from `security find-identity -v -p codesigning` to get that.
# Prints the signing identity: the certificate name, or "ad-hoc".
signing_identity() {
  local authority
  authority=$(codesign -dvvv "$APP" 2>&1 | grep -m1 "^Authority=" | cut -d= -f2- || true)
  if [[ -n "$authority" ]]; then
    echo "$authority"
  else
    echo "ad-hoc"
  fi
}

sign_app() {
  if [[ -n "${SOLARI_SIGN_ID:-}" ]]; then
    local err
    if err=$(codesign --force --deep --sign "$SOLARI_SIGN_ID" "$APP" 2>&1); then
      return 0
    fi

    # Worth being loud about. Silently falling back to ad-hoc is what makes the
    # permission panes disagree with the running app.
    echo "warning: could not sign with SOLARI_SIGN_ID, falling back to ad-hoc." >&2
    echo "         ${err##*: }" >&2
    echo "         macOS ties permissions to the signature, so Screen Recording" >&2
    echo "         and Accessibility will need re-granting after every rebuild." >&2
    echo "         Fix by running this from your own Terminal:" >&2
    echo "           $0 restart" >&2
  fi

  # Never downgrade an existing real signature to ad-hoc.
  if [[ "$(signing_identity)" != "ad-hoc" ]]; then
    return 0
  fi

  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
}

stop_server() {
  if is_running; then
    pkill -f "Solari.app/Contents/MacOS/Solari" || true
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

  sign_app

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
      echo "running (pid $(pgrep -f 'Solari.app/Contents/MacOS/Solari' | head -1))"
    else
      echo "not running"
    fi

    echo
    echo "signing:    $(signing_identity)"
    if [[ "$(signing_identity)" == "ad-hoc" ]]; then
      echo "            permissions are tied to this exact binary, so any rebuild"
      echo "            revokes them. Run '$0 restart' from your Terminal to sign"
      echo "            with SOLARI_SIGN_ID instead."
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
  reset-permissions)
    # Clears the stale grants a rebuild leaves behind, so the panes stop showing an
    # app as approved when macOS no longer considers it the same app.
    stop_server
    tccutil reset ScreenCapture dev.fdatoo.app.Solari || true
    tccutil reset Accessibility dev.fdatoo.app.Solari || true
    start_server
    echo
    echo "now re-enable Solari in both panes:"
    echo "  $0 permissions"
    ;;
  *)
    echo "usage: $0 start|stop|restart|status|log|probe|permissions|reset-permissions" >&2
    exit 2
    ;;
esac
