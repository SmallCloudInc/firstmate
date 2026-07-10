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
# what to set. Those four flags are only valid for `up`; `down` and `status`
# always act on the configured settings.
#
# $FM_HOME/config/cloudflare.env (gitignored) also carries the account-wide
# CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. See AGENTS.md for the
# required token scopes and a documented example file.
#
# `up` is idempotent: every Cloudflare resource is found-by-name/hostname
# before it is created, so re-running never duplicates a tunnel, DNS record,
# Access app, or Access policy - existing ones are updated in place instead.
# It provisions the tunnel and ingress, then reads any DNS record already at the
# hostname to confirm the hostname is fm-tunnel's to claim, then the Access app
# and its allow-policy, and only then the DNS CNAME: nothing is ever created
# against a hostname held by an unrelated record, and a public route into the
# tunnel never exists before the login gate that fronts it. A firstmate-owned
# DNS record is rewritten on every run rather than skipped when its target
# already matches, so a record whose proxied flag was flipped off - which
# bypasses Access entirely - is self-healed.
# Every resource fm-tunnel creates carries an ownership marker (the DNS record's
# comment, the Access app's name), and neither `up` nor `down` will update or
# delete a pre-existing record found at the hostname that lacks this project's
# marker - so a typo'd hostname cannot clobber unrelated production resources.
# The local connector is a firstmate-owned macOS LaunchAgent
# (com.firstmate.tunnel.<project>) that execs `cloudflared tunnel run` with the
# run-token passed through the TUNNEL_TOKEN environment variable, so it never
# appears in the process argv; nothing is ever written into projects/. The
# token is stored gitignored at $FM_HOME/config/tunnel-<project>.token (0600)
# and is never printed to stdout/stderr/logs.
#
# `down` stops the connector, then deletes the DNS record, the Access policy
# and its Access app, and the tunnel (in that order: the public route goes
# first, so a partial failure can never leave the hostname resolvable with its
# login gate already removed). If an fm-tunnel-owned DNS record may still be
# live - a record read failure, a zone or record lookup failure, or a failed
# delete - the Access app and its policy are deliberately left alive and
# reported as survivors rather than deleted out from under a still-resolvable
# hostname. A record that is not fm-tunnel's, a zone that does not exist, or no
# configured zone at all (`up` cannot create a record without one) routes nothing
# to this tunnel, so fm-tunnel's own Access app is still removed in those cases
# (the foreign or unverifiable record is reported untouched). It removes the
# local token file too. Safe to run on a partially-provisioned or already-torn-
# down project. It exits non-zero, with a summary of what survived, if any
# lookup or delete failed - so a bad API token never reads as a successful
# teardown.
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
up_only() {
  [ "$CMD" = up ] || { echo "fm-tunnel: $1 is only valid for 'up'" >&2; exit 2; }
}
while [ $# -gt 0 ]; do
  case "$1" in
    --hostname)
      up_only "$1"
      [ $# -ge 2 ] || { echo "fm-tunnel: --hostname requires a value" >&2; exit 2; }
      CLI_HOSTNAME=$2; shift 2 ;;
    --zone)
      up_only "$1"
      [ $# -ge 2 ] || { echo "fm-tunnel: --zone requires a value" >&2; exit 2; }
      CLI_ZONE=$2; shift 2 ;;
    --service)
      up_only "$1"
      [ $# -ge 2 ] || { echo "fm-tunnel: --service requires a value" >&2; exit 2; }
      CLI_SERVICE=$2; shift 2 ;;
    --emails)
      up_only "$1"
      [ $# -ge 2 ] || { echo "fm-tunnel: --emails requires a value" >&2; exit 2; }
      CLI_EMAILS=$2; shift 2 ;;
    --install-cloudflared)
      up_only "$1"
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

# `up` needs the local connector toolchain too. Check it (and run the opt-in
# Homebrew install) before the first Cloudflare request, so a host without
# cloudflared fails with zero cloud resources created rather than after five.
if [ "$CMD" = up ]; then
  command -v launchctl >/dev/null 2>&1 || {
    echo "fm-tunnel: launchctl not found on PATH (required to run the connector)" >&2
    exit 1
  }
  fm_tunnel_ensure_cloudflared || exit 1
fi

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
      TUNNEL_ID=$(cf_tunnel_create "$TUNNEL_NAME") || {
        echo "fm-tunnel: aborting after step 1/6 (a tunnel named '$TUNNEL_NAME' may have been created; run 'fm-tunnel.sh down $PROJECT' to clean up)" >&2
        exit 1
      }
      echo "fm-tunnel: [1/6] created tunnel '$TUNNEL_NAME' ($TUNNEL_ID)" >&2
    fi
    [ -n "$TUNNEL_ID" ] || {
      echo "fm-tunnel: Cloudflare did not return a tunnel id - a tunnel named '$TUNNEL_NAME' may exist; run 'fm-tunnel.sh down $PROJECT' to clean up" >&2
      exit 1
    }

    if ! cf_tunnel_set_ingress "$TUNNEL_ID" "$HOSTNAME" "$SERVICE"; then
      echo "fm-tunnel: aborting after step 1/6 (tunnel '$TUNNEL_NAME' / $TUNNEL_ID exists; ingress NOT set)" >&2
      exit 1
    fi
    echo "fm-tunnel: [2/6] ingress set: $HOSTNAME -> $SERVICE" >&2

    # Claim the hostname before creating anything against it. These lookups are
    # read-only and type-agnostic, so any unrelated record already sitting at the
    # hostname aborts here - before an Access app would have put a login gate in
    # front of it. Cloudflare Access gates a domain whatever its record type, so
    # checking only for a CNAME would leave a live A record unguarded.
    DNS_CONTENT="$TUNNEL_ID.cfargotunnel.com"
    DNS_COMMENT=$(fm_tunnel_dns_comment "$PROJECT")
    ZONE_ID=$(cf_zone_id "$ZONE") || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; Access+DNS NOT done, nothing touched at '$HOSTNAME')" >&2; exit 1; }
    if [ -z "$ZONE_ID" ]; then
      echo "fm-tunnel: zone '$ZONE' not found on this account - aborting after step 2/6 (tunnel+ingress done; Access+DNS NOT done, nothing touched at '$HOSTNAME')" >&2
      exit 1
    fi
    DNS_ID=$(cf_dns_find "$ZONE_ID" "$HOSTNAME") || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; Access+DNS NOT done, nothing touched at '$HOSTNAME')" >&2; exit 1; }
    if [ -n "$DNS_ID" ]; then
      CURRENT_RECORD=$(cf_dns_current_record "$ZONE_ID" "$DNS_ID") || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; DNS record found but unreadable; Access+DNS NOT done, nothing touched at '$HOSTNAME')" >&2; exit 1; }
      CURRENT_CONTENT=${CURRENT_RECORD%%$'\t'*}
      CURRENT_COMMENT=${CURRENT_RECORD#*$'\t'}
      if [ "$CURRENT_COMMENT" != "$DNS_COMMENT" ]; then
        echo "fm-tunnel: refusing to touch the existing DNS record at '$HOSTNAME' -> $CURRENT_CONTENT" >&2
        echo "fm-tunnel: it is not managed by fm-tunnel for project '$PROJECT' (expected comment: $DNS_COMMENT)" >&2
        echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; DNS record and Access app left untouched)" >&2
        exit 1
      fi
    fi

    # The Access gate is provisioned before the DNS record is written: a public
    # route into the tunnel must never exist before the login gate that fronts
    # it. An Access app with no DNS record pointing at it is harmless.
    APP_ID=$(cf_access_app_find "$HOSTNAME") || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; Access/DNS NOT done)" >&2; exit 1; }
    APP_NAME=$(fm_tunnel_app_name "$PROJECT")
    if [ -n "$APP_ID" ]; then
      CURRENT_APP_NAME=$(cf_access_app_current_name "$APP_ID") || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; Access app found but unreadable; DNS NOT done)" >&2; exit 1; }
      if [ "$CURRENT_APP_NAME" != "$APP_NAME" ]; then
        echo "fm-tunnel: refusing to touch the existing Access app on '$HOSTNAME' named '$CURRENT_APP_NAME'" >&2
        echo "fm-tunnel: it is not managed by fm-tunnel for project '$PROJECT' (expected name: $APP_NAME)" >&2
        echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; Access app left untouched; DNS NOT done)" >&2
        exit 1
      fi
      cf_access_app_update "$APP_ID" "$HOSTNAME" "$APP_NAME" || { echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; Access app update failed; DNS NOT done)" >&2; exit 1; }
      echo "fm-tunnel: [3/6] Access app already exists ($APP_ID), updated" >&2
    else
      APP_ID=$(cf_access_app_create "$HOSTNAME" "$APP_NAME") || {
        echo "fm-tunnel: aborting after step 2/6 (tunnel+ingress done; an Access app named '$APP_NAME' may have been created; DNS NOT done; run 'fm-tunnel.sh down $PROJECT' to clean up)" >&2
        exit 1
      }
      echo "fm-tunnel: [3/6] created Access app ($APP_ID)" >&2
    fi
    [ -n "$APP_ID" ] || {
      echo "fm-tunnel: Cloudflare did not return an Access app id - an Access app named '$APP_NAME' may exist; run 'fm-tunnel.sh down $PROJECT' to clean up" >&2
      exit 1
    }

    POLICY_ID=$(cf_access_policy_find "$APP_ID") || { echo "fm-tunnel: aborting after step 3/6 (tunnel+ingress+Access app done; policy and DNS NOT done)" >&2; exit 1; }
    if [ -n "$POLICY_ID" ]; then
      cf_access_policy_update "$APP_ID" "$POLICY_ID" "${TRIMMED_EMAILS[@]}" || { echo "fm-tunnel: aborting after step 3/6 (Access app done; policy update failed; DNS NOT done)" >&2; exit 1; }
      echo "fm-tunnel: [4/6] Access policy already exists, updated to allow: ${TRIMMED_EMAILS[*]}" >&2
    else
      POLICY_ID=$(cf_access_policy_create "$APP_ID" "${TRIMMED_EMAILS[@]}") || {
        echo "fm-tunnel: aborting after step 3/6 (Access app done; an Access policy may have been created on app $APP_ID; DNS NOT done; run 'fm-tunnel.sh down $PROJECT' to clean up)" >&2
        exit 1
      }
      echo "fm-tunnel: [4/6] created Access policy allowing: ${TRIMMED_EMAILS[*]}" >&2
    fi
    [ -n "$POLICY_ID" ] || {
      echo "fm-tunnel: Cloudflare did not return an Access policy id - a policy may exist on app $APP_ID; run 'fm-tunnel.sh down $PROJECT' to clean up" >&2
      exit 1
    }

    if [ -n "$DNS_ID" ]; then
      # Always rewrite: the marker proves ownership, and content is not the only
      # field that matters - a record whose proxied flag was flipped off bypasses
      # Access entirely, so every `up` re-run restates the full desired record.
      cf_dns_update "$ZONE_ID" "$DNS_ID" "$HOSTNAME" "$DNS_CONTENT" "$DNS_COMMENT" || { echo "fm-tunnel: aborting after step 4/6 (tunnel+ingress+Access done; DNS update failed)" >&2; exit 1; }
      echo "fm-tunnel: [5/6] DNS CNAME up to date: $HOSTNAME -> $DNS_CONTENT" >&2
    else
      DNS_ID=$(cf_dns_create "$ZONE_ID" "$HOSTNAME" "$DNS_CONTENT" "$DNS_COMMENT") || {
        echo "fm-tunnel: aborting after step 4/6 (tunnel+ingress+Access done; a CNAME at '$HOSTNAME' may have been created; run 'fm-tunnel.sh down $PROJECT' to clean up)" >&2
        exit 1
      }
      echo "fm-tunnel: [5/6] created DNS CNAME: $HOSTNAME -> $DNS_CONTENT" >&2
    fi
    [ -n "$DNS_ID" ] || {
      echo "fm-tunnel: Cloudflare did not return a DNS record id - a CNAME at '$HOSTNAME' may exist; run 'fm-tunnel.sh down $PROJECT' to clean up" >&2
      exit 1
    }

    RUN_TOKEN=$(cf_tunnel_token "$TUNNEL_ID") || { echo "fm-tunnel: aborting after step 5/6 (Cloudflare side fully provisioned; connector NOT started)" >&2; exit 1; }
    if [ -z "$RUN_TOKEN" ]; then
      echo "fm-tunnel: Cloudflare did not return a run-token - aborting after step 5/6 (Cloudflare side fully provisioned; connector NOT started)" >&2
      exit 1
    fi

    if fm_tunnel_connector_unchanged "$PROJECT" "$RUN_TOKEN"; then
      echo "fm-tunnel: [6/6] connector already running unchanged ($(fm_tunnel_label "$PROJECT"))" >&2
    else
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
      CONNECTOR_UP=0
      for _ in 1 2 3 4; do
        if fm_tunnel_launchagent_alive "$PROJECT"; then CONNECTOR_UP=1; break; fi
        sleep 0.5
      done
      if [ "$CONNECTOR_UP" -eq 0 ]; then
        echo "fm-tunnel: connector did not stay up - see $(fm_tunnel_log_path "$PROJECT" err)" >&2
        echo "fm-tunnel: the LaunchAgent $(fm_tunnel_label "$PROJECT") IS loaded and launchd keeps respawning it in the background; run 'fm-tunnel.sh down $PROJECT' to stop it" >&2
        echo "fm-tunnel: aborting after step 5/6 (Cloudflare side fully provisioned; connector not running)" >&2
        exit 1
      fi
      echo "fm-tunnel: [6/6] connector LaunchAgent installed and started ($(fm_tunnel_label "$PROJECT"))" >&2
    fi

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
    CONNECTOR_STOPPED=1

    fm_tunnel_launchagent_stop "$PROJECT"
    PLIST=$(fm_tunnel_plist_path "$PROJECT")
    if fm_tunnel_launchagent_loaded "$PROJECT"; then
      # The plist and wrapper are kept so a later `down` retry can unload the
      # job by path and the operator can inspect exactly what is still loaded.
      CONNECTOR_STOPPED=0
      SURVIVORS+=("connector $(fm_tunnel_label "$PROJECT") (still loaded; LaunchAgent could not be unloaded)")
      echo "fm-tunnel: connector could NOT be stopped - LaunchAgent left in place" >&2
    else
      rm -f "$PLIST"
      rm -f "$(fm_tunnel_wrapper_path "$PROJECT")"
      echo "fm-tunnel: connector stopped and LaunchAgent removed" >&2
    fi

    APP_NAME=$(fm_tunnel_app_name "$PROJECT")
    DNS_COMMENT=$(fm_tunnel_dns_comment "$PROJECT")
    HOSTNAME=$(fm_tunnel_resolve "$PROJECT" HOSTNAME "" 2>/dev/null || true)
    if [ -n "$HOSTNAME" ]; then
      # The DNS record goes first: it is the public route. The Access gate is
      # only removed once no fm-tunnel-owned route into this tunnel can still be
      # live, so no partial failure can leave the service reachable with its
      # login gate already deleted. A record that is not ours - or a zone that
      # does not exist - routes nothing here, so it never holds the gate hostage.
      OUR_ROUTE_MAY_BE_LIVE=1
      ZONE=$(fm_tunnel_resolve "$PROJECT" ZONE "" 2>/dev/null || true)
      if [ -n "$ZONE" ]; then
        if ZONE_ID=$(cf_zone_id "$ZONE"); then
          if [ -z "$ZONE_ID" ]; then
            OUR_ROUTE_MAY_BE_LIVE=0
            SURVIVORS+=("DNS record for '$HOSTNAME' (zone '$ZONE' not found)")
          elif DNS_ID=$(cf_dns_find "$ZONE_ID" "$HOSTNAME"); then
            if [ -z "$DNS_ID" ]; then
              OUR_ROUTE_MAY_BE_LIVE=0
            elif ! CURRENT_RECORD=$(cf_dns_current_record "$ZONE_ID" "$DNS_ID"); then
              SURVIVORS+=("DNS record $DNS_ID (read failed; left untouched)")
            else
              CURRENT_COMMENT=${CURRENT_RECORD#*$'\t'}
              if [ "$CURRENT_COMMENT" != "$DNS_COMMENT" ]; then
                OUR_ROUTE_MAY_BE_LIVE=0
                SURVIVORS+=("DNS record $DNS_ID for '$HOSTNAME' (not managed by fm-tunnel for '$PROJECT'; left untouched)")
              elif cf_dns_delete "$ZONE_ID" "$DNS_ID"; then
                OUR_ROUTE_MAY_BE_LIVE=0
              else
                SURVIVORS+=("DNS record $DNS_ID (delete failed)")
              fi
            fi
          else
            SURVIVORS+=("DNS record for '$HOSTNAME' (lookup failed)")
          fi
        else
          SURVIVORS+=("DNS record for '$HOSTNAME' (zone lookup failed)")
        fi
      else
        # `up` hard-requires a zone to create a record, so without one fm-tunnel
        # never routed this hostname and has no route to protect: the gate can go.
        OUR_ROUTE_MAY_BE_LIVE=0
        SURVIVORS+=("DNS record for '$HOSTNAME' (no zone configured to look it up in; state unconfirmed)")
      fi

      if [ "$OUR_ROUTE_MAY_BE_LIVE" -eq 1 ]; then
        SURVIVORS+=("Access app for '$HOSTNAME' (left in place on purpose: the DNS record above may still route to this tunnel, and removing its login gate would expose the service)")
      elif APP_ID=$(cf_access_app_find "$HOSTNAME"); then
        if [ -n "$APP_ID" ]; then
          if ! CURRENT_APP_NAME=$(cf_access_app_current_name "$APP_ID"); then
            SURVIVORS+=("Access app $APP_ID (read failed; left untouched)")
          elif [ "$CURRENT_APP_NAME" != "$APP_NAME" ]; then
            SURVIVORS+=("Access app $APP_ID named '$CURRENT_APP_NAME' (not managed by fm-tunnel for '$PROJECT'; left untouched)")
          else
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
        fi
      else
        SURVIVORS+=("Access app for '$HOSTNAME' (lookup failed)")
      fi
    else
      SURVIVORS+=("DNS record and Access app (no hostname configured to look them up by)")
    fi

    if TUNNEL_ID=$(cf_tunnel_find "$TUNNEL_NAME"); then
      if [ -n "$TUNNEL_ID" ]; then
        cf_tunnel_delete "$TUNNEL_ID" || SURVIVORS+=("tunnel $TUNNEL_ID (delete failed; an active connection may still be draining - retry shortly)")
      fi
    else
      SURVIVORS+=("tunnel '$TUNNEL_NAME' (lookup failed)")
    fi

    # A still-running connector needs its token file; removing it would only
    # break the restart the operator has to perform anyway.
    [ "$CONNECTOR_STOPPED" -eq 1 ] && rm -f "$(fm_tunnel_token_path "$PROJECT")"

    if [ "${#SURVIVORS[@]}" -gt 0 ]; then
      echo "fm-tunnel: '$PROJECT' was NOT fully torn down - these may still be live:" >&2
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
            LOOKUP_FAILED=1
            echo "dns:         zone '$ZONE' not found"
          elif DNS_ID=$(cf_dns_find "$ZONE_ID" "$HOSTNAME"); then
            if [ -n "$DNS_ID" ]; then
              if RECORD=$(cf_dns_current_record "$ZONE_ID" "$DNS_ID"); then
                echo "dns:         $HOSTNAME -> ${RECORD%%$'\t'*}"
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
        LOOKUP_FAILED=1
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

    if fm_tunnel_launchagent_loaded "$PROJECT"; then
      if fm_tunnel_launchagent_alive "$PROJECT"; then
        echo "connector:   LaunchAgent loaded and running ($(fm_tunnel_label "$PROJECT"))"
      else
        echo "connector:   LaunchAgent loaded but not running ($(fm_tunnel_label "$PROJECT"))"
      fi
    else
      echo "connector:   not loaded"
    fi

    [ "$LOOKUP_FAILED" -eq 0 ] || exit 1
    ;;
esac
