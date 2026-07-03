#!/usr/bin/env bash
# Shared config resolution for the fm-spectrum iMessage channel (the bridge
# launcher, fm-spectrum-notify.sh, and fm-spectrum-status.sh). Mirrors
# bin/fm-x-lib.sh's opt-in discipline: spectrum is inert until a user drops
# SPECTRUM_SELF_HANDLE into the firstmate home's .env (gitignored).
# SPECTRUM_ENV_FILE can point direct client calls at another .env-style file,
# but bootstrap-style activation still checks $FM_HOME/.env.
#
# This file is sourced, never executed. It defines:
#   spectrum_env_get <key> <file>  - read one KEY=VALUE from a .env-style file
#   spectrum_load_config           - resolve SPECTRUM_SELF, SPECTRUM_CAPTAIN,
#                                     SPECTRUM_TARGET, and SPECTRUM_DRY (env
#                                     wins over .env)
#   spectrum_configured            - true iff SPECTRUM_SELF is non-empty
#   spectrum_default_target        - print the default outbound target
#                                     (SPECTRUM_TARGET_HANDLE, else the first
#                                     handle in SPECTRUM_CAPTAIN_HANDLE)
#   spectrum_outbox_write <target> <text> <dry_run> - atomically drop one
#                                     outbound message for the bridge to pick up
# Callers must have FM_HOME set before calling spectrum_load_config.
#
# SPECTRUM_CAPTAIN_HANDLE may name more than one handle for the same captain
# (e.g. an email and a phone number both reachable on iMessage) as a
# comma-separated list: "tharshan09@gmail.com,+12262246894". Every listed
# handle is honored on inbound (the bridge's sender allowlist); the first
# listed handle is the default outbound target when neither
# SPECTRUM_TARGET_HANDLE nor an explicit --target is given.

# Read the value of KEY from a .env-style file: last assignment wins; tolerates
# a leading "export ", surrounding whitespace, and one layer of matching single
# or double quotes. Prints nothing (and succeeds) when the file or key is
# absent, so callers can treat empty output as "unset".
spectrum_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Resolve the spectrum settings into SPECTRUM_SELF, SPECTRUM_CAPTAIN, and
# SPECTRUM_DRY. An explicit environment variable always wins over the .env
# file. Presence of SPECTRUM_SELF (the firstmate-side iMessage handle) is the
# whole activation signal, exactly like FMX_PAIRING_TOKEN for X mode: absent
# means every caller stays a hard no-op.
# SPECTRUM_DRY is set to "1" when SPECTRUM_DRY_RUN is a truthy value (anything
# other than unset/empty/0/false/no/off), and "" otherwise.
spectrum_load_config() {
  local env_file="${SPECTRUM_ENV_FILE:-$FM_HOME/.env}" dry

  if [ -n "${SPECTRUM_SELF_HANDLE+x}" ]; then
    SPECTRUM_SELF=${SPECTRUM_SELF_HANDLE-}
  else
    SPECTRUM_SELF=$(spectrum_env_get SPECTRUM_SELF_HANDLE "$env_file")
  fi

  # shellcheck disable=SC2034 # SPECTRUM_CAPTAIN is read by callers after sourcing.
  if [ -n "${SPECTRUM_CAPTAIN_HANDLE+x}" ]; then
    SPECTRUM_CAPTAIN=${SPECTRUM_CAPTAIN_HANDLE-}
  else
    SPECTRUM_CAPTAIN=$(spectrum_env_get SPECTRUM_CAPTAIN_HANDLE "$env_file")
  fi

  # shellcheck disable=SC2034 # SPECTRUM_TARGET is read by callers after sourcing.
  if [ -n "${SPECTRUM_TARGET_HANDLE+x}" ]; then
    SPECTRUM_TARGET=${SPECTRUM_TARGET_HANDLE-}
  else
    SPECTRUM_TARGET=$(spectrum_env_get SPECTRUM_TARGET_HANDLE "$env_file")
  fi

  if [ -n "${SPECTRUM_DRY_RUN+x}" ]; then
    dry=${SPECTRUM_DRY_RUN-}
  else
    dry=$(spectrum_env_get SPECTRUM_DRY_RUN "$env_file")
  fi
  # shellcheck disable=SC2034 # SPECTRUM_DRY is read by callers after sourcing.
  case "$(printf '%s' "$dry" | tr '[:upper:]' '[:lower:]')" in
    ''|0|false|no|off) SPECTRUM_DRY="" ;;
    *) SPECTRUM_DRY=1 ;;
  esac
}

# spectrum_configured: succeeds iff SPECTRUM_SELF is non-empty. Callers run
# spectrum_load_config first.
spectrum_configured() {
  [ -n "$SPECTRUM_SELF" ]
}

# spectrum_default_target: print the default outbound target - an explicit
# SPECTRUM_TARGET_HANDLE if set, else the first handle in the comma-separated
# SPECTRUM_CAPTAIN_HANDLE list (whitespace around each entry is trimmed).
# Callers run spectrum_load_config first.
spectrum_default_target() {
  if [ -n "$SPECTRUM_TARGET" ]; then
    printf '%s' "$SPECTRUM_TARGET"
    return 0
  fi
  printf '%s' "$SPECTRUM_CAPTAIN" | cut -d',' -f1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# spectrum_outbox_write <target> <text-file> <dry:0|1> <outbox-dir>: atomically
# drop one outbound message JSON for the bridge (or, in dry-run, for the record
# only - the bridge never has to be running). Prints the generated message id on
# success. <text-file> must already exist and be readable (a "-" caller reads
# stdin to a temp file first, mirroring fm-x-reply.sh's discipline of never
# inlining message text into a shell argument).
spectrum_outbox_write() {
  local target=$1 text_file=$2 dry=$3 outbox_dir=$4 id ts tmp
  command -v jq >/dev/null 2>&1 || { echo "fm-spectrum: jq not found" >&2; return 1; }
  mkdir -p "$outbox_dir" 2>/dev/null || {
    echo "fm-spectrum: cannot create outbox dir: $outbox_dir" >&2
    return 1
  }
  ts=$(date +%s 2>/dev/null) || ts=0
  id="${ts}-$$-${RANDOM:-0}"
  tmp="$outbox_dir/.$id.json.tmp"
  if ! jq -Rs \
    --arg id "$id" \
    --arg target "$target" \
    --argjson ts "$ts" \
    --argjson dry_run "$([ "$dry" = 1 ] && echo true || echo false)" \
    '{id:$id, target:$target, text:., ts:$ts, dry_run:$dry_run}' \
    < "$text_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "fm-spectrum: failed to build outbox record" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$outbox_dir/$id.json" 2>/dev/null; then
    rm -f "$tmp"
    echo "fm-spectrum: cannot write outbox: $outbox_dir/$id.json" >&2
    return 1
  fi
  printf '%s\n' "$id"
}
