#!/usr/bin/env bash
# Mirror a captain-facing escalation (AGENTS.md section 9: work ready for
# review, a blocker, a failure, a needed decision or credential) out to the
# captain's phone over the private iMessage channel, but ONLY when it would
# actually help - the captain is away from a live session AND the channel is
# configured. This is the slice-2 "auto-push escalations" piece
# (docs/spectrum-backend.md); it is a thin, additive wrapper around
# bin/fm-spectrum-notify.sh, never a replacement for it or for the normal
# chat-surfaced escalation.
#
# Usage: fm-spectrum-escalate.sh --text-file <path>
#        fm-spectrum-escalate.sh -
#        fm-spectrum-escalate.sh <text>
#
# Gating (both must hold, or this is a silent no-op - exit 0, nothing sent,
# nothing printed on stdout):
#   1. spectrum is configured (non-empty SPECTRUM_SELF_HANDLE) - exactly the
#      same activation signal every other fm-spectrum-* script uses.
#   2. state/.afk exists - away-mode is active (see the `afk` skill and
#      AGENTS.md section 8's "Away-mode stub"), i.e. the captain is not
#      watching a live session right now. When a session IS live, the normal
#      chat-surfaced escalation already reaches the captain, so pushing a
#      duplicate notification would just be noise.
# Neither condition is an error; this script's whole job is to be silent
# unless both are true, so it is safe to call at every escalation point
# unconditionally (see AGENTS.md section 9's "Reaches the captain immediately"
# list) with zero behavior change for a captain who has never configured the
# channel or is actively at the keyboard.
#
# Text input mirrors fm-spectrum-notify.sh (--text-file / stdin / a literal
# positional argument) - message text is never inlined into a shell argument
# by firstmate itself when it might carry untrusted content (a PR title, a
# diff summary), so prefer --text-file or stdin from calling code.
#
# This script never talks to the bridge directly; it forwards straight to
# bin/fm-spectrum-notify.sh (default target, SPECTRUM_DRY_RUN honored exactly
# as it is there), so all outbox/dry-run/target-resolution behavior is
# defined in exactly one place.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-spectrum-lib.sh
. "$SCRIPT_DIR/fm-spectrum-lib.sh"

case "${1:-}" in
  --help|-h)
    cat >&2 <<'EOF'
usage: fm-spectrum-escalate.sh --text-file <path> | - | <text>

Push a captain-facing escalation to the private iMessage channel, but only
when spectrum is configured AND state/.afk (away-mode) is active. Silent
no-op otherwise. See docs/spectrum-backend.md.
EOF
    exit 0
    ;;
esac

if [ "$#" -lt 1 ]; then
  echo "usage: fm-spectrum-escalate.sh --text-file <path> | - | <text>" >&2
  exit 2
fi

spectrum_load_config
spectrum_configured || exit 0
[ -f "$STATE/.afk" ] || exit 0

exec "$SCRIPT_DIR/fm-spectrum-notify.sh" "$@"
