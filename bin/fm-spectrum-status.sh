#!/usr/bin/env bash
# Report the health of the fm-spectrum iMessage bridge (bin/fm-spectrum-bridge).
#
# Usage: fm-spectrum-status.sh [--status]
#
# The bridge is a separate, long-running Node process (started by hand today;
# full watcher/wake-queue supervision is a follow-up slice). This script is the
# additive observability piece for THIS slice: it reads the liveness beacon the
# bridge touches periodically (state/.spectrum-bridge-beat) and reports one of:
#
#   disabled  - spectrum is not configured (no SPECTRUM_SELF_HANDLE); exit 0.
#               This is a normal resting state, not a failure.
#   healthy   - the beacon exists and is fresher than the stale threshold; exit 0.
#   stale     - the beacon exists but is older than the stale threshold, i.e. the
#               bridge stopped touching it (hung, crashed, or was never
#               reaped); exit 1.
#   dead      - spectrum IS configured but no beacon file exists at all, i.e.
#               the bridge has never started or was torn down; exit 1.
#
# Deliberately does NOT touch bin/fm-watch.sh, fm-watch-arm.sh, fm-wake-lib.sh,
# or the afk daemon - this is a standalone health check a caller polls by hand
# or from a task's own state/<id>.check.sh, not a watcher wake source (that
# wiring is the next slice).
#
# Stale threshold: SPECTRUM_BRIDGE_STALE_SECS (default 90; the bridge is
# expected to touch its beacon roughly every 20s, so this gives several missed
# cycles of grace before flagging).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-spectrum-lib.sh
. "$SCRIPT_DIR/fm-spectrum-lib.sh"

case "${1:-}" in
  --help|-h)
    echo "usage: fm-spectrum-status.sh [--status]" >&2
    exit 0
    ;;
  --status|'') : ;;
  *) echo "usage: fm-spectrum-status.sh [--status]" >&2; exit 2 ;;
esac

spectrum_load_config

if ! spectrum_configured; then
  echo "spectrum: disabled (not configured)"
  exit 0
fi

STALE_SECS=${SPECTRUM_BRIDGE_STALE_SECS:-90}
case "$STALE_SECS" in ''|*[!0-9]*) STALE_SECS=90 ;; esac

BEACON="$STATE/.spectrum-bridge-beat"
if [ ! -f "$BEACON" ]; then
  echo "spectrum: dead (no beacon found at state/.spectrum-bridge-beat - bridge never started or was torn down)"
  exit 1
fi

NOW=$(date +%s 2>/dev/null) || NOW=0
BEACON_MTIME=$(stat -f '%m' "$BEACON" 2>/dev/null || stat -c '%Y' "$BEACON" 2>/dev/null) || BEACON_MTIME=0
case "$BEACON_MTIME" in ''|*[!0-9]*) BEACON_MTIME=0 ;; esac

AGE=$((NOW - BEACON_MTIME))
[ "$AGE" -ge 0 ] || AGE=0

if [ "$AGE" -gt "$STALE_SECS" ]; then
  printf 'spectrum: stale (beacon %ss ago, expected under %ss - bridge may be hung or crashed)\n' "$AGE" "$STALE_SECS"
  exit 1
fi

printf 'spectrum: healthy (beacon %ss ago)\n' "$AGE"
