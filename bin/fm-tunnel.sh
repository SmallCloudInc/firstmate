#!/usr/bin/env bash
# fm-tunnel.sh - expose a locally-running project on the internet via a
# remotely-managed ("token-run") Cloudflare Tunnel, behind a Cloudflare Access
# email login gate, on one of the captain's own domains.
#
# Usage:
#   fm-tunnel.sh up <project> [--hostname <host>] [--zone <zone>] \
#                              [--service <url>] [--emails <e1,e2,...>] \
#                              [--install-cloudflared]
#   fm-tunnel.sh down <project>
#   fm-tunnel.sh status <project>
#   fm-tunnel.sh --help
#
# Config precedence per setting (hostname/zone/service/emails), highest first:
#   1. the matching CLI flag
#   2. a real process environment variable named FM_TUNNEL_<PROJECT>_<SUFFIX>
#   3. that same key in $FM_HOME/config/cloudflare.env
# <PROJECT> is <project> upper-cased with every non [A-Z0-9] character folded
# to '_' (e.g. project "house-hunter" -> FM_TUNNEL_HOUSE_HUNTER_HOSTNAME).
# Missing a required setting after all three is a hard error naming exactly
# what to set.
#
# $FM_HOME/config/cloudflare.env (gitignored) also carries the account-wide
# CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. See AGENTS.md for the
# required token scopes and a documented example file.
#
# `up` is idempotent: every Cloudflare resource is found-by-name/hostname
# before it is created, so re-running never duplicates a tunnel, DNS record,
# Access app, or Access policy - existing ones are updated in place instead.
# The local connector is a firstmate-owned macOS LaunchAgent
# (com.firstmate.tunnel.<project>) that execs `cloudflared tunnel run --token
# ...`; nothing is ever written into projects/. Its run-token is stored
# gitignored at $FM_HOME/config/tunnel-<project>.token (0600) and is never
# printed to stdout/stderr/logs.
#
# `down` stops the connector, then deletes the Access policy, Access app, DNS
# record, and tunnel (in that order so nothing keeps a dangling reference to
# something already removed), and removes the local token file. Safe to run
# on a partially-provisioned or already-torn-down project. It exits non-zero,
# with a summary of what survived, if any lookup or delete failed - so a bad
# API token never reads as a successful teardown.
#
# `status` reports what currently exists without changing anything, and says
# "lookup failed" rather than "not found" when Cloudflare could not be queried.
#
# Requires: curl, python3 (JSON), launchctl (macOS), and cloudflared. A missing
# cloudflared is a hard error naming the install command; pass
# --install-cloudflared to `up` to opt into installing it via Homebrew.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-tunnel-lib.sh
. "$SCRIPT_DIR/fm-tunnel-lib.sh"

trap cf_cleanup_tmp EXIT
trap 'cf_cleanup_tmp; exit 130' INT
trap 'cf_cleanup_tmp; exit 143' TERM

usage() {
  cat >&2 <<'EOF'
usage: fm-tunnel.sh up <project> [--hostname <host>] [--zone <zone>] [--service <url>] [--emails <e1,e2,...>] [--install-cloudflared]
       fm-tunnel.sh down <project>
       fm-tunnel.sh status <project>
       fm-tunnel.sh --help
EOF
}

# Print the header comment block: every line from line 2 up to (not including)
# the first non-comment line, so the help text cannot drift out of sync with
# the header's length.
help() {
  sed -n '2,${/^#/!q; s/^# \{0,1\}//; p;}' "$0"
}

case "${1:-}" in
  --help|-h|help) help; exit 0 ;;
esac

CMD=${1:-}
if [ -z "$CMD" ]; then
  usage
  exit 2
fi
shift

case "$CMD" in
  up|down|status) : ;;
  *) echo "fm-tunnel: unknown command '$CMD'" >&2; usage; exit 2 ;;
esac

PROJECT=${1:-}
if [ -z "$PROJECT" ]; then
  echo "fm-tunnel: $CMD requires a <project> argument" >&2
  usage
  exit 2
fi
shift

case "$PROJECT" in
  *[!A-Za-z0-9_-]*|'')
    echo "fm-tunnel: invalid project id '$PROJECT' (use letters, digits, '-', '_')" >&2
    exit 2
    ;;
esac

CLI_HOSTNAME=""
CLI_ZONE=""
CLI_SERVICE=""
CLI_EMAILS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)
      [ $# -ge 2 ] || { echo "fm-tunnel: --hostname requires a value" >&2; exit 2; }
      CLI_HOSTNAME=$2; shift 2 ;;
    --zone)
      [ $# -ge 2 ] || { echo "fm-tunnel: --zone requires a value" >&2; exit 2; }
      CLI_ZONE=$2; shift 2 ;;
    --service)
      [ $# -ge 2 ] || { echo "fm-tunnel: --service requires a value" >&2; exit 2; }
      CLI_SERVICE=$2; shift 2 ;;
    --emails)
      [ $# -ge 2 ] || { echo "fm-tunnel: --emails requires a value" >&2; exit 2; }
      CLI_EMAILS=$2; shift 2 ;;
    --install-cloudflared)
      [ "$CMD" = up ] || { echo "fm-tunnel: --install-cloudflared is only valid for 'up'" >&2; exit 2; }
      FM_TUNNEL_INSTALL_CLOUDFLARED=1; export FM_TUNNEL_INSTALL_CLOUDFLARED; shift ;;
    *) echo "fm-tunnel: unknown option '$1'" >&2; usage; exit 2 ;;
  esac
done

for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "fm-tunnel: $tool not found on PATH (required for Cloudflare API calls)" >&2
    exit 1
  }
done

fm_tunnel_load_config
if [ -z "$CF_TOKEN" ]; then
  echo "fm-tunnel: no CLOUDFLARE_API_TOKEN (set it in $FM_TUNNEL_CONFIG_FILE_RESOLVED or the environment)" >&2
  exit 1
fi
if [ -z "$CF_ACCOUNT_ID" ]; then
  echo "fm-tunnel: no CLOUDFLARE_ACCOUNT_ID (set it in $FM_TUNNEL_CONFIG_FILE_RESOLVED or the environment)" >&2
  exit 1
fi

# resolve_or_die <suffix> <cli-value> <outvar> <flag-name>: resolve one
# project setting through fm_tunnel_resolve and die with an actionable
# message if it is still unset after CLI flag, env var, and config file.
resolve_or_die() {
  local suffix=$1 cli_value=$2 outvar=$3 flag=$4 val varname
  val=$(fm_tunnel_resolve "$PROJECT" "$suffix" "$cli_value")
  if [ -z "$val" ]; then
    varname=$(fm_tunnel_project_var "$PROJECT" "$suffix")
    echo "fm-tunnel: missing $flag for project '$PROJECT' - pass --$flag or set $varname in $FM_TUNNEL_CONFIG_FILE_RESOLVED" >&2
    exit 1
  fi
  printf -v "$outvar" '%s' "$val"
}

case "$CMD" in
  up)
    resolve_or_die HOSTNAME "$CLI_HOSTNAME" HOSTNAME hostname
    resolve_or_die ZONE "$CLI_ZONE" ZONE zone
    resolve_or_die SERVICE "$CLI_SERVICE" SERVICE service
    resolve_or_die ACCESS_EMAILS "$CLI_EMAILS" EMAILS_RAW emails
    IFS=',' read -r -a EMAILS <<< "$EMAILS_RAW"
    # trim whitespace around each email and drop empties from trailing commas
    TRIMMED_EMAILS=()
    for e in "${EMAILS[@]}"; do
      e="${e#"${e%%[![:space:]]*}"}"
      e="${e%"${e##*[![:space:]]}"}"
      [ -n "$e" ] && TRIMMED_EMAILS+=("$e")
    done
    if [ "${#TRIMMED_EMAILS[@]}" -eq 0 ]; then
      echo "fm-tunnel: no Access emails resolved for project '$PROJECT'" >&2
      exit 1
    fi

    TUNNEL_NAME="firstmate-$PROJECT"
    echo "fm-tunnel: provisioning '$PROJECT' -> https://$HOSTNAME (tunnel '$TUNNEL_NAME', zone '$ZONE')" >&2

    TUNNEL_ID=$(cf_tunnel_find "$TUNNEL_NAME") || { echo "fm-tunnel: aborting; nothing else was touched" >&2; exit 1; }
    if [ -n "$TUNNEL_ID" ]; then
      echo "fm-tunnel: [1/6] tunnel '$TUNNEL_NAME' already exists ($TUNNEL_ID)" >&2
    else
      TUNNEL_ID=$(cf_tunnel_create "$TUNNEL_NAME") || { echo "fm-tunnel: aborting; nothing else was touched" >&2; exit 1; }
      echo "fm-tunnel: [1/6] created tunnel '$TUNNEL_NAME' ($TUNNEL_ID)" >&2
    fi
    [ -n "$TUNNEL_ID" ] || { echo "fm-tunnel: Cloudflare did not return a tunnel id" >&2; exit 1; }

    if ! cf_tunnel_set_ingress "$TUNNEL_ID" "$HOSTNAME" "$SERVICE"; then
      echo "fm-tunnel: aborting after step 1/6 (tunnel '$TUNNEL_NAME' / $TUNNEL_ID exists; ingress NOT set)" >&2
      exit 1
    fi
    echo "fm-tunnel: [2/6] ingress set: $HOSTNAME -> $SERVICE" >&2

    ZONE_ID=$(cf_zone_id "$ZONE") || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; DNS/Access NOT done)" >&2; exit 1; }
    if [ -z "$ZONE_ID" ]; then
      echo "fm-tunnel: zone '$ZONE' not found on this account - aborting after step 2/6 (tunnel+ingress done; DNS/Access NOT done)" >&2
      exit 1
    fi
    DNS_CONTENT="$TUNNEL_ID.cfargotunnel.com"
    DNS_ID=$(cf_dns_find "$ZONE_ID" "$HOSTNAME") || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; DNS/Access NOT done)" >&2; exit 1; }
    if [ -n "$DNS_ID" ]; then
      CURRENT_CONTENT=$(cf_dns_current_content "$ZONE_ID" "$DNS_ID") || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; DNS record found but unreadable)" >&2; exit 1; }
      if [ "$CURRENT_CONTENT" = "$DNS_CONTENT" ]; then
        echo "fm-tunnel: [3/6] DNS CNAME already up to date ($HOSTNAME -> $DNS_CONTENT)" >&2
      else
        cf_dns_update "$ZONE_ID" "$DNS_ID" "$HOSTNAME" "$DNS_CONTENT" || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; DNS update failed)" >&2; exit 1; }
        echo "fm-tunnel: [3/6] updated DNS CNAME: $HOSTNAME -> $DNS_CONTENT" >&2
      fi
    else
      DNS_ID=$(cf_dns_create "$ZONE_ID" "$HOSTNAME" "$DNS_CONTENT") || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; DNS create failed)" >&2; exit 1; }
      echo "fm-tunnel: [3/6] created DNS CNAME: $HOSTNAME -> $DNS_CONTENT" >&2
    fi

    APP_ID=$(cf_access_app_find "$HOSTNAME") || { echo "fm-tunnel: aborting after step 3/6 (tunnel+ingress+DNS done; Access NOT done)" >&2; exit 1; }
    APP_NAME="firstmate: $PROJECT"
    if [ -n "$APP_ID" ]; then
      cf_access_app_update "$APP_ID" "$HOSTNAME" "$APP_NAME" || { echo "fm-tunnel: aborting after step 3/6 (tunnel+ingress+DNS done; Access app update failed)" >&2; exit 1; }
      echo "fm-tunnel: [4/6] Access app already exists ($APP_ID), updated" >&2
    else
      APP_ID=$(cf_access_app_create "$HOSTNAME" "$APP_NAME") || { echo "fm-tunnel: aborting after step 3/6 (tunnel+ingress+DNS done; Access app create failed)" >&2; exit 1; }
      echo "fm-tunnel: [4/6] created Access app ($APP_ID)" >&2
    fi
    [ -n "$APP_ID" ] || { echo "fm-tunnel: Cloudflare did not return an Access app id" >&2; exit 1; }

    POLICY_ID=$(cf_access_policy_find "$APP_ID") || { echo "fm-tunnel: aborting after step 4/6 (tunnel+ingress+DNS+Access app done; policy NOT done)" >&2; exit 1; }
    if [ -n "$POLICY_ID" ]; then
      cf_access_policy_update "$APP_ID" "$POLICY_ID" "${TRIMMED_EMAILS[@]}" || { echo "fm-tunnel: aborting after step 4/6 (Access app done; policy update failed)" >&2; exit 1; }
      echo "fm-tunnel: [5/6] Access policy already exists, updated to allow: ${TRIMMED_EMAILS[*]}" >&2
    else
      POLICY_ID=$(cf_access_policy_create "$APP_ID" "${TRIMMED_EMAILS[@]}") || { echo "fm-tunnel: aborting after step 4/6 (Access app done; policy create failed)" >&2; exit 1; }
      echo "fm-tunnel: [5/6] created Access policy allowing: ${TRIMMED_EMAILS[*]}" >&2
    fi
    [ -n "$POLICY_ID" ] || { echo "fm-tunnel: Cloudflare did not return an Access policy id" >&2; exit 1; }

    RUN_TOKEN=$(cf_tunnel_token "$TUNNEL_ID") || { echo "fm-tunnel: aborting after step 5/6 (Cloudflare side fully provisioned; connector NOT started)" >&2; exit 1; }
    if [ -z "$RUN_TOKEN" ]; then
      echo "fm-tunnel: Cloudflare did not return a run-token - aborting after step 5/6 (Cloudflare side fully provisioned; connector NOT started)" >&2
      exit 1
    fi

    fm_tunnel_ensure_cloudflared || { echo "fm-tunnel: aborting after step 5/6 (Cloudflare side fully provisioned; connector NOT started)" >&2; exit 1; }

    TOKEN_FILE=$(fm_tunnel_token_path "$PROJECT")
    mkdir -p "$(dirname "$TOKEN_FILE")" || { echo "fm-tunnel: cannot create $(dirname "$TOKEN_FILE")" >&2; exit 1; }
    ( umask 077; printf '%s' "$RUN_TOKEN" > "$TOKEN_FILE" ) || { echo "fm-tunnel: cannot write token file" >&2; exit 1; }
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true

    fm_tunnel_write_wrapper "$PROJECT" || { echo "fm-tunnel: cannot write connector wrapper script" >&2; exit 1; }
    fm_tunnel_write_plist "$PROJECT" || { echo "fm-tunnel: cannot write LaunchAgent plist" >&2; exit 1; }
    if ! fm_tunnel_launchagent_start "$PROJECT"; then
      echo "fm-tunnel: aborting after step 5/6 (Cloudflare side fully provisioned; connector failed to start - retry with: fm-tunnel.sh up $PROJECT)" >&2
      exit 1
    fi
    echo "fm-tunnel: [6/6] connector LaunchAgent installed and started ($(fm_tunnel_label "$PROJECT"))" >&2

    echo ""
    echo "fm-tunnel: '$PROJECT' is live at https://$HOSTNAME"
    echo "fm-tunnel:   tunnel:     $TUNNEL_NAME ($TUNNEL_ID)"
    echo "fm-tunnel:   DNS:        $HOSTNAME -> $DNS_CONTENT (zone $ZONE)"
    echo "fm-tunnel:   Access app: $APP_NAME ($APP_ID), allowing: ${TRIMMED_EMAILS[*]}"
    echo "fm-tunnel:   connector:  $(fm_tunnel_label "$PROJECT") running $SERVICE"
    ;;

  down)
    TUNNEL_NAME="firstmate-$PROJECT"
    echo "fm-tunnel: tearing down '$PROJECT'" >&2

    # Every lookup and delete records into SURVIVORS on failure. A failed
    # lookup is never silently read as "already gone", so an invalid or
    # under-scoped API token can never report a successful teardown.
    SURVIVORS=()

    fm_tunnel_launchagent_stop "$PROJECT"
    PLIST=$(fm_tunnel_plist_path "$PROJECT")
    rm -f "$PLIST"
    rm -f "$(fm_tunnel_wrapper_path "$PROJECT")"
    echo "fm-tunnel: connector stopped and LaunchAgent removed" >&2

    HOSTNAME=$(fm_tunnel_resolve "$PROJECT" HOSTNAME "" 2>/dev/null || true)
    if [ -n "$HOSTNAME" ]; then
      if APP_ID=$(cf_access_app_find "$HOSTNAME"); then
        if [ -n "$APP_ID" ]; then
          # Deleting the Access app removes its policies with it, so a policy
          # problem only survives when the app delete also fails.
          POLICY_SURVIVOR=""
          if POLICY_ID=$(cf_access_policy_find "$APP_ID"); then
            if [ -n "$POLICY_ID" ]; then
              cf_access_policy_delete "$APP_ID" "$POLICY_ID" || POLICY_SURVIVOR="Access policy $POLICY_ID (delete failed)"
            fi
          else
            POLICY_SURVIVOR="Access policy for app $APP_ID (lookup failed)"
          fi
          if ! cf_access_app_delete "$APP_ID"; then
            SURVIVORS+=("Access app $APP_ID (delete failed)")
            [ -n "$POLICY_SURVIVOR" ] && SURVIVORS+=("$POLICY_SURVIVOR")
          fi
        fi
      else
        SURVIVORS+=("Access app for '$HOSTNAME' (lookup failed)")
      fi

      ZONE=$(fm_tunnel_resolve "$PROJECT" ZONE "" 2>/dev/null || true)
      if [ -n "$ZONE" ]; then
        if ZONE_ID=$(cf_zone_id "$ZONE"); then
          if [ -z "$ZONE_ID" ]; then
            SURVIVORS+=("DNS record for '$HOSTNAME' (zone '$ZONE' not found)")
          elif DNS_ID=$(cf_dns_find "$ZONE_ID" "$HOSTNAME"); then
            if [ -n "$DNS_ID" ]; then
              cf_dns_delete "$ZONE_ID" "$DNS_ID" || SURVIVORS+=("DNS record $DNS_ID (delete failed)")
            fi
          else
            SURVIVORS+=("DNS record for '$HOSTNAME' (lookup failed)")
          fi
        else
          SURVIVORS+=("DNS record for '$HOSTNAME' (zone lookup failed)")
        fi
      else
        SURVIVORS+=("DNS record for '$HOSTNAME' (no zone configured to look it up in)")
      fi
    else
      SURVIVORS+=("Access app and DNS record (no hostname configured to look them up by)")
    fi

    if TUNNEL_ID=$(cf_tunnel_find "$TUNNEL_NAME"); then
      if [ -n "$TUNNEL_ID" ]; then
        cf_tunnel_delete "$TUNNEL_ID" || SURVIVORS+=("tunnel $TUNNEL_ID (delete failed; an active connection may still be draining - retry shortly)")
      fi
    else
      SURVIVORS+=("tunnel '$TUNNEL_NAME' (lookup failed)")
    fi

    rm -f "$(fm_tunnel_token_path "$PROJECT")"

    if [ "${#SURVIVORS[@]}" -gt 0 ]; then
      echo "fm-tunnel: '$PROJECT' was NOT fully torn down - the local connector is stopped, but these may still be live:" >&2
      for s in "${SURVIVORS[@]}"; do
        echo "fm-tunnel:   - $s" >&2
      done
      echo "fm-tunnel: fix the cause above and re-run: fm-tunnel.sh down $PROJECT" >&2
      exit 1
    fi
    echo "fm-tunnel: '$PROJECT' torn down" >&2
    ;;

  status)
    TUNNEL_NAME="firstmate-$PROJECT"
    HOSTNAME=$(fm_tunnel_resolve "$PROJECT" HOSTNAME "" 2>/dev/null || true)
    # A failed lookup is reported as such: "not found" is reserved for a
    # Cloudflare query that actually succeeded and returned nothing, so status
    # stays trustworthy as a provisioning/teardown check.
    LOOKUP_FAILED=0

    if TUNNEL_ID=$(cf_tunnel_find "$TUNNEL_NAME"); then
      if [ -n "$TUNNEL_ID" ]; then
        echo "tunnel:      $TUNNEL_NAME ($TUNNEL_ID)"
      else
        echo "tunnel:      not found"
      fi
    else
      LOOKUP_FAILED=1
      echo "tunnel:      lookup failed (see error above)"
    fi

    if [ -n "$HOSTNAME" ]; then
      ZONE=$(fm_tunnel_resolve "$PROJECT" ZONE "" 2>/dev/null || true)
      if [ -n "$ZONE" ]; then
        if ZONE_ID=$(cf_zone_id "$ZONE"); then
          if [ -z "$ZONE_ID" ]; then
            echo "dns:         zone '$ZONE' not found"
          elif DNS_ID=$(cf_dns_find "$ZONE_ID" "$HOSTNAME"); then
            if [ -n "$DNS_ID" ]; then
              if CONTENT=$(cf_dns_current_content "$ZONE_ID" "$DNS_ID"); then
                echo "dns:         $HOSTNAME -> $CONTENT"
              else
                LOOKUP_FAILED=1
                echo "dns:         $HOSTNAME -> read failed (see error above)"
              fi
            else
              echo "dns:         not found"
            fi
          else
            LOOKUP_FAILED=1
            echo "dns:         lookup failed (see error above)"
          fi
        else
          LOOKUP_FAILED=1
          echo "dns:         zone lookup failed (see error above)"
        fi
      else
        echo "dns:         zone unknown (no --zone / FM_TUNNEL_*_ZONE configured)"
      fi

      if APP_ID=$(cf_access_app_find "$HOSTNAME"); then
        if [ -z "$APP_ID" ]; then
          echo "access app:  not found"
        elif POLICY_ID=$(cf_access_policy_find "$APP_ID"); then
          if [ -n "$POLICY_ID" ]; then
            echo "access app:  $HOSTNAME ($APP_ID), policy configured"
          else
            echo "access app:  $HOSTNAME ($APP_ID), no policy"
          fi
        else
          LOOKUP_FAILED=1
          echo "access app:  $HOSTNAME ($APP_ID), policy lookup failed (see error above)"
        fi
      else
        LOOKUP_FAILED=1
        echo "access app:  lookup failed (see error above)"
      fi
    else
      echo "hostname:    not configured (no --hostname / FM_TUNNEL_*_HOSTNAME) - skipping DNS/Access status"
    fi

    if [ -f "$(fm_tunnel_plist_path "$PROJECT")" ]; then
      if fm_tunnel_launchagent_alive "$PROJECT"; then
        echo "connector:   LaunchAgent loaded and running ($(fm_tunnel_label "$PROJECT"))"
      else
        echo "connector:   LaunchAgent installed but not running ($(fm_tunnel_label "$PROJECT"))"
      fi
    else
      echo "connector:   not installed"
    fi

    [ "$LOOKUP_FAILED" -eq 0 ] || exit 1
    ;;
esac
