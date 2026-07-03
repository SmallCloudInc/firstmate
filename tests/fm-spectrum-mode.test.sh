#!/usr/bin/env bash
# Behavior tests for fm-spectrum (the private captain<->firstmate iMessage
# channel, slice 1): the shared lib (fm-spectrum-lib.sh), the outbound notify
# client (fm-spectrum-notify.sh), the health check (fm-spectrum-status.sh), and
# the bridge launcher's gating (fm-spectrum-bridge).
#
# fm-spectrum must be INERT by default (no SPECTRUM_SELF_HANDLE -> every script
# is a hard no-op) and dry-run must work end to end with no live Messages
# account, no bridge process, and no spectrum-ts install - that is this PR's
# acceptance path. The bridge launcher's dependency-missing failure is exercised
# for real (no node module mocking needed: spectrum-ts is genuinely not
# installed in this checkout), pinning the "fails gracefully when unconfigured"
# contract. Real Spectrum/iMessage behavior (a live account, a live send) is out
# of scope for this suite and this PR.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spectrum-mode-tests)

# ---------------------------------------------------------------------------
# fm-spectrum-lib.sh
# ---------------------------------------------------------------------------

test_lib_env_get_reads_last_assignment() {
  local file="$TMP_ROOT/lib-env-get/.env"
  mkdir -p "$(dirname "$file")"
  printf 'SPECTRUM_SELF_HANDLE=first@example.com\nSPECTRUM_SELF_HANDLE=second@example.com\n' > "$file"
  # shellcheck source=bin/fm-spectrum-lib.sh
  . "$ROOT/bin/fm-spectrum-lib.sh"
  local val
  val=$(spectrum_env_get SPECTRUM_SELF_HANDLE "$file")
  [ "$val" = "second@example.com" ] || fail "spectrum_env_get must take the last assignment (got: $val)"
  pass "spectrum_env_get reads the last assignment in a .env-style file"
}

test_lib_load_config_env_wins_over_dotenv() {
  local home="$TMP_ROOT/lib-precedence"
  mkdir -p "$home"
  printf 'SPECTRUM_SELF_HANDLE=dotenv@example.com\nSPECTRUM_CAPTAIN_HANDLE=dotenv-captain@example.com\n' > "$home/.env"
  # shellcheck source=bin/fm-spectrum-lib.sh
  . "$ROOT/bin/fm-spectrum-lib.sh"
  FM_HOME="$home" SPECTRUM_SELF_HANDLE=env@example.com spectrum_load_config
  [ "$SPECTRUM_SELF" = "env@example.com" ] || fail "explicit env var must win over .env (got: $SPECTRUM_SELF)"
  [ "$SPECTRUM_CAPTAIN" = "dotenv-captain@example.com" ] || fail ".env must still supply unset vars"
  pass "spectrum_load_config lets an explicit env var override .env per-key"
}

test_lib_dry_run_truthy_parsing() {
  local home="$TMP_ROOT/lib-dry"
  mkdir -p "$home"
  # shellcheck source=bin/fm-spectrum-lib.sh
  . "$ROOT/bin/fm-spectrum-lib.sh"
  for v in 1 true yes on anything; do
    FM_HOME="$home" SPECTRUM_SELF_HANDLE=x SPECTRUM_DRY_RUN="$v" spectrum_load_config
    [ "$SPECTRUM_DRY" = 1 ] || fail "SPECTRUM_DRY_RUN=$v must be truthy (got SPECTRUM_DRY=$SPECTRUM_DRY)"
  done
  for v in '' 0 false no off; do
    FM_HOME="$home" SPECTRUM_SELF_HANDLE=x SPECTRUM_DRY_RUN="$v" spectrum_load_config
    [ -z "$SPECTRUM_DRY" ] || fail "SPECTRUM_DRY_RUN=$v must be falsy (got SPECTRUM_DRY=$SPECTRUM_DRY)"
  done
  pass "spectrum_load_config parses SPECTRUM_DRY_RUN truthiness like FMX_DRY_RUN"
}

test_lib_configured_gate() {
  local home="$TMP_ROOT/lib-configured"
  mkdir -p "$home"
  # shellcheck source=bin/fm-spectrum-lib.sh
  . "$ROOT/bin/fm-spectrum-lib.sh"
  FM_HOME="$home" SPECTRUM_SELF_HANDLE='' spectrum_load_config
  spectrum_configured && fail "spectrum_configured must fail with no SPECTRUM_SELF_HANDLE"
  FM_HOME="$home" SPECTRUM_SELF_HANDLE=x spectrum_load_config
  spectrum_configured || fail "spectrum_configured must succeed once SPECTRUM_SELF_HANDLE is set"
  pass "spectrum_configured gates purely on SPECTRUM_SELF_HANDLE presence"
}

# ---------------------------------------------------------------------------
# fm-spectrum-notify.sh
# ---------------------------------------------------------------------------

test_notify_hard_noop_unconfigured() {
  local home="$TMP_ROOT/notify-noop"
  mkdir -p "$home"
  local out rc
  out=$(FM_HOME="$home" "$ROOT/bin/fm-spectrum-notify.sh" tharshan09@gmail.com "hello" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "notify unconfigured exit"
  [ -z "$out" ] || fail "notify unconfigured must print nothing on stdout (got: $out)"
  assert_absent "$home/state/spectrum-outbox" "notify unconfigured must not create an outbox"
  pass "fm-spectrum-notify is a hard no-op without SPECTRUM_SELF_HANDLE"
}

test_notify_dry_run_requires_activation_too() {
  local home="$TMP_ROOT/notify-dry-noop"
  mkdir -p "$home"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_DRY_RUN=1 "$ROOT/bin/fm-spectrum-notify.sh" tharshan09@gmail.com "hello" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "notify dry-run-but-unconfigured exit"
  [ -z "$out" ] || fail "dry-run alone must not activate spectrum (got: $out)"
  assert_absent "$home/state/spectrum-outbox" "dry-run without SPECTRUM_SELF_HANDLE must not create an outbox"
  pass "fm-spectrum-notify requires SPECTRUM_SELF_HANDLE even under SPECTRUM_DRY_RUN"
}

test_notify_dry_run_text_file_records_preview() {
  local home="$TMP_ROOT/notify-dry-file"
  mkdir -p "$home"
  printf 'PR is ready for review: https://example.test/pr/1' > "$home/msg.txt"
  local out rc id
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com \
    SPECTRUM_CAPTAIN_HANDLE=tharshan09@gmail.com SPECTRUM_DRY_RUN=1 \
    "$ROOT/bin/fm-spectrum-notify.sh" tharshan09@gmail.com --text-file "$home/msg.txt" 2>"$home/stderr.log"); rc=$?
  expect_code 0 "$rc" "notify dry-run text-file exit"
  id=$out
  [ -n "$id" ] || fail "notify dry-run must echo the generated message id"
  assert_present "$home/state/spectrum-outbox/$id.json" "notify dry-run must record an outbox preview"
  [ "$(jq -r .target "$home/state/spectrum-outbox/$id.json")" = "tharshan09@gmail.com" ] \
    || fail "outbox record must preserve the target"
  [ "$(jq -r .dry_run "$home/state/spectrum-outbox/$id.json")" = "true" ] \
    || fail "dry-run outbox record must carry dry_run:true"
  assert_grep "DRY RUN" "$home/stderr.log" "notify dry-run must print a DRY RUN summary to stderr"
  pass "fm-spectrum-notify --text-file dry-run records an outbox preview with no send"
}

test_notify_dry_run_stdin() {
  local home="$TMP_ROOT/notify-dry-stdin"
  mkdir -p "$home"
  local out rc id
  out=$(printf 'blocked: needs a decision on X vs Y' | FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com \
    SPECTRUM_CAPTAIN_HANDLE=tharshan09@gmail.com SPECTRUM_DRY_RUN=1 \
    "$ROOT/bin/fm-spectrum-notify.sh" tharshan09@gmail.com - 2>/dev/null); rc=$?
  expect_code 0 "$rc" "notify dry-run stdin exit"
  id=$out
  [ "$(jq -r .text "$home/state/spectrum-outbox/$id.json")" = "blocked: needs a decision on X vs Y" ] \
    || fail "stdin form must preserve message text"
  pass "fm-spectrum-notify - (stdin) records message text without shell interpolation"
}

test_notify_live_marks_outbox_not_dry() {
  local home="$TMP_ROOT/notify-live"
  mkdir -p "$home"
  local out rc id
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com \
    SPECTRUM_CAPTAIN_HANDLE=tharshan09@gmail.com \
    "$ROOT/bin/fm-spectrum-notify.sh" tharshan09@gmail.com "PR ready" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "notify live exit"
  id=$out
  [ "$(jq -r .dry_run "$home/state/spectrum-outbox/$id.json")" = "false" ] \
    || fail "live outbox record must carry dry_run:false"
  pass "fm-spectrum-notify without SPECTRUM_DRY_RUN writes a live (non-dry) outbox record"
}

test_notify_empty_text_rejected() {
  local home="$TMP_ROOT/notify-empty"
  mkdir -p "$home"
  : > "$home/empty.txt"
  local rc
  FM_HOME="$home" SPECTRUM_SELF_HANDLE=x SPECTRUM_CAPTAIN_HANDLE=y \
    "$ROOT/bin/fm-spectrum-notify.sh" target --text-file "$home/empty.txt" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "notify empty text-file exit"
  assert_absent "$home/state/spectrum-outbox" "empty message text must not be queued"
  pass "fm-spectrum-notify rejects empty message text"
}

test_notify_missing_text_file_errors() {
  local home="$TMP_ROOT/notify-missing-file"
  mkdir -p "$home"
  local rc
  FM_HOME="$home" SPECTRUM_SELF_HANDLE=x SPECTRUM_CAPTAIN_HANDLE=y \
    "$ROOT/bin/fm-spectrum-notify.sh" target --text-file "$home/does-not-exist.txt" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "notify must fail on a missing --text-file path"
  pass "fm-spectrum-notify errors clearly on a missing --text-file path"
}

test_notify_usage_errors() {
  local rc
  "$ROOT/bin/fm-spectrum-notify.sh" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "notify with no args exit"
  "$ROOT/bin/fm-spectrum-notify.sh" --target only-a-target >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "notify with --target but no text source exit"
  pass "fm-spectrum-notify reports usage errors for missing arguments"
}

test_notify_default_target_from_captain_handle_list() {
  local home="$TMP_ROOT/notify-default-target"
  mkdir -p "$home"
  local out rc id
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com \
    SPECTRUM_CAPTAIN_HANDLE='tharshan09@gmail.com,+12262246894' SPECTRUM_DRY_RUN=1 \
    "$ROOT/bin/fm-spectrum-notify.sh" "no explicit target given" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "notify default-target exit"
  id=$out
  [ "$(jq -r .target "$home/state/spectrum-outbox/$id.json")" = "tharshan09@gmail.com" ] \
    || fail "default target must be the first handle in SPECTRUM_CAPTAIN_HANDLE"
  [ "$(jq -r .text "$home/state/spectrum-outbox/$id.json")" = "no explicit target given" ] \
    || fail "a single bare argument must be treated as message text, not a target"
  pass "fm-spectrum-notify with a single bare argument defaults the target to the first captain handle"
}

test_notify_target_handle_overrides_captain_list_default() {
  local home="$TMP_ROOT/notify-target-override"
  mkdir -p "$home"
  local out rc id
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com \
    SPECTRUM_CAPTAIN_HANDLE='tharshan09@gmail.com,+12262246894' \
    SPECTRUM_TARGET_HANDLE='+12262246894' SPECTRUM_DRY_RUN=1 \
    "$ROOT/bin/fm-spectrum-notify.sh" "hi" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "notify SPECTRUM_TARGET_HANDLE exit"
  id=$out
  [ "$(jq -r .target "$home/state/spectrum-outbox/$id.json")" = "+12262246894" ] \
    || fail "SPECTRUM_TARGET_HANDLE must win over the first SPECTRUM_CAPTAIN_HANDLE entry"
  pass "fm-spectrum-notify honors SPECTRUM_TARGET_HANDLE as the default target"
}

test_notify_explicit_target_flag() {
  local home="$TMP_ROOT/notify-target-flag"
  mkdir -p "$home"
  local out rc id
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com \
    SPECTRUM_CAPTAIN_HANDLE='tharshan09@gmail.com,+12262246894' SPECTRUM_DRY_RUN=1 \
    "$ROOT/bin/fm-spectrum-notify.sh" --target +12262246894 "hi via phone" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "notify --target exit"
  id=$out
  [ "$(jq -r .target "$home/state/spectrum-outbox/$id.json")" = "+12262246894" ] \
    || fail "--target must override the default"
  pass "fm-spectrum-notify --target <handle> sends to the explicit handle"
}

test_notify_positional_target_backcompat() {
  local home="$TMP_ROOT/notify-positional-target"
  mkdir -p "$home"
  local out rc id
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com \
    SPECTRUM_CAPTAIN_HANDLE='tharshan09@gmail.com,+12262246894' SPECTRUM_DRY_RUN=1 \
    "$ROOT/bin/fm-spectrum-notify.sh" tharshan09@gmail.com "explicit positional target" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "notify positional target exit"
  id=$out
  [ "$(jq -r .target "$home/state/spectrum-outbox/$id.json")" = "tharshan09@gmail.com" ] \
    || fail "a positional target followed by text must still work (back-compat)"
  [ "$(jq -r .text "$home/state/spectrum-outbox/$id.json")" = "explicit positional target" ] \
    || fail "text after a positional target must be preserved"
  pass "fm-spectrum-notify <target> <text> (positional target) still works"
}

test_notify_no_default_target_available_errors() {
  local home="$TMP_ROOT/notify-no-default"
  mkdir -p "$home"
  local rc
  FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com SPECTRUM_DRY_RUN=1 \
    "$ROOT/bin/fm-spectrum-notify.sh" "hi" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "notify must fail when no target and no SPECTRUM_CAPTAIN_HANDLE are available"
  assert_absent "$home/state/spectrum-outbox" "notify must not queue anything with no resolvable target"
  pass "fm-spectrum-notify errors clearly when no target can be resolved"
}

# ---------------------------------------------------------------------------
# fm-spectrum-status.sh
# ---------------------------------------------------------------------------

test_status_disabled_when_unconfigured() {
  local home="$TMP_ROOT/status-disabled"
  mkdir -p "$home"
  local out rc
  out=$(FM_HOME="$home" "$ROOT/bin/fm-spectrum-status.sh"); rc=$?
  expect_code 0 "$rc" "status disabled exit"
  assert_contains "$out" "disabled" "status must report disabled when unconfigured"
  pass "fm-spectrum-status reports disabled (exit 0) when spectrum is not configured"
}

test_status_dead_when_configured_no_beacon() {
  local home="$TMP_ROOT/status-dead"
  mkdir -p "$home/state"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=x SPECTRUM_CAPTAIN_HANDLE=y "$ROOT/bin/fm-spectrum-status.sh"); rc=$?
  expect_code 1 "$rc" "status dead exit"
  assert_contains "$out" "dead" "status must report dead when configured but no beacon exists"
  pass "fm-spectrum-status reports dead (exit 1) when configured but the beacon is absent"
}

test_status_healthy_with_fresh_beacon() {
  local home="$TMP_ROOT/status-healthy"
  mkdir -p "$home/state"
  date +%s > "$home/state/.spectrum-bridge-beat"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=x SPECTRUM_CAPTAIN_HANDLE=y "$ROOT/bin/fm-spectrum-status.sh" --status); rc=$?
  expect_code 0 "$rc" "status healthy exit"
  assert_contains "$out" "healthy" "status must report healthy with a fresh beacon"
  pass "fm-spectrum-status reports healthy (exit 0) with a fresh beacon, and accepts --status"
}

test_status_stale_with_old_beacon() {
  local home="$TMP_ROOT/status-stale"
  mkdir -p "$home/state"
  touch -t 202001010000 "$home/state/.spectrum-bridge-beat"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=x SPECTRUM_CAPTAIN_HANDLE=y \
    SPECTRUM_BRIDGE_STALE_SECS=5 "$ROOT/bin/fm-spectrum-status.sh"); rc=$?
  expect_code 1 "$rc" "status stale exit"
  assert_contains "$out" "stale" "status must report stale with an old beacon"
  pass "fm-spectrum-status reports stale (exit 1) once the beacon exceeds the stale threshold"
}

# ---------------------------------------------------------------------------
# fm-spectrum-bridge (launcher gating; the Node process itself needs a live
# macOS Messages account and is out of scope for this hermetic suite)
# ---------------------------------------------------------------------------

test_bridge_hard_noop_unconfigured() {
  local home="$TMP_ROOT/bridge-noop"
  mkdir -p "$home"
  local out rc
  out=$(FM_HOME="$home" "$ROOT/bin/fm-spectrum-bridge" 2>&1); rc=$?
  expect_code 0 "$rc" "bridge unconfigured exit"
  [ -z "$out" ] || fail "bridge unconfigured must be silent (got: $out)"
  pass "fm-spectrum-bridge is a hard no-op without SPECTRUM_SELF_HANDLE"
}

test_bridge_requires_captain_allowlist() {
  local home="$TMP_ROOT/bridge-no-captain"
  mkdir -p "$home"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com "$ROOT/bin/fm-spectrum-bridge" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bridge must refuse to start without SPECTRUM_CAPTAIN_HANDLE"
  assert_contains "$out" "SPECTRUM_CAPTAIN_HANDLE" "bridge must explain the missing captain allowlist"
  pass "fm-spectrum-bridge refuses to start with self configured but no captain allowlist"
}

test_bridge_captain_allowlist_accepts_any_listed_handle() {
  command -v node >/dev/null 2>&1 || { pass "bridge allowlist unit test skipped (no node on PATH)"; return; }
  local out rc
  out=$(node -e '
    const m = require(process.argv[1]);
    const handles = m.parseHandleList("tharshan09@gmail.com, +12262246894 ,");
    const results = [
      m.isFromCaptain({ sender: { handle: "tharshan09@gmail.com" } }, handles),
      m.isFromCaptain({ sender: { handle: "+12262246894" } }, handles),
      m.isFromCaptain({ sender: { handle: "TharShan09@Gmail.com" } }, handles),
      m.isFromCaptain({ sender: { handle: "someone-else@example.com" } }, handles),
    ];
    console.log(JSON.stringify(results));
  ' "$ROOT/bin/spectrum-bridge/index.js" 2>&1); rc=$?
  expect_code 0 "$rc" "bridge allowlist unit test exit"
  [ "$out" = "[true,true,true,false]" ] \
    || fail "expected [true,true,true,false] for the two listed handles + a case-variant + a stranger (got: $out)"
  pass "fm-spectrum-bridge's inbound allowlist accepts any handle in a comma-separated SPECTRUM_CAPTAIN_HANDLE list"
}

test_bridge_resolves_real_space_accessor() {
  command -v node >/dev/null 2>&1 || { pass "bridge space-accessor unit test skipped (no node on PATH)"; return; }
  [ -d "$ROOT/bin/spectrum-bridge/node_modules/spectrum-ts" ] || {
    pass "bridge space-accessor unit test skipped (spectrum-ts is not installed in this checkout)"
    return
  }
  # Regression coverage for a live-smoke-test bug: resolvePlatformInstance()
  # used to guess app.im.space.get / app.space.get, neither of which exists on
  # a real Spectrum() app instance, so every outbound send silently failed
  # before ever reaching osascript. This exercises the fix against the REAL
  # installed spectrum-ts + @spectrum-ts/imessage (constructing a genuine
  # local-mode app and resolving a real space), so a future spectrum-ts
  # upgrade that changes this API surface fails a test instead of a live send.
  # It deliberately stops short of space.send() - that needs a live Messages.app
  # window and is covered by the live smoke test, not this hermetic suite.
  local out rc
  out=$(cd "$ROOT/bin/spectrum-bridge" && node -e '
    const { Spectrum } = require("spectrum-ts");
    const { imessage } = require("@spectrum-ts/imessage");
    const { resolvePlatformInstance } = require("./index.js");
    (async () => {
      const app = await Spectrum({ providers: [imessage.config({ local: true })] });
      try {
        const platformInstance = resolvePlatformInstance(app, imessage);
        const space = await platformInstance.space.create("+12262246894");
        console.log(JSON.stringify({
          hasCreate: typeof platformInstance.space.create,
          hasGet: typeof platformInstance.space.get,
          spaceId: space.id,
          hasSend: typeof space.send,
        }));
      } finally {
        await app.stop();
      }
    })().catch((e) => { console.error("ERR " + e.message); process.exit(1); });
  ' 2>&1); rc=$?
  expect_code 0 "$rc" "bridge space-accessor unit test exit"
  local parsed
  parsed=$(printf '%s\n' "$out" | grep '"hasCreate"')
  [ "$(printf '%s' "$parsed" | jq -r .hasCreate)" = "function" ] \
    || fail "resolvePlatformInstance must return a PlatformInstance with a real space.create (got: $out)"
  [ "$(printf '%s' "$parsed" | jq -r .hasGet)" = "function" ] \
    || fail "resolvePlatformInstance must return a PlatformInstance with a real space.get (got: $out)"
  [ "$(printf '%s' "$parsed" | jq -r .hasSend)" = "function" ] \
    || fail "the resolved space must carry a real send() (got: $out)"
  [ "$(printf '%s' "$parsed" | jq -r .spaceId)" = "any;-;+12262246894" ] \
    || fail "resolved space id must match spectrum-ts's own id scheme for the handle (got: $out)"
  pass "fm-spectrum-bridge's resolvePlatformInstance resolves a real, working space accessor against installed spectrum-ts"
}

test_bridge_fails_gracefully_when_dependencies_missing() {
  command -v node >/dev/null 2>&1 || { pass "fm-spectrum-bridge dependency-missing check skipped (no node on PATH)"; return; }
  [ ! -d "$ROOT/bin/spectrum-bridge/node_modules/spectrum-ts" ] || {
    pass "fm-spectrum-bridge dependency-missing check skipped (spectrum-ts is installed in this checkout)"
    return
  }
  local home="$TMP_ROOT/bridge-no-deps"
  mkdir -p "$home"
  local out rc
  out=$(FM_HOME="$home" SPECTRUM_SELF_HANDLE=lily.lotuscloud@gmail.com \
    SPECTRUM_CAPTAIN_HANDLE=tharshan09@gmail.com "$ROOT/bin/fm-spectrum-bridge" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bridge must exit non-zero when spectrum-ts is not installed"
  assert_contains "$out" "npm install" "bridge must tell the operator how to install its dependencies"
  assert_absent "$home/state/.spectrum-bridge-beat" "bridge must not claim liveness before it can actually start"
  pass "fm-spectrum-bridge fails gracefully (clear message, exit 1) when spectrum-ts is not installed"
}

# ---------------------------------------------------------------------------

test_lib_env_get_reads_last_assignment
test_lib_load_config_env_wins_over_dotenv
test_lib_dry_run_truthy_parsing
test_lib_configured_gate
test_notify_hard_noop_unconfigured
test_notify_dry_run_requires_activation_too
test_notify_dry_run_text_file_records_preview
test_notify_dry_run_stdin
test_notify_live_marks_outbox_not_dry
test_notify_empty_text_rejected
test_notify_missing_text_file_errors
test_notify_usage_errors
test_notify_default_target_from_captain_handle_list
test_notify_target_handle_overrides_captain_list_default
test_notify_explicit_target_flag
test_notify_positional_target_backcompat
test_notify_no_default_target_available_errors
test_status_disabled_when_unconfigured
test_status_dead_when_configured_no_beacon
test_status_healthy_with_fresh_beacon
test_status_stale_with_old_beacon
test_bridge_hard_noop_unconfigured
test_bridge_requires_captain_allowlist
test_bridge_captain_allowlist_accepts_any_listed_handle
test_bridge_resolves_real_space_accessor
test_bridge_fails_gracefully_when_dependencies_missing
