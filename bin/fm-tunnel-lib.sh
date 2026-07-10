#!/usr/bin/env bash
# fm-tunnel-lib.sh - shared helpers for fm-tunnel.sh: Cloudflare API client,
# config resolution, and the resource-level find/create/update primitives for
# a remotely-managed ("token-run") Cloudflare Tunnel behind Cloudflare Access.
#
# This file is sourced, never executed. It never prints CLOUDFLARE_API_TOKEN or
# a tunnel run-token to stdout/stderr/logs. JSON is built and parsed with
# python3 (argv-passed values only, never interpolated into python source) so
# hostnames/emails/tokens with shell-special characters stay safe.
#
# Callers must set FM_HOME before sourcing fm_tunnel_load_config, and must have
# curl and python3 on PATH (checked by fm-tunnel.sh's own preflight).
set -u

CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

# --- temp file bookkeeping ---------------------------------------------------

# Every temp file lives in one per-run directory, created here with `mktemp -d`
# so it is unpredictable and atomically owned by the caller at mode 0700 - an
# attacker cannot pre-create it. A command-substitution subshell cannot register
# a file with its parent, so bookkeeping must not depend on shared shell state:
# subshells inherit CF_TMPDIR, and the top-level trap removes the whole tree on
# exit or signal.
if ! CF_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-tunnel.XXXXXX" 2>/dev/null); then
  echo "fm-tunnel: cannot create a private temp directory" >&2
  CF_TMPDIR=""
fi

cf_mktemp() {
  [ -n "$CF_TMPDIR" ] && [ -d "$CF_TMPDIR" ] || return 1
  mktemp "$CF_TMPDIR/f.XXXXXX"
}

cf_cleanup_tmp() {
  if [ -n "${CF_TMPDIR:-}" ]; then
    rm -rf "$CF_TMPDIR"
  fi
}

# --- config resolution --------------------------------------------------------

# fm_tunnel_env_get <key> <file>: read the last KEY=VALUE assignment from a
# .env-style file (tolerates "export ", surrounding whitespace, one layer of
# quoting, and a trailing ` # comment` on an unquoted value, exactly as a
# shell-sourced .env would). Prints nothing (and succeeds) when the file or key
# is absent.
fm_tunnel_env_get() {
  local key=$1 file=$2 line val rest
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}
  case "$val" in
    \"*)
      rest=${val#\"}
      case "$rest" in *\"*) val=${rest%%\"*} ;; *) val=$rest ;; esac
      ;;
    \'*)
      rest=${val#\'}
      case "$rest" in *\'*) val=${rest%%\'*} ;; *) val=$rest ;; esac
      ;;
    *)
      case "$val" in
        *[[:space:]]\#*) val=${val%%[[:space:]]\#*} ;;
      esac
      val=${val%"${val##*[![:space:]]}"}
      ;;
  esac
  printf '%s' "$val"
}

# fm_tunnel_project_var <project> <suffix>: normalize a project id into the
# FM_TUNNEL_<PROJECT>_<SUFFIX> config-file key, e.g. "house-hunter" HOSTNAME ->
# FM_TUNNEL_HOUSE_HUNTER_HOSTNAME.
fm_tunnel_project_var() {
  local project=$1 suffix=$2 norm
  norm=$(printf '%s' "$project" | tr '[:lower:]' '[:upper:]' | LC_ALL=C sed -E 's/[^A-Z0-9]/_/g')
  printf 'FM_TUNNEL_%s_%s' "$norm" "$suffix"
}

# fm_tunnel_load_config: read CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID from
# $FM_HOME/config/cloudflare.env into CF_TOKEN / CF_ACCOUNT_ID. A non-empty
# process environment variable wins over the file, matching fm_tunnel_resolve.
# An exported-but-empty variable falls through to the file. Prints nothing;
# callers check whether CF_TOKEN/CF_ACCOUNT_ID ended up non-empty.
fm_tunnel_load_config() {
  local env_file="${FM_TUNNEL_CONFIG_FILE:-$FM_HOME/config/cloudflare.env}"
  FM_TUNNEL_CONFIG_FILE_RESOLVED=$env_file
  if [ -n "${CLOUDFLARE_API_TOKEN-}" ]; then
    CF_TOKEN=$CLOUDFLARE_API_TOKEN
  else
    CF_TOKEN=$(fm_tunnel_env_get CLOUDFLARE_API_TOKEN "$env_file")
  fi
  if [ -n "${CLOUDFLARE_ACCOUNT_ID-}" ]; then
    CF_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID
  else
    CF_ACCOUNT_ID=$(fm_tunnel_env_get CLOUDFLARE_ACCOUNT_ID "$env_file")
  fi
}

# fm_tunnel_resolve <project> <suffix> <cli-value>: resolve one project setting
# (hostname/zone/service/emails) by precedence: explicit CLI flag > real
# process env var of the same FM_TUNNEL_<PROJECT>_<SUFFIX> name > the config
# file. Prints the resolved value, or nothing when unresolved.
fm_tunnel_resolve() {
  local project=$1 suffix=$2 cli_value=$3 varname
  if [ -n "$cli_value" ]; then
    printf '%s' "$cli_value"
    return 0
  fi
  varname=$(fm_tunnel_project_var "$project" "$suffix")
  local envval
  envval=$(eval "printf '%s' \"\${$varname-}\"")
  if [ -n "$envval" ]; then
    printf '%s' "$envval"
    return 0
  fi
  fm_tunnel_env_get "$varname" "$FM_TUNNEL_CONFIG_FILE_RESOLVED"
}

# --- Cloudflare API client -----------------------------------------------------

# cf_auth_header_file: write "Authorization: Bearer <token>" to a 0600 temp
# file so the token never appears in curl's argv (visible via ps/history).
cf_auth_header_file() {
  local file
  case "$CF_TOKEN" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  file=$(cf_mktemp) || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: Bearer %s\n' "$CF_TOKEN" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

cf_urlencode() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# cf_request <METHOD> <path-and-query> [json-body]: call the Cloudflare API.
# Sets CF_HTTP_CODE (string) and CF_BODY (the raw JSON response). The response
# never touches disk, so a run-token in a body cannot outlive the process even
# if it is killed mid-request. Returns non-zero only on a transport failure
# (curl missing, network error); HTTP error codes are still captured in
# CF_HTTP_CODE for the caller to check with cf_check_ok.
cf_request() {
  local method=$1 path=$2 body=${3:-}
  command -v curl >/dev/null 2>&1 || { echo "fm-tunnel: curl not found" >&2; return 1; }
  local auth_file resp rc
  auth_file=$(cf_auth_header_file) || { echo "fm-tunnel: cannot prepare auth header" >&2; return 1; }
  if [ -n "$body" ]; then
    resp=$(printf '%s' "$body" | curl -sS -m 20 -w '\n%{http_code}' -X "$method" \
      -H "@$auth_file" -H 'Content-Type: application/json' \
      --data-binary @- "${CF_API_BASE}${path}")
    rc=$?
  else
    resp=$(curl -sS -m 20 -w '\n%{http_code}' -X "$method" \
      -H "@$auth_file" -H 'Content-Type: application/json' \
      "${CF_API_BASE}${path}")
    rc=$?
  fi
  rm -f "$auth_file"
  if [ "$rc" -ne 0 ]; then
    echo "fm-tunnel: request to Cloudflare API failed (network error)" >&2
    return 1
  fi
  CF_HTTP_CODE=${resp##*$'\n'}
  CF_BODY=${resp%$'\n'*}
  return 0
}

# cf_error_message: join Cloudflare's "errors[].message" entries from CF_BODY
# into one string, or print nothing if the body has no errors array.
cf_error_message() {
  printf '%s' "${CF_BODY:-}" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
errs = d.get("errors") if isinstance(d, dict) else None
if errs:
    msgs = [str(e.get("message", e)) if isinstance(e, dict) else str(e) for e in errs]
    print("; ".join(msgs))
' 2>/dev/null
}

# cf_check_ok <context-label>: verify the last cf_request succeeded (2xx).
# Prints an actionable error (including Cloudflare's own message) on failure.
cf_check_ok() {
  case "$CF_HTTP_CODE" in
    2[0-9][0-9]) return 0 ;;
    *)
      local msg
      msg=$(cf_error_message)
      echo "fm-tunnel: $1 failed (HTTP ${CF_HTTP_CODE:-?})${msg:+: $msg}" >&2
      return 1
      ;;
  esac
}

cf_extract() {
  # cf_extract <python-expr-of-loaded-json-'d'>, reading the body from CF_BODY
  local expr=$1
  printf '%s' "${CF_BODY:-}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
expr = sys.argv[1]
result = eval(expr, {"__builtins__": {}}, {"d": d})
if result is None:
    pass
elif isinstance(result, (dict, list)):
    print(json.dumps(result))
else:
    print(result)
' "$expr" 2>/dev/null
}

# --- request body builders (argv-only, never interpolated into python source) -

cf_body_tunnel_create() {
  python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "config_src": "cloudflare"}))' "$1"
}

cf_body_tunnel_ingress() {
  python3 -c '
import json, sys
hostname, service = sys.argv[1], sys.argv[2]
cfg = {"ingress": [{"hostname": hostname, "service": service}, {"service": "http_status:404"}]}
print(json.dumps({"config": cfg}))
' "$1" "$2"
}

cf_body_dns_record() {
  python3 -c '
import json, sys
hostname, content, comment = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({"name": hostname, "type": "CNAME", "content": content, "proxied": True, "ttl": 1, "comment": comment}))
' "$1" "$2" "$3"
}

cf_body_access_app() {
  python3 -c '
import json, sys
hostname, name = sys.argv[1], sys.argv[2]
print(json.dumps({"type": "self_hosted", "domain": hostname, "name": name, "session_duration": "24h"}))
' "$1" "$2"
}

# cf_body_access_policy <name> <email> [<email> ...]
cf_body_access_policy() {
  local name=$1
  shift
  python3 -c '
import json, sys
name = sys.argv[1]
emails = sys.argv[2:]
include = [{"email": {"email": e}} for e in emails]
print(json.dumps({"name": name, "decision": "allow", "include": include, "precedence": 1}))
' "$name" "$@"
}

# --- resource-level find/create/update helpers ---------------------------------

FM_TUNNEL_ACCESS_POLICY_NAME="firstmate-tunnel-access"

# Ownership markers. Every resource fm-tunnel creates carries one, and no
# pre-existing resource found by hostname is ever updated or deleted unless it
# carries this project's marker - so a typo'd hostname cannot clobber an
# unrelated production DNS record or Access app.
fm_tunnel_dns_comment() {
  printf 'managed by firstmate fm-tunnel: %s' "$1"
}

fm_tunnel_app_name() {
  printf 'firstmate: %s' "$1"
}

# cf_tunnel_find <name>: print the id of a non-deleted tunnel with an exact
# name match, or nothing if none exists.
cf_tunnel_find() {
  local name=$1 enc
  enc=$(cf_urlencode "$name")
  cf_request GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?name=$enc&is_deleted=false" || return 2
  cf_check_ok "list tunnels" || return 1
  printf '%s' "$CF_BODY" | python3 -c '
import json, sys
d = json.load(sys.stdin)
name = sys.argv[1]
for t in (d.get("result") or []):
    if t.get("name") == name and not t.get("deleted_at"):
        print(t.get("id",""))
        break
' "$name"
}

# cf_tunnel_create <name>: create a remotely-managed tunnel, print its id.
cf_tunnel_create() {
  local name=$1 body
  body=$(cf_body_tunnel_create "$name")
  cf_request POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" "$body" || return 2
  cf_check_ok "create tunnel '$name'" || return 1
  cf_extract 'd.get("result",{}).get("id","")'
}

# cf_tunnel_set_ingress <tunnel_id> <hostname> <service>: set the tunnel's
# remote ingress config (idempotent: PUT always sets the full config).
cf_tunnel_set_ingress() {
  local id=$1 hostname=$2 service=$3 body
  body=$(cf_body_tunnel_ingress "$hostname" "$service")
  cf_request PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$id/configurations" "$body" || return 2
  cf_check_ok "set ingress for tunnel $id"
}

# cf_tunnel_token <tunnel_id>: print the connector run-token (never log this).
cf_tunnel_token() {
  local id=$1
  cf_request GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$id/token" || return 2
  cf_check_ok "fetch run-token for tunnel $id" || return 1
  cf_extract 'd.get("result","")'
}

# cf_tunnel_delete <tunnel_id>
cf_tunnel_delete() {
  local id=$1
  cf_request DELETE "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$id" || return 2
  cf_check_ok "delete tunnel $id"
}

# cf_zone_id <zone-name>: print the zone id, or nothing if not found.
cf_zone_id() {
  local zone=$1 enc
  enc=$(cf_urlencode "$zone")
  cf_request GET "/zones?name=$enc" || return 2
  cf_check_ok "look up zone '$zone'" || return 1
  cf_extract '(d.get("result") or [{}])[0].get("id","") if d.get("result") else ""'
}

# cf_dns_find <zone_id> <hostname>: print the id of the routing record at the
# hostname - CNAME (what fm-tunnel creates) or A/AAAA (which Cloudflare refuses
# to let coexist with a routing CNAME) - or nothing. Callers use this to decide
# whether the hostname is theirs to claim, so an A/AAAA record must be seen: it
# holds the hostname just as firmly as a CNAME, and Access gates a domain
# whatever its record type. Non-routing records (TXT, MX, CAA, ...) legitimately
# coexist with fm-tunnel's CNAME and are ignored, so one of them can never be
# mistaken for a foreign record sitting at an fm-tunnel-owned hostname.
cf_dns_find() {
  local zone_id=$1 hostname=$2 enc
  enc=$(cf_urlencode "$hostname")
  cf_request GET "/zones/$zone_id/dns_records?name=$enc" || return 2
  cf_check_ok "look up DNS record for '$hostname'" || return 1
  cf_extract '([r.get("id","") for r in (d.get("result") or []) if r.get("type") in ("CNAME","A","AAAA")] or [""])[0]'
}

# cf_dns_current_record <zone_id> <record_id>: print the record's current
# content (target) and comment (the ownership marker), tab-separated, from one
# GET. The comment is empty when the record has none.
cf_dns_current_record() {
  local zone_id=$1 record_id=$2
  cf_request GET "/zones/$zone_id/dns_records/$record_id" || return 2
  cf_check_ok "read DNS record $record_id" || return 1
  cf_extract 'd.get("result",{}).get("content","") + "\t" + (d.get("result",{}).get("comment") or "")'
}

# cf_dns_create <zone_id> <hostname> <content> <comment>: create the proxied CNAME.
cf_dns_create() {
  local zone_id=$1 hostname=$2 content=$3 comment=$4 body
  body=$(cf_body_dns_record "$hostname" "$content" "$comment")
  cf_request POST "/zones/$zone_id/dns_records" "$body" || return 2
  cf_check_ok "create DNS record for '$hostname'" || return 1
  cf_extract 'd.get("result",{}).get("id","")'
}

# cf_dns_update <zone_id> <record_id> <hostname> <content> <comment>
cf_dns_update() {
  local zone_id=$1 record_id=$2 hostname=$3 content=$4 comment=$5 body
  body=$(cf_body_dns_record "$hostname" "$content" "$comment")
  cf_request PUT "/zones/$zone_id/dns_records/$record_id" "$body" || return 2
  cf_check_ok "update DNS record for '$hostname'"
}

# cf_dns_delete <zone_id> <record_id>
cf_dns_delete() {
  local zone_id=$1 record_id=$2
  cf_request DELETE "/zones/$zone_id/dns_records/$record_id" || return 2
  cf_check_ok "delete DNS record $record_id"
}

# cf_access_app_find <hostname>: print the app id for an exact domain match.
# The domain= filter is a server-side hint, not a guarantee, so every page is
# walked and re-filtered client-side: an existing app must never be missed, or
# `up` would duplicate it and `down` would report a still-live gate as gone.
cf_access_app_find() {
  local hostname=$1 enc page=1 total found
  enc=$(cf_urlencode "$hostname")
  while :; do
    cf_request GET "/accounts/$CF_ACCOUNT_ID/access/apps?domain=$enc&per_page=50&page=$page" || return 2
    cf_check_ok "list Access apps for '$hostname'" || return 1
    found=$(printf '%s' "$CF_BODY" | python3 -c '
import json, sys
d = json.load(sys.stdin)
hostname = sys.argv[1]
for a in (d.get("result") or []):
    if a.get("domain") == hostname:
        print(a.get("id",""))
        break
' "$hostname")
    if [ -n "$found" ]; then
      printf '%s\n' "$found"
      return 0
    fi
    total=$(cf_extract '(d.get("result_info") or {}).get("total_pages") or 0')
    [ -n "$total" ] && [ "$total" -gt "$page" ] 2>/dev/null || return 0
    page=$((page + 1))
  done
}

# cf_access_app_current_name <app_id>: print the app's current name (the
# ownership marker), or nothing when it has none.
cf_access_app_current_name() {
  local app_id=$1
  cf_request GET "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id" || return 2
  cf_check_ok "read Access app $app_id" || return 1
  cf_extract 'd.get("result",{}).get("name") or ""'
}

# cf_access_app_create <hostname> <name>: create the self-hosted app, print id.
cf_access_app_create() {
  local hostname=$1 name=$2 body
  body=$(cf_body_access_app "$hostname" "$name")
  cf_request POST "/accounts/$CF_ACCOUNT_ID/access/apps" "$body" || return 2
  cf_check_ok "create Access app for '$hostname'" || return 1
  cf_extract 'd.get("result",{}).get("id","")'
}

# cf_access_app_update <app_id> <hostname> <name>
cf_access_app_update() {
  local app_id=$1 hostname=$2 name=$3 body
  body=$(cf_body_access_app "$hostname" "$name")
  cf_request PUT "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id" "$body" || return 2
  cf_check_ok "update Access app $app_id"
}

# cf_access_app_delete <app_id>
cf_access_app_delete() {
  local app_id=$1
  cf_request DELETE "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id" || return 2
  cf_check_ok "delete Access app $app_id"
}

# cf_access_policy_find <app_id>: print the id of the firstmate-managed policy
# (matched by name), or nothing.
cf_access_policy_find() {
  local app_id=$1
  cf_request GET "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies" || return 2
  cf_check_ok "list Access policies for app $app_id" || return 1
  printf '%s' "$CF_BODY" | python3 -c '
import json, sys
d = json.load(sys.stdin)
name = sys.argv[1]
for p in (d.get("result") or []):
    if p.get("name") == name:
        print(p.get("id",""))
        break
' "$FM_TUNNEL_ACCESS_POLICY_NAME"
}

# cf_access_policy_create <app_id> <email> [<email> ...]: print the policy id.
cf_access_policy_create() {
  local app_id=$1
  shift
  local body
  body=$(cf_body_access_policy "$FM_TUNNEL_ACCESS_POLICY_NAME" "$@")
  cf_request POST "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies" "$body" || return 2
  cf_check_ok "create Access policy for app $app_id" || return 1
  cf_extract 'd.get("result",{}).get("id","")'
}

# cf_access_policy_update <app_id> <policy_id> <email> [<email> ...]
cf_access_policy_update() {
  local app_id=$1 policy_id=$2
  shift 2
  local body
  body=$(cf_body_access_policy "$FM_TUNNEL_ACCESS_POLICY_NAME" "$@")
  cf_request PUT "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies/$policy_id" "$body" || return 2
  cf_check_ok "update Access policy $policy_id"
}

# cf_access_policy_delete <app_id> <policy_id>
cf_access_policy_delete() {
  local app_id=$1 policy_id=$2
  cf_request DELETE "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies/$policy_id" || return 2
  cf_check_ok "delete Access policy $policy_id"
}

# --- connector (LaunchAgent) management ----------------------------------------

fm_tunnel_label() {
  printf 'com.firstmate.tunnel.%s' "$1"
}

fm_tunnel_plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist' "${FM_TUNNEL_HOME_DIR:-$HOME}" "$(fm_tunnel_label "$1")"
}

fm_tunnel_token_path() {
  printf '%s/config/tunnel-%s.token' "$FM_HOME" "$1"
}

fm_tunnel_wrapper_path() {
  printf '%s/config/tunnel-%s-run.sh' "$FM_HOME" "$1"
}

fm_tunnel_log_path() {
  printf '%s/state/tunnel-%s.%s.log' "$FM_HOME" "$1" "$2"
}

# fm_tunnel_ensure_cloudflared: cloudflared is never installed without explicit
# consent, mirroring bootstrap's MISSING:/consent/install convention. A missing
# binary is a hard failure naming the install command; only an explicit
# --install-cloudflared (FM_TUNNEL_INSTALL_CLOUDFLARED=1) opts into the install.
fm_tunnel_ensure_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 && return 0
  if [ "${FM_TUNNEL_INSTALL_CLOUDFLARED:-0}" != "1" ]; then
    echo "fm-tunnel: MISSING: cloudflared (install: brew install cloudflared)" >&2
    echo "fm-tunnel: install it, or re-run 'up' with --install-cloudflared to install it now" >&2
    return 1
  fi
  command -v brew >/dev/null 2>&1 || {
    echo "fm-tunnel: cloudflared not found and Homebrew is unavailable to install it" >&2
    return 1
  }
  echo "fm-tunnel: installing cloudflared via Homebrew (--install-cloudflared)" >&2
  brew install cloudflared >&2
}

# fm_tunnel_render_wrapper <project>: print the small script the LaunchAgent
# execs. Keeping the token out of the plist means it never lands in a
# world-readable file under ~/Library/LaunchAgents, and passing it through
# a shell environment assignment (never `env`, whose own argv would carry the
# value) keeps it out of every process's argv, which any
# local user can read via `ps`. cloudflared
# is resolved to an absolute path here, because launchd hands the job a minimal
# PATH that contains neither Homebrew prefix - a bare name would exec-fail into
# a silent KeepAlive respawn loop while `up` reported success.
fm_tunnel_render_wrapper() {
  local project=$1 token_file cloudflared_bin
  token_file=$(fm_tunnel_token_path "$project")
  cloudflared_bin=$(command -v cloudflared) || {
    echo "fm-tunnel: cloudflared disappeared from PATH" >&2
    return 1
  }
  case "$cloudflared_bin" in
    /*) : ;;
    *) cloudflared_bin=$(cd "$(dirname "$cloudflared_bin")" && pwd)/$(basename "$cloudflared_bin") ;;
  esac
  cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
TUNNEL_TOKEN="\$(cat "$token_file")" exec "$cloudflared_bin" tunnel run
EOF
}

# fm_tunnel_write_wrapper <project>: write that script to disk.
fm_tunnel_write_wrapper() {
  local project=$1 wrapper content
  wrapper=$(fm_tunnel_wrapper_path "$project")
  content=$(fm_tunnel_render_wrapper "$project") || return 1
  mkdir -p "$(dirname "$wrapper")" || return 1
  printf '%s\n' "$content" > "$wrapper" || return 1
  chmod 700 "$wrapper"
}

# fm_tunnel_render_plist <project>: print the LaunchAgent plist.
fm_tunnel_render_plist() {
  local project=$1 label wrapper out_log err_log
  label=$(fm_tunnel_label "$project")
  wrapper=$(fm_tunnel_wrapper_path "$project")
  out_log=$(fm_tunnel_log_path "$project" out)
  err_log=$(fm_tunnel_log_path "$project" err)
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${wrapper}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${out_log}</string>
  <key>StandardErrorPath</key>
  <string>${err_log}</string>
</dict>
</plist>
EOF
}

# fm_tunnel_write_plist <project>: write that plist to disk.
fm_tunnel_write_plist() {
  local project=$1 plist content out_log
  plist=$(fm_tunnel_plist_path "$project")
  out_log=$(fm_tunnel_log_path "$project" out)
  content=$(fm_tunnel_render_plist "$project") || return 1
  mkdir -p "$(dirname "$plist")" "$(dirname "$out_log")" || return 1
  printf '%s\n' "$content" > "$plist"
}

# fm_tunnel_connector_unchanged <project> <run-token>: succeed when the token
# file, wrapper, and plist already on disk are byte-identical to what `up`
# would write, and the connector is alive. Lets an idempotent `up` skip the
# unload/reload bounce, which would otherwise drop a live tunnel for the
# duration of the cloudflared restart.
fm_tunnel_connector_unchanged() {
  local project=$1 run_token=$2 token_file wrapper plist want
  token_file=$(fm_tunnel_token_path "$project")
  wrapper=$(fm_tunnel_wrapper_path "$project")
  plist=$(fm_tunnel_plist_path "$project")
  [ -f "$token_file" ] && [ -f "$wrapper" ] && [ -f "$plist" ] || return 1
  [ "$(cat "$token_file")" = "$run_token" ] || return 1
  want=$(fm_tunnel_render_wrapper "$project") || return 1
  [ "$(cat "$wrapper")" = "$want" ] || return 1
  want=$(fm_tunnel_render_plist "$project") || return 1
  [ "$(cat "$plist")" = "$want" ] || return 1
  fm_tunnel_launchagent_alive "$project"
}

# fm_tunnel_launchagent_start <project>: (re)load the LaunchAgent so it picks
# up a fresh plist/token. Idempotent: unload is best-effort (a fresh install
# has nothing loaded yet).
fm_tunnel_launchagent_start() {
  local project=$1 plist
  plist=$(fm_tunnel_plist_path "$project")
  command -v launchctl >/dev/null 2>&1 || { echo "fm-tunnel: launchctl not found" >&2; return 1; }
  launchctl unload "$plist" >/dev/null 2>&1 || true
  launchctl load -w "$plist"
}

# fm_tunnel_launchagent_stop <project>: unload if loaded; never errors on an
# already-stopped agent. When the plist file is gone but launchd still knows the
# label, unload-by-path is impossible, so fall back to removing the job by label
# - otherwise an orphaned job could never be stopped.
fm_tunnel_launchagent_stop() {
  local project=$1 plist label
  plist=$(fm_tunnel_plist_path "$project")
  label=$(fm_tunnel_label "$project")
  command -v launchctl >/dev/null 2>&1 || return 0
  [ -f "$plist" ] && launchctl unload "$plist" >/dev/null 2>&1
  fm_tunnel_launchagent_loaded "$project" || return 0
  launchctl bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 ||
    launchctl remove "$label" >/dev/null 2>&1 || true
}

# fm_tunnel_launchagent_loaded <project>: succeed when launchctl still knows the
# label at all, whatever its pid column says. This is the unload check: a
# crashed-but-registered job (pid "-") is still loaded and must not be treated
# as stopped.
fm_tunnel_launchagent_loaded() {
  local project=$1 label
  label=$(fm_tunnel_label "$project")
  command -v launchctl >/dev/null 2>&1 || return 1
  launchctl list 2>/dev/null | awk -v l="$label" '$3 == l { found = 1 } END { exit found ? 0 : 1 }'
}

# fm_tunnel_launchagent_alive <project>: succeed only when launchctl reports a
# live pid for the label. A loaded-but-crashed agent lists a "-" pid and is not
# alive, so `status` never claims a dead connector is running.
fm_tunnel_launchagent_alive() {
  local project=$1 label pid
  label=$(fm_tunnel_label "$project")
  command -v launchctl >/dev/null 2>&1 || return 1
  pid=$(launchctl list 2>/dev/null | awk -v l="$label" '$3 == l { print $1; exit }')
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}
