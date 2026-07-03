#!/usr/bin/env bash
# One check cycle for the fm-spectrum iMessage channel: keep the bridge
# supervised, and surface pending inbound captain messages as a watcher wake.
#
# Inert by default: a HARD no-op (exit 0, no output) unless spectrum is
# configured via a non-empty SPECTRUM_SELF_HANDLE - mirrors fm-x-poll.sh's
# activation contract exactly. This script is the body of the watcher check
# shim state/spectrum-watch.check.sh, where the contract is "output => wake
# firstmate, silence => keep sleeping" (see bin/fm-watch.sh's *.check.sh
# sweep), so the no-op keeps the watcher behaving exactly as today for a
# non-spectrum user.
#
# Two responsibilities on every check cycle, both additive to the existing
# watcher backbone (no edits to fm-watch.sh/fm-watch-arm.sh/fm-wake-lib.sh):
#
#   1. Supervision: call bin/fm-spectrum-ensure-bridge.sh so the bridge stays
#      always-on without the captain having to start it by hand. A routine
#      "healthy" or "just started, beacon not written yet" verdict is quiet
#      (it is not captain-relevant); an actual restart (stale/hung bridge) or
#      a fresh start-from-dead (crash, reboot) is surfaced as a wake so
#      firstmate's fleet-state digest reflects it. A genuine ensure-started
#      failure (exit non-zero) is always surfaced.
#   2. Inbound: state/spectrum-inbox/ already holds every captain message the
#      bridge has captured (written directly by the bridge process, no network
#      poll needed - unlike X mode's relay round trip). If anything is
#      pending, print one compact "spectrum-inbound <id>" line naming the
#      OLDEST pending message; spectrum-respond (loaded on that wake) then
#      drains every pending file, not just the named one - same "one wake can
#      stand in for several" contract fmx-respond uses for state/x-inbox/.
#
# Bounded and fast: no network calls (the bridge already does the reading),
# so this never needs curl or holds a check cycle open.
#
# A persistently failing ensure-bridge call is deduped like fm-x-poll.sh's
# relay diagnostics: repeating the identical error every ~20s check cycle
# would wake firstmate needlessly, so only a NEW/changed error message wakes
# again (state/spectrum-poll.error is the marker, mirroring state/x-poll.error).
#
# SPECTRUM_ENSURE_BRIDGE_BIN overrides the ensure-bridge script path (testing
# only; normal use execs the sibling bin/fm-spectrum-ensure-bridge.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-spectrum-lib.sh
. "$SCRIPT_DIR/fm-spectrum-lib.sh"

spectrum_load_config

# Hard no-op when spectrum is off: this is what keeps the check shim inert.
spectrum_configured || exit 0

ERROR_FILE="$STATE/spectrum-poll.error"

emit_error_once() {
  local msg=$1
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf 'spectrum-bridge-error %s\n' "$msg"
}

clear_error() {
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

# --- 1. supervision ----------------------------------------------------------
ENSURE_BRIDGE_BIN="${SPECTRUM_ENSURE_BRIDGE_BIN:-$SCRIPT_DIR/fm-spectrum-ensure-bridge.sh}"
ensure_out=
ensure_rc=0
ensure_out=$("$ENSURE_BRIDGE_BIN" 2>&1) || ensure_rc=$?

if [ "$ensure_rc" -ne 0 ]; then
  emit_error_once "$ensure_out"
else
  clear_error
  if [ -n "$ensure_out" ]; then
    case "$ensure_out" in
      *healthy*|*"no beacon yet"*|*"already in progress"*) : ;;  # routine, stay quiet
      *) printf '%s\n' "$ensure_out" ;;  # started / restarting: worth a wake
    esac
  fi
fi

# --- 2. inbound ---------------------------------------------------------------
INBOX="$STATE/spectrum-inbox"
oldest=$(spectrum_inbox_list "$INBOX" | head -n1)
if [ -n "$oldest" ]; then
  id=$(basename "$oldest")
  id=${id%.json}
  printf 'spectrum-inbound %s\n' "$id"
fi
