#!/usr/bin/env bash
# Starts everything the phone link needs, in one command.
#
#   scripts/run_phone_link.sh               # relay + desktop app + iOS simulator
#   scripts/run_phone_link.sh --no-mobile   # just the relay and the desktop app
#   scripts/run_phone_link.sh --no-desktop  # just the relay and the phone
#   scripts/run_phone_link.sh pair          # send the copied pairing code to the phone
#
# Three processes have to agree about one string, and it is what breaks first.
# The relay signs every challenge with the address it was *started* on, so a
# desktop dialling `ws://localhost:8787` cannot prove itself to a relay that
# believes it is `ws://127.0.0.1:8787` — and the error you get says only that
# the proof was refused. So this script starts the relay and exports
# GRID_PAIRING_RELAY for the app from the same variable. They cannot drift.
#
# Ctrl-C stops everything it started. A relay that was already listening is left
# running: it is somebody else's, and killing it would be rude to whoever that is.
#
# Written for bash 3.2, which is what macOS ships. No `wait -n`, no associative
# arrays, no `${var,,}`.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${GRID_PAIRING_PORT:-8787}"
# Loopback by name, not `localhost`: see the header. This exact string is what
# the relay signs with and what the app dials.
RELAY_URL="ws://127.0.0.1:${PORT}"
SIMULATOR="${GRID_SIM:-iPhone 17 Pro}"
# From mobile/ios/Runner.xcodeproj. Needed to stop the app: see cleanup().
BUNDLE_ID="ai.autonomous.gridMobile"
# TMPDIR ends with a slash on macOS and not on Linux; strip it so the path
# printed at the end is one a person can paste.
LOGS="${TMPDIR:-/tmp}"
LOGS="${LOGS%/}/grid-phone-link"

WANT_DESKTOP=1
WANT_MOBILE=1
RELAY_PID=""
DESKTOP_PID=""
MOBILE_PID=""
SIM_UDID=""
STARTED_RELAY=0

say() { printf '  %s\n' "$*"; }
step() { printf '\n▸ %s\n' "$*"; }
die() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

# --- finding the pieces -------------------------------------------------------

# The candidate list is a convenience, never an assertion: §10 of the
# conventions records what happened the last time a path was written down here
# as if it were true everywhere. GRID_FLUTTER is the answer when it is wrong.
resolve_flutter() {
  if [ -n "${GRID_FLUTTER:-}" ]; then
    [ -x "$GRID_FLUTTER" ] || die "GRID_FLUTTER points at $GRID_FLUTTER, which is not executable."
    printf '%s\n' "$GRID_FLUTTER"
    return
  fi
  if command -v flutter >/dev/null 2>&1; then
    command -v flutter
    return
  fi
  for candidate in \
    "$HOME/WorkPlace/Flutter/flutter/bin/flutter" \
    "$HOME/flutter/bin/flutter" \
    "$HOME/development/flutter/bin/flutter" \
    "/opt/homebrew/bin/flutter"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  die "Can't find flutter. Put it on PATH, or run: GRID_FLUTTER=/path/to/flutter $0"
}

resolve_cli_repo() {
  for candidate in "${GRID_CLI_REPO:-}" "$REPO/../autonomous-grid"; do
    if [ -n "$candidate" ] && [ -f "$candidate/pairing_relay/__main__.py" ]; then
      (cd "$candidate" && pwd)
      return
    fi
  done
  die "Can't find the relay. It lives in the CLI repo, beside this one as
    ../autonomous-grid, or wherever GRID_CLI_REPO points."
}

# Which python can actually run the relay, proved by importing what it needs.
#
# Do not assume the CLI repo's own .venv: on the machine this was written for it
# has ruff and pytest but no `cryptography`, so `-m pairing_relay` dies at import
# with a traceback that looks like the relay is broken.
resolve_python() {
  local repo="$1"
  for candidate in "${GRID_PYTHON:-}" "$repo/.venv/bin/python3" python3; do
    [ -n "$candidate" ] || continue
    if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
      if "$candidate" -c 'import fastapi, uvicorn, cryptography, websockets' >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return
      fi
    fi
  done
  die "No python here can run the relay. It needs fastapi, uvicorn, cryptography
    and websockets:  python3 -m pip install fastapi uvicorn cryptography websockets"
}

# --- the pieces ---------------------------------------------------------------

relay_is_up() {
  curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1
}

start_relay() {
  step "Relay on port $PORT"
  if relay_is_up; then
    say "Already listening — leaving it alone."
    return
  fi
  local repo python
  repo="$(resolve_cli_repo)"
  python="$(resolve_python "$repo")"
  say "$python -m pairing_relay  (in $repo)"
  ( cd "$repo" && exec "$python" -m pairing_relay --port "$PORT" --origin "$RELAY_URL" ) \
    >"$LOGS/relay.log" 2>&1 &
  RELAY_PID=$!
  STARTED_RELAY=1

  local waited=0
  while [ "$waited" -lt 20 ]; do
    if relay_is_up; then
      say "Up. Proofs bound to $RELAY_URL"
      return
    fi
    if ! kill -0 "$RELAY_PID" 2>/dev/null; then
      say "--- relay.log ---"
      tail -20 "$LOGS/relay.log" >&2 || true
      die "The relay stopped before it was ready."
    fi
    sleep 1
    waited=$((waited + 1))
  done
  die "The relay never answered /healthz. See $LOGS/relay.log"
}

# Sets SIM_UDID rather than printing it: `say` writes to stdout too, so
# capturing this function's output would have swallowed every message in it.
boot_simulator() {
  step "Simulator: $SIMULATOR"
  local udid
  udid="$(xcrun simctl list devices available \
    | grep -F "$SIMULATOR (" \
    | head -1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
  [ -n "$udid" ] || die "No available simulator called '$SIMULATOR'.
    Pick one from: xcrun simctl list devices available
    then:          GRID_SIM='iPhone 16' $0"
  if xcrun simctl list devices booted | grep -q "$udid"; then
    say "Already booted."
  else
    xcrun simctl boot "$udid"
    say "Booted."
  fi
  open -a Simulator
  SIM_UDID="$udid"
}

start_desktop() {
  step "Grid on this computer"
  # A second copy will not replace the first: the running app holds the port the
  # tooling attaches on, so `flutter run` quietly shows you the OLD build and
  # every change you make appears to do nothing.
  if pgrep -f "Grid.app/Contents/MacOS/Grid" >/dev/null 2>&1; then
    say "⚠ Grid is already running. Quit it first, or this build will not be"
    say "  the one you end up looking at."
  fi
  say "flutter run -d macos   (first build takes a few minutes)"
  ( cd "$REPO" && GRID_PAIRING_RELAY="$RELAY_URL" exec "$FLUTTER" run -d macos ) \
    >"$LOGS/desktop.log" 2>&1 &
  DESKTOP_PID=$!
}

start_mobile() {
  local udid="$1"
  step "Grid on the phone"
  say "flutter run -d $udid"
  ( cd "$REPO/mobile" && exec "$FLUTTER" run -d "$udid" ) \
    >"$LOGS/mobile.log" 2>&1 &
  MOBILE_PID=$!
}

# --- pairing ------------------------------------------------------------------

send_pairing_code() {
  command -v pbpaste >/dev/null 2>&1 || die "'pair' needs pbpaste, so it is macOS only."
  local code
  code="$(pbpaste | tr -d '[:space:]')"
  case "$code" in
    grid://pair?code=*) ;;
    *) die "The clipboard does not hold a pairing code.
    Copy it from Grid on this computer: Settings ▸ Phone ▸ Create code ▸ Copy." ;;
  esac
  xcrun simctl list devices booted | grep -q Booted \
    || die "No simulator is booted. Run $0 first."
  xcrun simctl openurl booted "$code"
  printf '\n  Sent. Tap "Open" on the phone — iOS asks that once per link.\n\n'
}

# --- lifecycle ----------------------------------------------------------------

# Kills a process and everything under it, children first.
#
# `flutter` is a shell script that spawns `dart`, which spawns the app. Killing
# only the PID we hold leaves the dart process running — MEASURED: it survived
# every Ctrl-C until this existed. That orphan is not harmless: it holds the
# port the tooling attaches on, so the next run shows you the OLD build and
# your changes appear to do nothing (see the single-instance note in §10).
stop_tree() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    stop_tree "$child"
  done
  kill "$pid" 2>/dev/null || true
}

cleanup() {
  trap - EXIT INT TERM
  printf '\n▸ Stopping\n'
  stop_tree "$MOBILE_PID"
  # The app on the phone is NOT a child of `flutter run` — the simulator
  # launches it, so the process tree above does not reach it. MEASURED: after a
  # clean stop, two Runner processes were still serving screens from a build
  # nobody was running any more, which is the iOS version of the stale-build
  # trap in the note above.
  if [ -n "$SIM_UDID" ]; then
    xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  stop_tree "$DESKTOP_PID"
  if [ "$STARTED_RELAY" -eq 1 ] && [ -n "$RELAY_PID" ]; then
    stop_tree "$RELAY_PID"
    say "Relay stopped."
  elif [ -n "${RELAY_PID:-}" ] || relay_is_up; then
    say "Relay left running — it was up before this script was."
  fi
  wait 2>/dev/null || true
}

main() {
  for argument in "$@"; do
    case "$argument" in
      pair) send_pairing_code; exit 0 ;;
      --no-desktop) WANT_DESKTOP=0 ;;
      --no-mobile) WANT_MOBILE=0 ;;
      -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "Unknown argument: $argument" ;;
    esac
  done

  if [ "$(uname -s)" != "Darwin" ] && [ "$WANT_MOBILE" -eq 1 ]; then
    WANT_MOBILE=0
    say "Not macOS, so there is no iOS simulator — starting the rest."
  fi

  mkdir -p "$LOGS"
  FLUTTER="$(resolve_flutter)"
  trap cleanup EXIT INT TERM

  start_relay

  if [ "$WANT_MOBILE" -eq 1 ]; then
    boot_simulator
  fi
  # `if`, not `[ … ] && cmd`: under `set -e` a test that comes out false is a
  # failed command, and the script would exit here rather than skip a step.
  if [ "$WANT_DESKTOP" -eq 1 ]; then
    start_desktop
  fi
  if [ -n "$SIM_UDID" ]; then
    start_mobile "$SIM_UDID"
  fi

  printf '\n▸ Running. Logs in %s\n' "$LOGS"
  if [ -n "$DESKTOP_PID" ]; then
    say "desktop   tail -f $LOGS/desktop.log"
  fi
  if [ -n "$MOBILE_PID" ]; then
    say "phone     tail -f $LOGS/mobile.log"
  fi
  printf '\n  To pair: Settings ▸ Phone ▸ Connect to relay ▸ Create code ▸ Copy\n'
  printf '           then, in another terminal:  %s pair\n' "$0"
  printf '\n  Ctrl-C stops everything.\n\n'
  wait
}

main "$@"
