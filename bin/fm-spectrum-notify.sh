#!/usr/bin/env bash
# Push a proactive escalation (PR-ready / blocked / needs-decision) from
# firstmate to the captain over the private iMessage channel (fm-spectrum).
#
# Usage: fm-spectrum-notify.sh [--target <handle-or-space>] --text-file <path>
#        fm-spectrum-notify.sh [--target <handle-or-space>] -
#        fm-spectrum-notify.sh [--target <handle-or-space>] <text>
#        fm-spectrum-notify.sh <handle-or-space> --text-file <path>   (explicit target, positional)
#        fm-spectrum-notify.sh <text>                                 (default target)
#
# The target is optional. When omitted (no --target and no positional target),
# it defaults to SPECTRUM_TARGET_HANDLE, or else the first handle in
# SPECTRUM_CAPTAIN_HANDLE (which may itself list more than one reachable
# handle for the same captain, comma-separated) - either one works as a send
# target, so a bare invocation just picks one. A positional target is only
# recognized when at least one more argument follows it (so a single bare
# argument is always the message text, using the default target - a
# lone-target-with-no-text call was never valid anyway).
#
# The --text-file / stdin forms exist so firstmate never has to inline message
# text (which may include a PR title, a diff summary, etc.) into a shell
# argument, mirroring fm-x-reply.sh's --text-file/stdin discipline. The
# positional <text> form is kept for quick manual use.
#
# This client never talks to the iMessage bridge directly - it just drops a
# {id, target, text, ts, dry_run} JSON record atomically into
# state/spectrum-outbox/, which bin/fm-spectrum-bridge (a separate, long-running
# process) watches and sends via osascript-driven Messages.app. That keeps this
# script a fast, dependency-light one-shot, exactly like the outbound X-mode
# clients.
#
# Config (home .env, SPECTRUM_ENV_FILE, or env): SPECTRUM_SELF_HANDLE is the
# whole activation signal (mirrors FMX_PAIRING_TOKEN); when absent, this script
# is a hard no-op that exits 0 without writing anything (a stderr note is
# printed so a captain watching the pane can see why nothing went out - but
# nothing is posted anywhere, so it never wakes anyone).
#
# Preview / dry-run: with SPECTRUM_DRY_RUN set (truthy), the message is NOT
# handed to the bridge for sending. The would-be outbox record is still written
# (with dry_run:true, so a bridge that happens to be running skips it too) and a
# "DRY RUN" summary is printed to stderr; stdout still echoes the generated
# message id and the exit is 0. This is the acceptance path that runs end to end
# with no live Messages account and no bridge process required.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-spectrum-lib.sh
. "$SCRIPT_DIR/fm-spectrum-lib.sh"

TMP_FILES=()
cleanup_tmp_files() {
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup_tmp_files EXIT

usage() {
  echo "usage: fm-spectrum-notify.sh [--target <handle-or-space>] --text-file <path> | - | <text>" >&2
}

help() {
  cat <<'EOF'
usage: fm-spectrum-notify.sh [--target <handle-or-space>] --text-file <path>
       fm-spectrum-notify.sh [--target <handle-or-space>] -
       fm-spectrum-notify.sh [--target <handle-or-space>] <text>

Push a proactive escalation to the captain over the private iMessage channel.
The target is optional; omitted, it defaults to SPECTRUM_TARGET_HANDLE, or
else the first handle in SPECTRUM_CAPTAIN_HANDLE.

Options:
  --target <handle-or-space>
                        Explicit send target (also accepted as a bare leading
                        positional argument when at least one more argument
                        follows it).
  --text-file <path>   Read message text from a file instead of the command line.
  -                     Read message text from stdin.
  --help                Show this help.
EOF
}

case "${1:-}" in
  --help|-h) help; exit 0 ;;
esac

if [ "$#" -lt 1 ]; then
  usage
  exit 2
fi

TARGET_EXPLICIT=
case "$1" in
  --text-file|-)
    : # target omitted; text source starts here
    ;;
  --target)
    if [ "$#" -lt 2 ]; then
      echo "usage: fm-spectrum-notify.sh --target <handle-or-space> ..." >&2
      exit 2
    fi
    TARGET_EXPLICIT=$2
    shift 2
    ;;
  *)
    if [ "$#" -ge 2 ]; then
      # A positional target is only recognized when at least one more argument
      # follows it - a single bare argument is always the message text (see
      # the disambiguation note above the usage functions).
      TARGET_EXPLICIT=$1
      shift
    fi
    ;;
esac

if [ "$#" -lt 1 ]; then
  usage
  exit 2
fi

TEXT_SOURCE_KIND="literal"
TEXT_SOURCE_VALUE=
case "$1" in
  --text-file)
    if [ "$#" -lt 2 ]; then
      echo "usage: fm-spectrum-notify.sh [--target <handle-or-space>] --text-file <path>" >&2
      exit 2
    fi
    TEXT_SOURCE_KIND="file"
    TEXT_SOURCE_VALUE=$2
    [ -r "$TEXT_SOURCE_VALUE" ] || { echo "fm-spectrum-notify: cannot read text file: $TEXT_SOURCE_VALUE" >&2; exit 1; }
    ;;
  -)
    TEXT_SOURCE_KIND="stdin"
    ;;
  *)
    TEXT_SOURCE_VALUE=$1
    ;;
esac

spectrum_load_config

# Hard no-op when spectrum is off: exit 0, write nothing (and never consume
# stdin), but say so on stderr (never stdout) so an interactively-watching
# captain can see why - this never wakes anything since nothing is posted or
# queued.
if ! spectrum_configured; then
  echo "fm-spectrum-notify: spectrum not configured (no SPECTRUM_SELF_HANDLE) - skipping" >&2
  exit 0
fi

TARGET=$TARGET_EXPLICIT
[ -n "$TARGET" ] || TARGET=$(spectrum_default_target)
if [ -z "$TARGET" ]; then
  echo "fm-spectrum-notify: no target given and no default available (set SPECTRUM_TARGET_HANDLE or SPECTRUM_CAPTAIN_HANDLE)" >&2
  exit 1
fi

case "$TEXT_SOURCE_KIND" in
  file)
    TEXT_FILE=$TEXT_SOURCE_VALUE
    ;;
  stdin)
    TEXT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-spectrum-notify.XXXXXX") || {
      echo "fm-spectrum-notify: cannot create temp file" >&2; exit 1; }
    TMP_FILES+=("$TEXT_FILE")
    cat > "$TEXT_FILE" || { echo "fm-spectrum-notify: failed to read stdin" >&2; exit 1; }
    ;;
  literal)
    TEXT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-spectrum-notify.XXXXXX") || {
      echo "fm-spectrum-notify: cannot create temp file" >&2; exit 1; }
    TMP_FILES+=("$TEXT_FILE")
    printf '%s' "$TEXT_SOURCE_VALUE" > "$TEXT_FILE" || { echo "fm-spectrum-notify: failed to write message text" >&2; exit 1; }
    ;;
esac

if [ ! -s "$TEXT_FILE" ]; then
  echo "fm-spectrum-notify: empty message text" >&2
  exit 2
fi

OUTBOX="$STATE/spectrum-outbox"
DRY_FLAG=0
[ -n "$SPECTRUM_DRY" ] && DRY_FLAG=1

ID=$(spectrum_outbox_write "$TARGET" "$TEXT_FILE" "$DRY_FLAG" "$OUTBOX") || exit 1

if [ "$DRY_FLAG" = 1 ]; then
  printf 'fm-spectrum-notify: DRY RUN - would send to %s (recorded: state/spectrum-outbox/%s.json): %s\n' \
    "$TARGET" "$ID" "$(head -c 200 "$TEXT_FILE")" >&2
fi

printf '%s\n' "$ID"
