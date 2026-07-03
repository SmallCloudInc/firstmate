#!/usr/bin/env bash
# Behavior tests for the no-mistakes gate pre-push stopgap and its bundled
# gitignore parity fix.
#
# Change 1: bin/fm-brief.sh's no-mistakes-mode Definition-of-done must instruct
# the crewmate to run a plain `git push no-mistakes fm/<id>` before its first
# `no-mistakes axi run`, working around a confirmed no-mistakes bug where axi
# run's own internal push is rejected (it runs with a corrupted PWD, so the
# gate derives an invalid path and never creates a run row). direct-PR and
# scout briefs never touch the gate, so they must NOT carry this step.
#
# Change 2: config/spectrum-mode.env (fm-spectrum's generated cadence file,
# mirroring config/x-mode.env) must be gitignored identically, so it never
# shows up as an untracked file dirtying the tree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gate-prepush-stopgap-tests)

# --- Change 1: fm-brief.sh no-mistakes DoD pre-push step --------------------

test_no_mistakes_brief_has_prepush_step() {
  local home="$TMP_ROOT/no-mistakes-brief"
  mkdir -p "$home/data"
  printf -- '- widgets [no-mistakes] - a widget factory (added 2026-01-01)\n' > "$home/data/projects.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" nm-task-a1 widgets >/dev/null

  local brief="$home/data/nm-task-a1/brief.md"
  assert_present "$brief" "fm-brief.sh must scaffold a brief for a no-mistakes project"
  assert_grep "git push no-mistakes fm/nm-task-a1" "$brief" \
    "no-mistakes DoD must instruct a plain push of the interpolated branch to the no-mistakes remote"
  assert_grep "Before your first" "$brief" \
    "the pre-push step must be sequenced before the first no-mistakes axi run"
  pass "fm-brief.sh no-mistakes DoD includes the gate pre-push stopgap with the real task id interpolated"
}

test_direct_pr_brief_omits_prepush_step() {
  local home="$TMP_ROOT/direct-pr-brief"
  mkdir -p "$home/data"
  printf -- '- widgets [direct-PR] - a widget factory (added 2026-01-01)\n' > "$home/data/projects.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" dp-task-a2 widgets >/dev/null

  local brief="$home/data/dp-task-a2/brief.md"
  assert_present "$brief" "fm-brief.sh must scaffold a brief for a direct-PR project"
  assert_no_grep "git push no-mistakes" "$brief" \
    "direct-PR briefs never touch the gate and must not carry the pre-push stopgap"
  pass "fm-brief.sh direct-PR DoD omits the gate pre-push stopgap"
}

test_scout_brief_omits_prepush_step() {
  local home="$TMP_ROOT/scout-brief"
  mkdir -p "$home/data"
  printf -- '- widgets [no-mistakes] - a widget factory (added 2026-01-01)\n' > "$home/data/projects.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-brief.sh" sc-task-a3 widgets --scout >/dev/null

  local brief="$home/data/sc-task-a3/brief.md"
  assert_present "$brief" "fm-brief.sh must scaffold a brief for a scout task"
  assert_no_grep "git push no-mistakes" "$brief" \
    "scout briefs never touch the gate and must not carry the pre-push stopgap"
  pass "fm-brief.sh scout DoD omits the gate pre-push stopgap"
}

# --- Change 2: gitignore parity for config/spectrum-mode.env ----------------

test_gitignore_covers_spectrum_mode_env() {
  local repo="$TMP_ROOT/gitignore-repo"
  mkdir -p "$repo/config"
  git init -q "$repo"
  cp "$ROOT/.gitignore" "$repo/.gitignore"
  : > "$repo/config/spectrum-mode.env"

  local out rc
  out=$(cd "$repo" && git check-ignore config/spectrum-mode.env); rc=$?
  expect_code 0 "$rc" "git check-ignore exit for config/spectrum-mode.env"
  assert_contains "$out" "config/spectrum-mode.env" "git check-ignore must report the matched path"
  pass "config/spectrum-mode.env is gitignored identically to config/x-mode.env"
}

test_gitignore_lists_spectrum_mode_env_next_to_x_mode_env() {
  assert_grep "config/spectrum-mode.env" "$ROOT/.gitignore" \
    ".gitignore must list config/spectrum-mode.env"
  local line
  line=$(grep -n "^config/x-mode.env$" "$ROOT/.gitignore" | cut -d: -f1)
  [ -n "$line" ] || fail ".gitignore must still list config/x-mode.env"
  local next
  next=$(sed -n "$((line + 1))p" "$ROOT/.gitignore")
  [ "$next" = "config/spectrum-mode.env" ] || \
    fail "config/spectrum-mode.env must sit right next to config/x-mode.env (got next line: $next)"
  pass "config/spectrum-mode.env is placed directly after config/x-mode.env in .gitignore"
}

# ---------------------------------------------------------------------------

test_no_mistakes_brief_has_prepush_step
test_direct_pr_brief_omits_prepush_step
test_scout_brief_omits_prepush_step
test_gitignore_covers_spectrum_mode_env
test_gitignore_lists_spectrum_mode_env_next_to_x_mode_env
