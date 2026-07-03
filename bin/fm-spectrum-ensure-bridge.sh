#!/usr/bin/env bash
# Ensure the fm-spectrum iMessage bridge (bin/fm-spectrum-bridge) is running,
# starting or restarting it as needed. Safe to call repeatedly and safe to
# call concurrently - it is the supervision half of slice 2 (docs/spectrum-backend.md),
# making the bridge firstmate's one always-on long-lived child instead of a
# by-hand `nohup ... &` the captain has to remember to run.
#
# Usage: fm-spectrum-ensure-bridge.sh
#   Prints one summary line ("spectrum-bridge: <verdict> ...") and exits 0 on
#   every non-error path (disabled, already healthy, started, restarted).
#   Exits non-zero only on a genuine operational failure (cannot create state
#   dir, cannot acquire the start lock in a way that indicates real trouble,
#   cannot launch the process).
#
# Inert by default: a HARD no-op (exit 0, no output) unless spectrum is
# configured via a non-empty SPECTRUM_SELF_HANDLE - mirrors every other
# fm-spectrum-* script's activation contract.
#
# Idempotency / single-instance guard: an mkdir-based mutex
# (state/.spectrum-bridge.lock) serializes concurrent ensure-started calls (one
# from session-start bootstrap, one from a watcher check cycle, whatever) so
# two callers racing never launch two bridge processes. A stale lock (owner pid
# no longer alive) is reclaimed rather than wedging forever.
#
# Liveness is tracked with a pidfile (state/.spectrum-bridge.pid) plus a
# command-line sanity check (a bare PID is not enough - PIDs get reused), and
# cross-checked against the bridge's own liveness beacon
# (state/.spectrum-bridge-beat, via spectrum_beacon_state() in
# fm-spectrum-lib.sh - the same threshold fm-spectrum-status.sh reports).
# Four cases:
#   - not configured                          -> silent no-op, exit 0
#   - no live tracked process                 -> start fresh
#   - live process, beacon healthy (or not yet written - just started) -> leave alone
#   - live process, beacon stale (hung)        -> terminate it, then start fresh
#
# Never a broad `pkill`: only the specific tracked pid for THIS home is ever
# signaled, and only after confirming (via `ps -o command=`) it actually looks
# like the spectrum bridge - never a bare `kill $(cat pidfile)` with no sanity
# check.
#
# SPECTRUM_BRIDGE_BIN overrides the launcher path (testing only; normal use
# execs the sibling bin/fm-spectrum-bridge).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-spectrum-lib.sh
. "$SCRIPT_DIR/fm-spectrum-lib.sh"

spectrum_load_config

# Hard no-op when spectrum is off: nothing to supervise.
spectrum_configured || exit 0

BRIDGE_BIN="${SPECTRUM_BRIDGE_BIN:-$SCRIPT_DIR/fm-spectrum-bridge}"
PIDFILE="$STATE/.spectrum-bridge.pid"
LOCKDIR="$STATE/.spectrum-bridge.lock"
LOG="$STATE/spectrum-bridge.log"
BEACON="$STATE/.spectrum-bridge-beat"
STALE_SECS=${SPECTRUM_BRIDGE_STALE_SECS:-90}
case "$STALE_SECS" in ''|*[!0-9]*) STALE_SECS=90 ;; esac

mkdir -p "$STATE" 2>/dev/null || {
  echo "spectrum-bridge: cannot create state dir: $STATE" >&2
  exit 1
}

# --- single-instance mutex --------------------------------------------------
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    echo "spectrum-bridge: another ensure-started run is already in progress, skipping"
    exit 0
  fi
  # Stale lock (owner is gone): reclaim it.
  rm -rf "$LOCKDIR" 2>/dev/null
  mkdir "$LOCKDIR" 2>/dev/null || {
    echo "spectrum-bridge: cannot acquire start lock: $LOCKDIR" >&2
    exit 1
  }
fi
echo $$ > "$LOCKDIR/pid" 2>/dev/null || true
trap 'rm -rf "$LOCKDIR" 2>/dev/null || true' EXIT

# bridge_pid_alive <pid>: true iff <pid> is a live process whose command line
# looks like our bridge (guards against a reused pid pointing at something else).
bridge_pid_alive() {
  local pid=$1 cmd
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$cmd" in *spectrum-bridge*) return 0 ;; *) return 1 ;; esac
}

start_bridge() {
  nohup "$BRIDGE_BIN" >>"$LOG" 2>&1 &
  local newpid=$!
  printf '%s\n' "$newpid" > "$PIDFILE" 2>/dev/null || {
    echo "spectrum-bridge: started (pid $newpid) but could not record pidfile: $PIDFILE" >&2
  }
  printf 'spectrum-bridge: started (pid %s)\n' "$newpid"
}

CURRENT_PID=
[ -f "$PIDFILE" ] && CURRENT_PID=$(cat "$PIDFILE" 2>/dev/null || true)

if bridge_pid_alive "$CURRENT_PID"; then
  if [ -f "$BEACON" ]; then
    case "$(spectrum_beacon_state "$BEACON" "$STALE_SECS")" in
      stale)
        echo "spectrum-bridge: pid $CURRENT_PID alive but beacon stale - restarting"
        kill -TERM "$CURRENT_PID" 2>/dev/null || true
        # Bounded grace for a clean app.stop() shutdown before a hard kill;
        # the bridge's own signal handler is expected to exit quickly.
        tries=0
        while [ "$tries" -lt 20 ] && kill -0 "$CURRENT_PID" 2>/dev/null; do
          tries=$((tries + 1))
          sleep 0.25 2>/dev/null || sleep 1
        done
        kill -0 "$CURRENT_PID" 2>/dev/null && kill -KILL "$CURRENT_PID" 2>/dev/null || true
        rm -f "$PIDFILE" "$BEACON" 2>/dev/null || true
        start_bridge
        ;;
      *)
        printf 'spectrum-bridge: healthy (pid %s)\n' "$CURRENT_PID"
        ;;
    esac
  else
    # Alive, beacon not written yet - a freshly started process; leave it be.
    printf 'spectrum-bridge: starting (pid %s, no beacon yet)\n' "$CURRENT_PID"
  fi
else
  start_bridge
fi
