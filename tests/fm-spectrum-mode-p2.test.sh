#!/usr/bin/env bash
# Behavior tests for fm-spectrum slice 2: always-on, two-way wiring on top of
# slice 1's bridge + outbound escalations (tests/fm-spectrum-mode.test.sh).
# Covers, all deterministically (no live iMessage, no LLM):
#   - bin/fm-spectrum-poll.sh: the inbound check-shim wake production (inert
#     unconfigured, silent when healthy/empty, wakes on pending inbound, wakes
#     on a genuine bridge state change, stays quiet on routine health).
#   - fm-spectrum-lib.sh's spectrum_inbox_list / spectrum_beacon_state helpers
#     (the inbox drain/dedup and stale-detection primitives spectrum-respond
#     and fm-spectrum-ensure-bridge.sh both build on).
#   - bin/fm-spectrum-ensure-bridge.sh: idempotent ensure-started, the
#     single-instance lock, pid-reuse safety, and stale-bridge restart -
#     exercised against a fake bridge binary (SPECTRUM_BRIDGE_BIN override) so
#     no real spectrum-ts/Messages.app is needed.
#   - bin/fm-spectrum-escalate.sh: the away-mode-gated auto-push wrapper.
#   - fm-bootstrap.sh: idempotent activation/deactivation of the
#     state/spectrum-watch.check.sh shim + config/spectrum-mode.env cadence,
#     mirroring the existing X-mode bootstrap tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spectrum-mode-p2-tests)

# Track any bridge-like background pids we start so a real test failure never
# leaves a stray process running after the suite exits.
SPAWNED_PIDS=()
cleanup_spawned() {
  local pid
  for pid in "${SPAWNED_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill -CONT "$pid" 2>/dev/null || true
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_spawned; fm_test_cleanup' EXIT

# make_fake_bridge <dir>: a fake long-running "bridge" that just touches its
# beacon on a fast interval until signaled - enough to exercise ensure-bridge's
# liveness/pid/beacon logic without spectrum-ts or a live Messages account.
make_fake_bridge() {
  local dir=$1
  local bin="$dir/fake-spectrum-bridge"
  mkdir -p "$dir"
  cat > "$bin" <<'EOF'
#!/usr/bin/env bash
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"
trap 'exit 0' TERM INT
while :; do date +%s > "$STATE/.spectrum-bridge-beat"; sleep 0.15; done
EOF
  chmod +x "$bin"
  printf '%s' "$bin"
}

# ---------------------------------------------------------------------------
# fm-spectrum-lib.sh: spectrum_beacon_state / spectrum_inbox_list
# ---------------------------------------------------------------------------

test_lib_beacon_state_dead_stale_healthy() {
  local home="$TMP_ROOT/lib-beacon"
  mkdir -p "$home/state"
  # shellcheck source=bin/fm-spectrum-lib.sh
  . "$ROOT/bin/fm-spectrum-lib.sh"
  local word rc
  word=$(spectrum_beacon_state "$home/state/.beat" 90); rc=$?
  [ "$word" = "dead" ] || fail "beacon_state must report dead for a missing beacon (got: $word)"
  [ "$rc" -ne 0 ] || fail "beacon_state must return non-zero for dead"

  date +%s > "$home/state/.beat"
  word=$(spectrum_beacon_state "$home/state/.beat" 90); rc=$?
  [ "$word" = "healthy" ] || fail "beacon_state must report healthy for a fresh beacon (got: $word)"
  [ "$rc" -eq 0 ] || fail "beacon_state must return 0 for healthy"

  touch -t 202001010000 "$home/state/.beat"
  word=$(spectrum_beacon_state "$home/state/.beat" 5); rc=$?
  [ "$word" = "stale" ] || fail "beacon_state must report stale for an old beacon under a short threshold (got: $word)"
  [ "$rc" -ne 0 ] || fail "beacon_state must return non-zero for stale"

  pass "spectrum_beacon_state reports dead/healthy/stale with the matching exit code"
}

test_lib_beacon_state_defaults_stale_secs() {
  local home="$TMP_ROOT/lib-beacon-default"
  mkdir -p "$home/state"
  # shellcheck source=bin/fm-spectrum-lib.sh
  . "$ROOT/bin/fm-spectrum-lib.sh"
  date +%s > "$home/state/.beat"
  local word
  word=$(spectrum_beacon_state "$home/state/.beat" "")
  [ "$word" = "healthy" ] || fail "an empty stale-secs argument must fall back to the 90s default (got: $word)"
  pass "spectrum_beacon_state falls back to a 90s default for an empty/non-numeric stale-secs argument"
}

test_lib_inbox_list_sorted_and_filtered() {
  local home="$TMP_ROOT/lib-inbox"
  mkdir -p "$home/state/spectrum-inbox"
  # shellcheck source=bin/fm-spectrum-lib.sh
  . "$ROOT/bin/fm-spectrum-lib.sh"
  # Absent dir -> nothing, no error.
  local out
  out=$(spectrum_inbox_list "$home/state/does-not-exist")
  [ -z "$out" ] || fail "spectrum_inbox_list on a missing dir must print nothing (got: $out)"

  : > "$home/state/spectrum-inbox/.hidden.json"
  : > "$home/state/spectrum-inbox/.partial.json.tmp"
  : > "$home/state/spectrum-inbox/b-second.json"
  : > "$home/state/spectrum-inbox/a-first.json"
  out=$(spectrum_inbox_list "$home/state/spectrum-inbox")
  local n
  n=$(printf '%s\n' "$out" | grep -c . || true)
  [ "$n" = 2 ] || fail "spectrum_inbox_list must skip dotfiles/.tmp remnants (got $n entries: $out)"
  [ "$(printf '%s\n' "$out" | head -n1 | xargs basename)" = "a-first.json" ] \
    || fail "spectrum_inbox_list must sort deterministically, oldest/earliest name first (got: $out)"
  pass "spectrum_inbox_list lists only real *.json records, sorted, skipping dotfiles and .tmp remnants"
}

# ---------------------------------------------------------------------------
# bin/fm-spectrum-poll.sh
# ---------------------------------------------------------------------------

test_poll_hard_noop_unconfigured() {
  local home="$TMP_ROOT/poll-noop"
  mkdir -p "$home/state/spectrum-inbox"
  : > "$home/state/spectrum-inbox/m1.json"
  local out rc
  out=$(FM_HOME="$home" "$ROOT/bin/fm-spectrum-poll.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "poll unconfigured exit"
  [ -z "$out" ] || fail "poll unconfigured must print nothing, even with a pending inbox file (got: $out)"
  pass "fm-spectrum-poll is a hard no-op without SPECTRUM_SELF_HANDLE"
}

test_poll_wakes_on_pending_inbound_oldest_first() {
  local home="$TMP_ROOT/poll-inbound"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/poll-inbound-bridge")
  mkdir -p "$home/state/spectrum-inbox"
  printf '{"id":"z-newer"}' > "$home/state/spectrum-inbox/z-newer.json"
  printf '{"id":"a-older"}' > "$home/state/spectrum-inbox/a-older.json"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-poll.sh" 2>&1); rc=$?
  local pid; pid=$(cat "$home/state/.spectrum-bridge.pid" 2>/dev/null || true)
  [ -n "$pid" ] && SPAWNED_PIDS+=("$pid")
  expect_code 0 "$rc" "poll pending-inbound exit"
  assert_contains "$out" "spectrum-inbound a-older" "poll must name the OLDEST pending message, not just any"
  assert_not_contains "$out" "spectrum-inbound z-newer" "poll must report only one representative id per cycle"
  pass "fm-spectrum-poll wakes on pending inbound, naming the oldest pending message"
}

test_poll_silent_when_healthy_and_empty() {
  local home="$TMP_ROOT/poll-quiet"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/poll-quiet-bridge")
  mkdir -p "$home/state"
  # Prime a healthy bridge first (own pidfile + fresh beacon), then poll again -
  # the second cycle must be completely silent (no restart chatter, no inbound).
  FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-poll.sh" >/dev/null 2>&1
  local pid; pid=$(cat "$home/state/.spectrum-bridge.pid" 2>/dev/null || true)
  [ -n "$pid" ] && SPAWNED_PIDS+=("$pid")
  # Give the fake bridge a moment to write its first beacon.
  local tries=0
  while [ "$tries" -lt 20 ] && [ ! -f "$home/state/.spectrum-bridge-beat" ]; do
    tries=$((tries + 1)); sleep 0.1
  done
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-poll.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "poll healthy-and-empty exit"
  [ -z "$out" ] || fail "poll must be silent once the bridge is healthy and the inbox is empty (got: $out)"
  pass "fm-spectrum-poll stays silent on a routine cycle (bridge healthy, inbox empty)"
}

# ---------------------------------------------------------------------------
# bin/fm-spectrum-ensure-bridge.sh
# ---------------------------------------------------------------------------

test_ensure_bridge_hard_noop_unconfigured() {
  local home="$TMP_ROOT/ensure-noop"
  mkdir -p "$home"
  local out rc
  out=$(FM_HOME="$home" "$ROOT/bin/fm-spectrum-ensure-bridge.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "ensure-bridge unconfigured exit"
  [ -z "$out" ] || fail "ensure-bridge unconfigured must print nothing (got: $out)"
  assert_absent "$home/state/.spectrum-bridge.pid" "ensure-bridge unconfigured must not start anything"
  pass "fm-spectrum-ensure-bridge is a hard no-op without SPECTRUM_SELF_HANDLE"
}

test_ensure_bridge_starts_when_dead() {
  local home="$TMP_ROOT/ensure-start"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/ensure-start-bridge")
  mkdir -p "$home"
  local out rc pid
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-ensure-bridge.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "ensure-bridge cold-start exit"
  assert_contains "$out" "started" "ensure-bridge must report starting a fresh bridge"
  pid=$(cat "$home/state/.spectrum-bridge.pid" 2>/dev/null || true)
  [ -n "$pid" ] || fail "ensure-bridge must record a pidfile after starting"
  SPAWNED_PIDS+=("$pid")
  kill -0 "$pid" 2>/dev/null || fail "the pid recorded in the pidfile must actually be alive"
  pass "fm-spectrum-ensure-bridge starts the bridge from a cold (dead) state and records its pid"
}

test_ensure_bridge_idempotent_when_healthy() {
  local home="$TMP_ROOT/ensure-idempotent"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/ensure-idempotent-bridge")
  mkdir -p "$home"
  FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-ensure-bridge.sh" >/dev/null 2>&1
  local pid1; pid1=$(cat "$home/state/.spectrum-bridge.pid")
  SPAWNED_PIDS+=("$pid1")
  local tries=0
  while [ "$tries" -lt 20 ] && [ ! -f "$home/state/.spectrum-bridge-beat" ]; do
    tries=$((tries + 1)); sleep 0.1
  done
  local out rc pid2
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-ensure-bridge.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "ensure-bridge idempotent-call exit"
  assert_contains "$out" "healthy" "a second call against a healthy bridge must report healthy, not start another"
  pid2=$(cat "$home/state/.spectrum-bridge.pid")
  [ "$pid1" = "$pid2" ] || fail "ensure-bridge must not launch a second process when the first is already healthy (pid1=$pid1 pid2=$pid2)"
  pass "fm-spectrum-ensure-bridge is idempotent: a healthy bridge is left running, not duplicated"
}

test_ensure_bridge_ignores_reused_pid() {
  local home="$TMP_ROOT/ensure-pidreuse"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/ensure-pidreuse-bridge")
  mkdir -p "$home/state"
  # A pidfile pointing at a real, live, but UNRELATED process (not the bridge)
  # must never be trusted - ensure-bridge must start a genuine bridge instead
  # of treating a coincidental pid match as "already running".
  sleep 60 &
  local bogus=$!
  SPAWNED_PIDS+=("$bogus")
  printf '%s\n' "$bogus" > "$home/state/.spectrum-bridge.pid"
  local out rc newpid
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-ensure-bridge.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "ensure-bridge pid-reuse exit"
  assert_contains "$out" "started" "a pidfile pointing at an unrelated live process must not be treated as a live bridge"
  newpid=$(cat "$home/state/.spectrum-bridge.pid")
  [ "$newpid" != "$bogus" ] || fail "ensure-bridge must not adopt an unrelated process's pid as its own"
  SPAWNED_PIDS+=("$newpid")
  kill -0 "$bogus" 2>/dev/null || fail "the unrelated bogus process must be left untouched, never killed"
  pass "fm-spectrum-ensure-bridge never trusts a pidfile whose pid does not look like the bridge"
}

test_ensure_bridge_restarts_stale() {
  local home="$TMP_ROOT/ensure-stale"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/ensure-stale-bridge")
  mkdir -p "$home"
  FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-ensure-bridge.sh" >/dev/null 2>&1
  local pid1; pid1=$(cat "$home/state/.spectrum-bridge.pid")
  local tries=0
  while [ "$tries" -lt 20 ] && [ ! -f "$home/state/.spectrum-bridge-beat" ]; do
    tries=$((tries + 1)); sleep 0.1
  done
  # Simulate a hung bridge: SIGSTOP it (so it cannot keep touching its own
  # beacon even though it is still technically alive) and force its beacon
  # into the past.
  kill -STOP "$pid1"
  touch -t 202001010000 "$home/state/.spectrum-bridge-beat"
  local out rc pid2
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_STALE_SECS=5 SPECTRUM_BRIDGE_BIN="$fake" \
    "$ROOT/bin/fm-spectrum-ensure-bridge.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "ensure-bridge stale-restart exit"
  assert_contains "$out" "stale" "ensure-bridge must report the stale bridge before restarting it"
  assert_contains "$out" "started" "ensure-bridge must start a replacement after killing the stale one"
  pid2=$(cat "$home/state/.spectrum-bridge.pid")
  SPAWNED_PIDS+=("$pid2")
  [ "$pid1" != "$pid2" ] || fail "ensure-bridge must launch a genuinely NEW process for the stale restart"
  # The stopped original must have been reaped (force-killed), not left running.
  kill -CONT "$pid1" 2>/dev/null || true
  kill -0 "$pid1" 2>/dev/null && fail "the stale original process must be terminated, not left running" || true
  pass "fm-spectrum-ensure-bridge detects a stale (hung) bridge, terminates it, and starts a fresh one"
}

test_ensure_bridge_single_instance_lock_skips_concurrent() {
  local home="$TMP_ROOT/ensure-lock"
  mkdir -p "$home/state"
  # Simulate another ensure-started run already in flight: an active lock dir
  # whose recorded pid is genuinely alive.
  sleep 60 &
  local holder=$!
  SPAWNED_PIDS+=("$holder")
  mkdir -p "$home/state/.spectrum-bridge.lock"
  printf '%s\n' "$holder" > "$home/state/.spectrum-bridge.lock/pid"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/ensure-lock-bridge")
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-ensure-bridge.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "ensure-bridge concurrent-lock exit"
  assert_contains "$out" "already in progress" "a live lock holder must make the second caller skip, not race-start a second bridge"
  assert_absent "$home/state/.spectrum-bridge.pid" "a skipped concurrent call must not have started anything"
  pass "fm-spectrum-ensure-bridge's single-instance lock makes a concurrent call skip instead of double-launching"
}

test_ensure_bridge_reclaims_stale_lock() {
  local home="$TMP_ROOT/ensure-stalelock"
  mkdir -p "$home/state/.spectrum-bridge.lock"
  # A lock directory whose owner pid is long gone must be reclaimed, not treated
  # as a permanent wedge.
  printf '999999\n' > "$home/state/.spectrum-bridge.lock/pid"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/ensure-stalelock-bridge")
  local out rc pid
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-spectrum-ensure-bridge.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "ensure-bridge stale-lock exit"
  assert_contains "$out" "started" "a stale (dead-owner) lock must be reclaimed so the bridge still starts"
  pid=$(cat "$home/state/.spectrum-bridge.pid" 2>/dev/null || true)
  [ -n "$pid" ] || fail "ensure-bridge must have started the bridge after reclaiming the stale lock"
  SPAWNED_PIDS+=("$pid")
  assert_absent "$home/state/.spectrum-bridge.lock" "the lock must be released after the run completes"
  pass "fm-spectrum-ensure-bridge reclaims a lock whose owner process is no longer alive"
}

# ---------------------------------------------------------------------------
# bin/fm-spectrum-escalate.sh
# ---------------------------------------------------------------------------

test_escalate_noop_unconfigured() {
  local home="$TMP_ROOT/escalate-noop"
  mkdir -p "$home/state"
  : > "$home/state/.afk"
  local out rc
  out=$(FM_HOME="$home" "$ROOT/bin/fm-spectrum-escalate.sh" "hello" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "escalate unconfigured exit"
  [ -z "$out" ] || fail "escalate must be silent when spectrum is not configured, even while afk (got: $out)"
  assert_absent "$home/state/spectrum-outbox" "escalate unconfigured must not queue anything"
  pass "fm-spectrum-escalate is a silent no-op when spectrum is not configured"
}

test_escalate_noop_when_not_away() {
  local home="$TMP_ROOT/escalate-not-away"
  mkdir -p "$home"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_DRY_RUN=1 "$ROOT/bin/fm-spectrum-escalate.sh" "hello" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "escalate not-away exit"
  [ -z "$out" ] || fail "escalate must stay silent when state/.afk is absent, even if configured (got: $out)"
  assert_absent "$home/state/spectrum-outbox" "escalate must not queue anything when the captain is not away"
  pass "fm-spectrum-escalate is a silent no-op when away-mode (state/.afk) is not active"
}

test_escalate_pushes_when_configured_and_away() {
  local home="$TMP_ROOT/escalate-away"
  mkdir -p "$home/state"
  : > "$home/state/.afk"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_DRY_RUN=1 "$ROOT/bin/fm-spectrum-escalate.sh" "PR ready for review" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "escalate away+configured exit"
  [ -n "$out" ] || fail "escalate must echo the generated outbox id when it actually pushes"
  assert_present "$home/state/spectrum-outbox/$out.json" "escalate must record an outbox entry when both gates pass"
  [ "$(jq -r .text "$home/state/spectrum-outbox/$out.json")" = "PR ready for review" ] \
    || fail "the pushed escalation must preserve the message text"
  pass "fm-spectrum-escalate pushes the escalation when spectrum is configured AND the captain is away"
}

test_escalate_text_file_and_stdin_forms() {
  local home="$TMP_ROOT/escalate-forms"
  mkdir -p "$home/state"
  : > "$home/state/.afk"
  printf 'blocked: need a decision on X vs Y' > "$home/msg.txt"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_DRY_RUN=1 "$ROOT/bin/fm-spectrum-escalate.sh" --text-file "$home/msg.txt" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "escalate --text-file exit"
  [ "$(jq -r .text "$home/state/spectrum-outbox/$out.json")" = "blocked: need a decision on X vs Y" ] \
    || fail "escalate --text-file must forward the file's contents verbatim"
  out=$(printf 'failed: the build broke' | FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com \
    SPECTRUM_CAPTAIN_HANDLE=cap@example.com SPECTRUM_DRY_RUN=1 "$ROOT/bin/fm-spectrum-escalate.sh" - 2>/dev/null); rc=$?
  expect_code 0 "$rc" "escalate stdin exit"
  [ "$(jq -r .text "$home/state/spectrum-outbox/$out.json")" = "failed: the build broke" ] \
    || fail "escalate - (stdin) must forward the piped text"
  pass "fm-spectrum-escalate accepts --text-file and stdin, mirroring fm-spectrum-notify.sh's forms"
}

test_escalate_usage_error() {
  local rc
  "$ROOT/bin/fm-spectrum-escalate.sh" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "escalate with no args exit"
  pass "fm-spectrum-escalate reports a usage error for missing arguments"
}

# ---------------------------------------------------------------------------
# fm-bootstrap.sh: state/spectrum-watch.check.sh + config/spectrum-mode.env
# ---------------------------------------------------------------------------

test_bootstrap_activates_spectrum_watch_from_env() {
  local home out sum1 sum2 n
  home="$TMP_ROOT/boot-on"; mkdir -p "$home"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/boot-on-bridge")
  printf 'SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com\nSPECTRUM_CAPTAIN_HANDLE=tharshan09@gmail.com\n' > "$home/.env"
  out=$(FM_HOME="$home" SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  local pid; pid=$(cat "$home/state/.spectrum-bridge.pid" 2>/dev/null || true)
  [ -n "$pid" ] && SPAWNED_PIDS+=("$pid")
  assert_contains "$out" "SPECTRUM: channel on" "bootstrap must announce the spectrum channel"
  assert_present "$home/state/spectrum-watch.check.sh" "bootstrap must drop the check shim"
  [ -x "$home/state/spectrum-watch.check.sh" ] || fail "the check shim must be executable"
  assert_grep "fm-spectrum-poll.sh" "$home/state/spectrum-watch.check.sh" "the shim must exec the poll script"
  assert_present "$home/config/spectrum-mode.env" "bootstrap must drop the cadence config"
  assert_grep "export FM_CHECK_INTERVAL=20" "$home/config/spectrum-mode.env" "cadence must be 20s"
  # Idempotent: re-running changes neither artifact's content.
  sum1=$(cat "$home/state/spectrum-watch.check.sh" "$home/config/spectrum-mode.env" | shasum)
  FM_HOME="$home" SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  sum2=$(cat "$home/state/spectrum-watch.check.sh" "$home/config/spectrum-mode.env" | shasum)
  [ "$sum1" = "$sum2" ] || fail "bootstrap spectrum-watch setup must be idempotent"
  n=$(find "$home/state" -maxdepth 1 -name 'spectrum-watch*' | wc -l | tr -d ' ')
  [ "$n" = "1" ] || fail "bootstrap must not duplicate the shim (found $n)"
  pass "bootstrap activates the spectrum watch shim + 20s cadence from an .env handle, idempotently"
}

test_bootstrap_inert_without_spectrum_handle() {
  local home out
  home="$TMP_ROOT/boot-off"; mkdir -p "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "SPECTRUM:" "bootstrap must say nothing about spectrum without a handle"
  assert_absent "$home/state/spectrum-watch.check.sh" "no handle -> no check shim"
  assert_absent "$home/config/spectrum-mode.env" "no handle -> no cadence config"
  assert_absent "$home/state/.spectrum-bridge.pid" "no handle -> bridge supervision must not start anything"
  pass "bootstrap is inert without a non-empty .env SPECTRUM_SELF_HANDLE (non-spectrum users unaffected)"
}

test_bootstrap_opt_out_removes_spectrum_watch_artifacts() {
  local home out
  home="$TMP_ROOT/boot-optout"; mkdir -p "$home"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/boot-optout-bridge")
  printf 'SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com\nSPECTRUM_CAPTAIN_HANDLE=tharshan09@gmail.com\n' > "$home/.env"
  FM_HOME="$home" SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
  local pid; pid=$(cat "$home/state/.spectrum-bridge.pid" 2>/dev/null || true)
  [ -n "$pid" ] && SPAWNED_PIDS+=("$pid")
  assert_present "$home/state/spectrum-watch.check.sh" "opt-in must create the shim"
  printf 'SPECTRUM_SELF_HANDLE=\n' > "$home/.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "SPECTRUM: channel off" "opt-out must announce the channel going off"
  assert_absent "$home/state/spectrum-watch.check.sh" "opt-out must remove the shim"
  assert_absent "$home/config/spectrum-mode.env" "opt-out must remove the cadence config"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_not_contains "$out" "SPECTRUM:" "steady-state off must be silent"
  pass "bootstrap cleans up spectrum-watch artifacts on opt-out and is silent once off"
}

test_bootstrap_supervises_bridge_on_session_start() {
  local home out
  home="$TMP_ROOT/boot-supervise"; mkdir -p "$home"
  local fake; fake=$(make_fake_bridge "$TMP_ROOT/boot-supervise-bridge")
  printf 'SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com\nSPECTRUM_CAPTAIN_HANDLE=tharshan09@gmail.com\n' > "$home/.env"
  out=$(FM_HOME="$home" SPECTRUM_BRIDGE_BIN="$fake" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  local pid; pid=$(cat "$home/state/.spectrum-bridge.pid" 2>/dev/null || true)
  [ -n "$pid" ] || fail "bootstrap must have started the bridge via ensure-bridge on session start"
  SPAWNED_PIDS+=("$pid")
  kill -0 "$pid" 2>/dev/null || fail "the bridge pid bootstrap recorded must actually be alive"
  assert_contains "$out" "SPECTRUM: spectrum-bridge: started" "bootstrap must report starting the bridge"
  pass "bootstrap's mutating sweep starts the bridge (via fm-spectrum-ensure-bridge.sh) on session start"
}

# ---------------------------------------------------------------------------

test_lib_beacon_state_dead_stale_healthy
test_lib_beacon_state_defaults_stale_secs
test_lib_inbox_list_sorted_and_filtered
test_poll_hard_noop_unconfigured
test_poll_wakes_on_pending_inbound_oldest_first
test_poll_silent_when_healthy_and_empty
test_ensure_bridge_hard_noop_unconfigured
test_ensure_bridge_starts_when_dead
test_ensure_bridge_idempotent_when_healthy
test_ensure_bridge_ignores_reused_pid
test_ensure_bridge_restarts_stale
test_ensure_bridge_single_instance_lock_skips_concurrent
test_ensure_bridge_reclaims_stale_lock
test_escalate_noop_unconfigured
test_escalate_noop_when_not_away
test_escalate_pushes_when_configured_and_away
test_escalate_text_file_and_stdin_forms
test_escalate_usage_error
test_bootstrap_activates_spectrum_watch_from_env
test_bootstrap_inert_without_spectrum_handle
test_bootstrap_opt_out_removes_spectrum_watch_artifacts
test_bootstrap_supervises_bridge_on_session_start
