#!/usr/bin/env bash
# End-to-end tests for bin/fm-tunnel.sh against a stand-in Cloudflare API
# (tests/fake-cloudflare.py) plus launchctl/cloudflared PATH shims, so the real
# script's real curl requests, real plist/wrapper/token writes, and real
# LaunchAgent lifecycle are exercised without touching a Cloudflare account or
# the host's launchd.
#
# Matrix:
#   (a) a missing cloudflared is a hard error naming the brew command, before
#       any Cloudflare API call is made
#   (b) `up` provisions tunnel, ingress, Access app+policy, marker-tagged
#       proxied CNAME, and a 0600 token file + LaunchAgent, in that order
#   (c) `status` reports the live resources; the token never leaks to output
#   (d) a second `up` is idempotent and a true no-op: no duplicate resources
#       and no LaunchAgent bounce
#   (e) `up` refuses a hostname whose DNS record lacks this project's marker
#   (f) `up` self-heals a firstmate-owned record whose proxied flag was flipped
#   (g) `down` removes the connector, DNS record, Access app+policy and tunnel
#   (h) `down` leaves the Access gate alive, and exits non-zero, when the DNS
#       record's state cannot be confirmed
#   (i) `down` leaves a foreign DNS record and a foreign Access app untouched
#   (j) creation-time flags are rejected on down/status
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TUNNEL="$ROOT/bin/fm-tunnel.sh"
FAKE_CF="$(dirname "${BASH_SOURCE[0]}")/fake-cloudflare.py"
TMP_ROOT=$(fm_test_tmproot fm-tunnel-tests)
mkdir -p "$TMP_ROOT"

SRV_PID=""
cleanup() {
  if [ -n "$SRV_PID" ]; then
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
  fi
  rm -rf "$TMP_ROOT"
  fm_test_cleanup
}
trap cleanup EXIT

STATE="$TMP_ROOT/cf-state.json"
PORTFILE="$TMP_ROOT/cf-port"
TOKEN="cf-test-token-secret"
ACCOUNT="acct123"

# --- fake Cloudflare ---------------------------------------------------------
seed_state() {
  cat > "$STATE" <<EOF
{"token":"$TOKEN","zones":[{"id":"zone1","name":"example.com"}],
 "tunnels":[],"dns":[],"apps":[],"policies":[],"requests":[],"fail":[]}
EOF
}
seed_state
python3 "$FAKE_CF" "$STATE" "$PORTFILE" & SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$PORTFILE" ] && break; sleep 0.1; done
[ -s "$PORTFILE" ] || fail "fake Cloudflare API never came up"
export CF_API_BASE="http://127.0.0.1:$(cat "$PORTFILE")"

jqp() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2],{"d":d}))' "$STATE" "$1"; }
set_fail() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["fail"]=sys.argv[2:]; json.dump(d,open(sys.argv[1],"w"))' "$STATE" "$@"; }
clear_requests() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["requests"]=[]; json.dump(d,open(sys.argv[1],"w"))' "$STATE"; }

# --- firstmate home + PATH shims ---------------------------------------------
export FM_HOME="$TMP_ROOT/home"
export FM_TUNNEL_HOME_DIR="$TMP_ROOT/fakehome"   # LaunchAgents plist lives here
mkdir -p "$FM_HOME/config" "$FM_HOME/state" "$FM_TUNNEL_HOME_DIR/Library/LaunchAgents"

cat > "$FM_HOME/config/cloudflare.env" <<EOF
CLOUDFLARE_API_TOKEN=$TOKEN
CLOUDFLARE_ACCOUNT_ID=$ACCOUNT
FM_TUNNEL_HOUSE_HUNTER_HOSTNAME=househunter.example.com
FM_TUNNEL_HOUSE_HUNTER_ZONE=example.com
FM_TUNNEL_HOUSE_HUNTER_SERVICE=http://localhost:8765
FM_TUNNEL_HOUSE_HUNTER_ACCESS_EMAILS=captain@example.com
EOF

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LAUNCHD="$TMP_ROOT/launchd.txt"   # lines: "<pid> <status> <label> <plist>"
: > "$LAUNCHD"
export LAUNCHD
cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
db=$LAUNCHD
case "$1" in
  list) cat "$db"; exit 0 ;;
  load)
    plist=${*: -1}
    label=$(basename "$plist" .plist)
    grep -q " $label " "$db" 2>/dev/null && exit 1
    echo "4242 0 $label $plist" >> "$db"; exit 0 ;;
  unload)
    plist=${*: -1}
    label=$(basename "$plist" .plist)
    grep -q " $label " "$db" || exit 1
    grep -v " $label " "$db" > "$db.n"; mv "$db.n" "$db"; exit 0 ;;
  bootout|remove)
    label=${2##*/}
    grep -v " $label " "$db" > "$db.n" 2>/dev/null; mv "$db.n" "$db"; exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/launchctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/cloudflared"
chmod +x "$FAKEBIN/cloudflared"
# A minimal PATH so removing the cloudflared shim really hides cloudflared,
# even on a host where Homebrew has the real binary installed.
export PATH="$FAKEBIN:/usr/bin:/bin:/usr/sbin:/sbin"

PROJECT=house-hunter
HOST=househunter.example.com
LABEL=com.firstmate.tunnel.$PROJECT
PLIST="$FM_TUNNEL_HOME_DIR/Library/LaunchAgents/$LABEL.plist"
TOKEN_FILE="$FM_HOME/config/tunnel-$PROJECT.token"
# Set FM_TUNNEL_TEST_TRANSCRIPT to keep the CLI transcript after the run.
TRANSCRIPT="${FM_TUNNEL_TEST_TRANSCRIPT:-$TMP_ROOT/transcript.txt}"
: > "$TRANSCRIPT"

run() { # run <label> <args...>; captures combined output, echoes it, records rc
  local label=$1; shift
  printf '\n$ fm-tunnel.sh %s\n' "$*" >> "$TRANSCRIPT"
  OUT=$("$TUNNEL" "$@" 2>&1)
  RC=$?
  printf '%s\n[exit %d]\n' "$OUT" "$RC" >> "$TRANSCRIPT"
}

# (a) missing cloudflared is a hard error, before any API call ----------------
clear_requests
mv "$FAKEBIN/cloudflared" "$TMP_ROOT/cloudflared.bak"
run nocfd up "$PROJECT"
mv "$TMP_ROOT/cloudflared.bak" "$FAKEBIN/cloudflared"
[ "$RC" -ne 0 ] || fail "(a) up succeeded with no cloudflared"
case "$OUT" in *"MISSING: cloudflared (install: brew install cloudflared)"*) ;; *) fail "(a) no brew hint: $OUT" ;; esac
[ "$(jqp 'len(d["requests"])')" = 0 ] || fail "(a) Cloudflare was called before the cloudflared check"
pass "(a) missing cloudflared fails with the brew command and zero API calls"

# (b) up provisions everything ------------------------------------------------
clear_requests
run up1 up "$PROJECT"
[ "$RC" -eq 0 ] || fail "(b) up failed: $OUT"
[ "$(jqp 'len(d["tunnels"])')" = 1 ] || fail "(b) no tunnel"
TID=$(jqp 'd["tunnels"][0]["id"]')
[ "$(jqp 'd["ingress"]["config"]["ingress"][0]["service"]')" = "http://localhost:8765" ] || fail "(b) ingress service"
[ "$(jqp 'd["dns"][0]["content"]')" = "$TID.cfargotunnel.com" ] || fail "(b) CNAME target"
[ "$(jqp 'd["dns"][0]["proxied"]')" = True ] || fail "(b) record not proxied"
[ "$(jqp 'd["dns"][0]["comment"]')" = "managed by firstmate fm-tunnel: $PROJECT" ] || fail "(b) missing DNS marker"
[ "$(jqp 'd["apps"][0]["name"]')" = "firstmate: $PROJECT" ] || fail "(b) missing app marker"
[ "$(jqp 'd["policies"][0]["include"][0]["email"]["email"]')" = "captain@example.com" ] || fail "(b) policy email"
# gate before route: the Access app is POSTed before the DNS record
python3 - "$STATE" <<'PY' || fail "(b) DNS record created before the Access gate"
import json,sys
r=json.load(open(sys.argv[1]))["requests"]
app=next(i for i,x in enumerate(r) if x.startswith("POST /accounts") and x.endswith("/access/apps"))
dns=next(i for i,x in enumerate(r) if x.startswith("POST /zones/") and x.endswith("/dns_records"))
sys.exit(0 if app < dns else 1)
PY
[ -f "$TOKEN_FILE" ] || fail "(b) no token file"
[ "$(stat -f '%Lp' "$TOKEN_FILE")" = 600 ] || fail "(b) token file not 0600"
[ "$(cat "$TOKEN_FILE")" = "run-token-for-$TID" ] || fail "(b) wrong token stored"
grep -q " $LABEL " "$LAUNCHD" || fail "(b) LaunchAgent not loaded"
grep -q 'TUNNEL_TOKEN=' "$FM_HOME/config/tunnel-$PROJECT-run.sh" || fail "(b) wrapper does not pass the token by env"
grep -q "run-token" "$PLIST" && fail "(b) token leaked into the plist"
case "$OUT" in *"run-token-for-$TID"*) fail "(b) run-token leaked to output" ;; esac
case "$OUT" in *"$TOKEN"*) fail "(b) API token leaked to output" ;; esac
case "$OUT" in *"is live at https://$HOST"*) ;; *) fail "(b) no live summary: $OUT" ;; esac
pass "(b) up provisions tunnel, ingress, gate-before-route, marked CNAME, 0600 token, LaunchAgent"

# (c) status ------------------------------------------------------------------
run status1 status "$PROJECT"
[ "$RC" -eq 0 ] || fail "(c) status failed: $OUT"
case "$OUT" in *"tunnel:      firstmate-$PROJECT ($TID)"*) ;; *) fail "(c) tunnel line: $OUT" ;; esac
case "$OUT" in *"dns:         $HOST -> $TID.cfargotunnel.com"*) ;; *) fail "(c) dns line: $OUT" ;; esac
case "$OUT" in *"policy configured"*) ;; *) fail "(c) access line: $OUT" ;; esac
case "$OUT" in *"connector:   LaunchAgent loaded and running ($LABEL)"*) ;; *) fail "(c) connector line: $OUT" ;; esac
case "$OUT" in *"$TOKEN"*|*"run-token"*) fail "(c) status leaked a secret" ;; esac
pass "(c) status reports live tunnel, DNS, gate and connector without leaking secrets"

# (d) second up is idempotent and does not bounce the connector ---------------
PLIST_MTIME_BEFORE=$(stat -f %m "$PLIST")
sleep 1
run up2 up "$PROJECT"
[ "$RC" -eq 0 ] || fail "(d) second up failed: $OUT"
[ "$(jqp 'len(d["tunnels"])')" = 1 ] || fail "(d) duplicate tunnel"
[ "$(jqp 'len(d["dns"])')" = 1 ] || fail "(d) duplicate DNS record"
[ "$(jqp 'len(d["apps"])')" = 1 ] || fail "(d) duplicate Access app"
[ "$(jqp 'len(d["policies"])')" = 1 ] || fail "(d) duplicate Access policy"
case "$OUT" in *"connector already running unchanged"*) ;; *) fail "(d) connector was bounced: $OUT" ;; esac
[ "$(stat -f %m "$PLIST")" = "$PLIST_MTIME_BEFORE" ] || fail "(d) plist rewritten on a no-op up"
[ "$(grep -c " $LABEL " "$LAUNCHD")" = 1 ] || fail "(d) LaunchAgent reloaded"
pass "(d) re-running up creates no duplicates and skips the LaunchAgent bounce"

# (f) a firstmate-owned record with proxied flipped off is self-healed --------
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["dns"][0]["proxied"]=False; json.dump(d,open(sys.argv[1],"w"))' "$STATE"
run heal up "$PROJECT"
[ "$RC" -eq 0 ] || fail "(f) heal up failed: $OUT"
[ "$(jqp 'd["dns"][0]["proxied"]')" = True ] || fail "(f) proxied flag not self-healed"
pass "(f) up rewrites an owned record whose proxied flag was flipped off"

# (e) refuses an unmarked record at the hostname ------------------------------
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["dns"][0]["comment"]="prod, do not touch"; d["dns"][0]["content"]="prod.origin.example.com"; json.dump(d,open(sys.argv[1],"w"))' "$STATE"
run foreign up "$PROJECT"
[ "$RC" -ne 0 ] || fail "(e) up clobbered a foreign DNS record"
case "$OUT" in *"refusing to touch the existing DNS record at '$HOST' -> prod.origin.example.com"*) ;; *) fail "(e) no refusal: $OUT" ;; esac
[ "$(jqp 'd["dns"][0]["content"]')" = "prod.origin.example.com" ] || fail "(e) foreign record was modified"
pass "(e) up refuses a hostname whose DNS record lacks this project's marker"

# (i) down leaves the foreign record and a foreign app untouched --------------
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["apps"][0]["name"]="prod gate"; json.dump(d,open(sys.argv[1],"w"))' "$STATE"
run downforeign down "$PROJECT"
[ "$(jqp 'len(d["dns"])')" = 1 ] || fail "(i) foreign DNS record deleted"
[ "$(jqp 'len(d["apps"])')" = 1 ] || fail "(i) foreign Access app deleted"
case "$OUT" in *"is not managed by fm-tunnel"*) ;; *) fail "(i) no untouched notice: $OUT" ;; esac
pass "(i) down leaves a foreign DNS record and Access app in place"

# restore an owned deployment for the remaining teardown cases
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["dns"]=[]; d["apps"]=[]; d["policies"]=[]; json.dump(d,open(sys.argv[1],"w"))' "$STATE"
run reup up "$PROJECT"
[ "$RC" -eq 0 ] || fail "reprovision failed: $OUT"

# (h) unconfirmable DNS state keeps the Access gate alive and fails loudly ----
set_fail "GET /zones/zone1/dns_records*"
run downfail down "$PROJECT"
[ "$RC" -ne 0 ] || fail "(h) down exited 0 despite a failed DNS lookup"
case "$OUT" in *"DNS record for '$HOST' (lookup failed)"*) ;; *) fail "(h) no DNS survivor: $OUT" ;; esac
case "$OUT" in *"Access app for '$HOST' (left in place on purpose, unverified"*) ;; *) fail "(h) gate not preserved: $OUT" ;; esac
[ "$(jqp 'len(d["apps"])')" = 1 ] || fail "(h) Access gate deleted while the route was unconfirmed"
[ "$(jqp 'len(d["dns"])')" = 1 ] || fail "(h) DNS record vanished"
set_fail
pass "(h) down keeps the login gate and exits non-zero when the route cannot be confirmed gone"

# (g) a clean down removes everything -----------------------------------------
run down down "$PROJECT"
[ "$RC" -eq 0 ] || fail "(g) down failed: $OUT"
[ "$(jqp 'len(d["dns"])')" = 0 ] || fail "(g) DNS record survived"
[ "$(jqp 'len(d["apps"])')" = 0 ] || fail "(g) Access app survived"
[ "$(jqp 'len(d["policies"])')" = 0 ] || fail "(g) Access policy survived"
[ "$(jqp 'len(d["tunnels"])')" = 0 ] || fail "(g) tunnel survived"
grep -q " $LABEL " "$LAUNCHD" && fail "(g) LaunchAgent still loaded"
[ -f "$PLIST" ] && fail "(g) plist survived"
[ -f "$TOKEN_FILE" ] && fail "(g) token file survived"
case "$OUT" in *"'$PROJECT' torn down"*) ;; *) fail "(g) no torn-down line: $OUT" ;; esac
run statusdown status "$PROJECT"
case "$OUT" in *"tunnel:      not found"*) ;; *) fail "(g) status after down: $OUT" ;; esac
case "$OUT" in *"connector:   not loaded"*) ;; *) fail "(g) status after down: $OUT" ;; esac
pass "(g) down removes connector, DNS, gate and tunnel; status confirms it"

# (j) creation-time flags rejected on down/status ------------------------------
run svcdown down "$PROJECT" --service http://x
[ "$RC" -eq 2 ] || fail "(j) --service accepted on down"
case "$OUT" in *"--service is only valid for 'up'"*) ;; *) fail "(j) wrong message: $OUT" ;; esac
run emailstatus status "$PROJECT" --emails a@b.c
[ "$RC" -eq 2 ] || fail "(j) --emails accepted on status"
pass "(j) creation-time flags are rejected on down and status"

echo "transcript: $TRANSCRIPT"
