#!/usr/bin/env bash
# Behavior tests for fm-spectrum-poll.sh's bridge-error dedup, mirroring
# fm-x-poll.sh's emit_error_once/clear_error contract (state/x-poll.error)
# with state/spectrum-poll.error:
#   - a persistently failing bridge must wake firstmate once per DISTINCT
#     error message, not every check cycle
#   - a following distinct error re-alerts
#   - a subsequent success clears the marker so a later failure re-alerts too
#
# Deterministic: no real bridge/Messages.app. Uses the SPECTRUM_ENSURE_BRIDGE_BIN
# testing seam (mirroring fm-spectrum-ensure-bridge.sh's own SPECTRUM_BRIDGE_BIN
# override) to point fm-spectrum-poll.sh at a tiny stub instead of the real
# bin/fm-spectrum-ensure-bridge.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spectrum-poll-error-dedup-tests)
trap 'fm_test_cleanup' EXIT

# make_ensure_stub <dir> <rc> <message>: a fake ensure-bridge that just prints
# <message> and exits <rc> - enough to drive the dedup logic without a real
# bridge process.
make_ensure_stub() {
  local dir=$1 rc=$2 msg=$3
  local bin="$dir/fake-ensure-bridge.sh"
  mkdir -p "$dir"
  cat > "$bin" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$msg"
exit $rc
EOF
  chmod +x "$bin"
  printf '%s' "$bin"
}

run_poll() {
  local home=$1 stub=$2
  FM_HOME="$home" SPECTRUM_SELF_HANDLE=me@example.com SPECTRUM_CAPTAIN_HANDLE=cap@example.com \
    SPECTRUM_ENSURE_BRIDGE_BIN="$stub" "$ROOT/bin/fm-spectrum-poll.sh" 2>&1
}

test_first_failure_wakes_and_writes_marker() {
  local home="$TMP_ROOT/first-fail"
  mkdir -p "$home"
  local stub; stub=$(make_ensure_stub "$TMP_ROOT/first-fail-bin" 1 "bridge died")
  local out
  out=$(run_poll "$home" "$stub")
  assert_contains "$out" "spectrum-bridge-error bridge died" \
    "the first failing cycle must print a spectrum-bridge-error wake"
  assert_present "$home/state/spectrum-poll.error" \
    "the first failing cycle must write the dedupe marker"
  [ "$(cat "$home/state/spectrum-poll.error")" = "bridge died" ] \
    || fail "the marker must store the exact error message"
  pass "fm-spectrum-poll wakes and records the marker on the first failing cycle"
}

test_second_identical_failure_is_deduped() {
  local home="$TMP_ROOT/dedup"
  mkdir -p "$home"
  local stub; stub=$(make_ensure_stub "$TMP_ROOT/dedup-bin" 1 "bridge died")
  run_poll "$home" "$stub" >/dev/null
  local out
  out=$(run_poll "$home" "$stub")
  [ -z "$out" ] || fail "a second cycle with the SAME error must print nothing (got: $out)"
  [ "$(cat "$home/state/spectrum-poll.error")" = "bridge died" ] \
    || fail "the marker must be left unchanged by a deduped repeat"
  pass "fm-spectrum-poll deduplicates a repeated identical bridge-error, staying silent"
}

test_distinct_failure_realerts() {
  local home="$TMP_ROOT/distinct"
  mkdir -p "$home"
  local stub1; stub1=$(make_ensure_stub "$TMP_ROOT/distinct-bin1" 1 "bridge died")
  local stub2; stub2=$(make_ensure_stub "$TMP_ROOT/distinct-bin2" 1 "beacon missing")
  run_poll "$home" "$stub1" >/dev/null
  local out
  out=$(run_poll "$home" "$stub2")
  assert_contains "$out" "spectrum-bridge-error beacon missing" \
    "a cycle with a DIFFERENT error message must wake again"
  [ "$(cat "$home/state/spectrum-poll.error")" = "beacon missing" ] \
    || fail "the marker must be updated to the new error message"
  pass "fm-spectrum-poll re-alerts on a distinct bridge-error message"
}

test_success_clears_marker_and_next_failure_realerts() {
  local home="$TMP_ROOT/clear"
  mkdir -p "$home"
  local fail_stub; fail_stub=$(make_ensure_stub "$TMP_ROOT/clear-bin-fail" 1 "bridge died")
  local ok_stub; ok_stub=$(make_ensure_stub "$TMP_ROOT/clear-bin-ok" 0 "")
  run_poll "$home" "$fail_stub" >/dev/null
  assert_present "$home/state/spectrum-poll.error" "precondition: marker present after first failure"

  run_poll "$home" "$ok_stub" >/dev/null
  assert_absent "$home/state/spectrum-poll.error" \
    "a successful cycle must clear the dedupe marker"

  local out
  out=$(run_poll "$home" "$fail_stub")
  assert_contains "$out" "spectrum-bridge-error bridge died" \
    "the SAME error message must re-alert once the marker has been cleared by a success"
  pass "fm-spectrum-poll clears the marker on success, so a later failure re-alerts"
}

test_first_failure_wakes_and_writes_marker
test_second_identical_failure_is_deduped
test_distinct_failure_realerts
test_success_clears_marker_and_next_failure_realerts
