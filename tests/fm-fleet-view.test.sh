#!/usr/bin/env bash
# Behavior tests for the captain sidebar rendering of bin/fm-fleet-view.sh.
#
# The wide Markdown rendering and the snapshot contract it consumes are covered
# by tests/fm-fleet-snapshot-view.test.sh; this file owns the needs-you-first
# sidebar: classification, age, the read-only guarantee, and the watch loop.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-view)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TODAY=2026-08-10

# Renders are compared as plain text, and the fixture pane width is fixed so a
# wrap regression is visible rather than terminal-dependent.
view() {  # <home> [args...]
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" NO_COLOR=1 FM_FLEET_VIEW_WIDTH=40 FM_FLEET_VIEW_TODAY="$TODAY" \
    FM_HOME="$home" "$VIEW" "$@"
}

# Classification assertions read the render with its narrow-pane wrapping undone,
# so a headline's wording is tested independently of where the pane folds it.
# A continuation line is exactly the two-space hanging indent, never an action
# line, which carries the copyable marker at that same indent.
unwrap() {
  awk '
    NR > 1 && substr($0, 1, 2) == "  " && index($0, "\342\206\263") != 3 {
      printf " %s", substr($0, 3); next
    }
    NR > 1 { printf "\n" }
    { printf "%s", $0 }
    END { if (NR > 0) printf "\n" }
  '
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects"
  printf '%s\n' "$home"
}

# One fake terminal for every fixture: a task whose id contains "gone" has no
# endpoint, which is how a worker that stopped responding is modeled.
make_fakebin() {
  local fb
  fb=$(fm_fakebin "$TMP_ROOT/fakebin")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta 2>/dev/null ;;
  display-message)
    case "$target" in
      *gone*) exit 1 ;;
    esac
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *gone*) exit 1 ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}
FAKEBIN=$(make_fakebin)

# A crew's current state comes from its semantic busy record (bin/fm-busy-lib.sh),
# and only an idle record lets the declared status event decide the state.
record_idle() {  # <home> <id>
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1/state" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1/state" "$2" idle --gen "$gen" \
    --source claude-hook --event stop > /dev/null
}

record_busy() {  # <home> <id>
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1/state" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1/state" "$2" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit > /dev/null
}

add_task() {  # <home> <id> <mode> <kind> <status-line> [extra-meta...]
  local home=$1 id=$2 mode=$3 kind=$4 status=$5
  shift 5
  mkdir -p "$home/projects/$id"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/$id" \
    "project=$home/projects/$id" \
    "harness=claude" \
    "kind=$kind" \
    "mode=$mode" \
    "yolo=off" \
    "$@"
  printf '%s\n' "$status" > "$home/state/$id.status"
}

test_empty_fleet_is_all_quiet() {
  local home out
  home=$(make_home empty)
  out=$(view "$home")
  expect_code 0 "$?" "an empty fleet must still render successfully"
  assert_contains "$out" "All quiet" "an empty fleet should say all quiet"
  assert_contains "$out" "0 tasks" "an empty fleet should count zero tasks"
  assert_not_contains "$out" "NEEDS YOU" "an empty fleet should print no sections"
  pass "empty fleet renders a short all-quiet view and exits 0"
}

test_needs_you_classification() {
  local home out
  home=$(make_home needs)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] 3412 - contracts (repo: alpha) (kind: ship) (since 2026-08-09)
- [ ] 1905 - pane-naming (repo: alpha) (kind: ship) (since 2026-08-09)
- [ ] 7002 - vault sync (repo: alpha) (kind: ship) (since 2026-08-10)
- [ ] 7009gone - lost worker (repo: alpha) (kind: ship) (since 2026-08-10)
EOF
  add_task "$home" 3412 ship ship 'needs-decision: [key=api-shape] pick REST or gRPC'
  add_task "$home" 1905 ship ship 'done: PR is up' \
    "pr=https://github.com/kunchenguid/firstmate/pull/1905"
  add_task "$home" 7002 local-only ship 'done: ready branch'
  add_task "$home" 7009gone ship ship 'working: mid-implementation'
  record_idle "$home" 3412
  record_idle "$home" 1905
  record_idle "$home" 7002
  record_idle "$home" 7009gone

  out=$(view "$home" | unwrap)
  assert_contains "$out" "NEEDS YOU (4)" "all four captain-actionable tasks belong in NEEDS YOU"

  assert_contains "$out" "3412 contracts — decision: pick REST or gRPC" \
    "an open decision should surface with its question"
  assert_not_contains "$out" "key=api-shape" \
    "the internal decision key must not reach the captain surface"

  assert_contains "$out" "PR #1905 pane-naming — checks green" \
    "a task holding a PR should read as awaiting the merge word"
  assert_contains "$out" "https://github.com/kunchenguid/firstmate/pull/1905" \
    "a PR entry must carry its full URL, never a bare number"

  assert_contains "$out" "7002 vault sync — ready to review on" \
    "a finished local-only task should read as ready to review"
  assert_contains "$out" "bin/fm-review-diff.sh 7002" \
    "a local-only entry must carry a runnable review command"

  assert_contains "$out" "worker stopped responding" \
    "a task whose worker is gone must be surfaced, not repaired"
  pass "needs-you covers open decisions, PR merge word, local-only review, and a gone worker"
}

# A real backlog title is a body, not a label. This one reproduces the live
# 2026-08-11 render, where a single needs-you entry printed its whole title -
# a status dump of PR verdicts, findings, and file paths - and pushed every
# later entry off a short pane.
LONG_TITLE='review pr2909 add po to ap. VERDICT: pass with 4 findings; finding 1: bin/fm-fleet-view.sh line 168 renders the full backlog title; finding 2: docs/fleet-view.md does not describe the entry format; finding 3: tests/fm-fleet-view.test.sh has no long-title fixture; finding 4: state/2909.status carries the verdict body verbatim. Reviewed heads: 3f1a2b9 against origin/main, checks green, awaiting merge word from the captain.'

test_long_title_stays_glanceable() {
  local home out over
  home=$(make_home longtitle)
  {
    printf '## In flight\n'
    printf -- '- [ ] 2909 - %s (repo: alpha) (kind: ship) (since 2026-08-11)\n' "$LONG_TITLE"
    printf -- '- [ ] 7002 - vault sync (repo: alpha) (kind: ship) (since 2026-08-11)\n'
  } > "$home/data/backlog.md"
  add_task "$home" 2909 ship ship 'done: PR is up' \
    "pr=https://github.com/ecloin/firstmate/pull/2909"
  add_task "$home" 7002 local-only ship 'done: ready branch'
  record_idle "$home" 2909
  record_idle "$home" 7002

  out=$(view "$home" | unwrap)
  assert_contains "$out" "NEEDS YOU (2)" "both finished tasks are waiting on the captain"

  # Every entry headline stays within the renderer's cap, which is about two
  # wrapped lines at this pane width. The two-character section glyph and its
  # space are the only allowance on top of it.
  over=$(printf '%s\n' "$out" | grep '^[●◐○✓] ' | jq -Rr 'select(length > 84) | "\(length): \(.)"')
  [ -z "$over" ] || fail "an entry headline must stay within the sidebar cap: $over"

  assert_contains "$out" "PR #2909 review pr2909 add po to ap…" \
    "a long title should clip to its first sentence with a single ellipsis"
  assert_not_contains "$out" "VERDICT" "a verdict body must never reach the sidebar"
  assert_not_contains "$out" "finding 2" "a finding list must never reach the sidebar"
  assert_not_contains "$out" "bin/fm-fleet-view.sh" "a file path from a title must never reach the sidebar"

  assert_contains "$out" "7002 vault sync" \
    "a clipped first entry must leave the second needs-you entry on the pane"

  # The action line is deliberately outside every budget: a clipped command is
  # worse than a long one, so both survive whole and unwrapped.
  assert_contains "$out" "https://github.com/ecloin/firstmate/pull/2909" \
    "a PR URL must survive unclipped even when the entry was clipped"
  assert_contains "$out" "bin/fm-review-diff.sh 7002" \
    "a review command must survive unclipped"
  pass "a multi-hundred-character title clips to a glanceable entry without hiding the next one"
}

test_long_title_clipping_covers_every_section() {
  local home out over
  home=$(make_home longtitle-sections)
  {
    printf '## In flight\n'
    printf -- '- [ ] 3406 - %s (repo: alpha) (kind: ship) (since 2026-08-11)\n' "$LONG_TITLE"
    printf -- '- [ ] 7001 - %s (repo: alpha) (kind: ship) (since 2026-08-11)\n' "$LONG_TITLE"
    printf '## Done\n'
    printf -- '- [x] 3410 - %s (repo: alpha) (kind: ship) (merged %s)\n' "$LONG_TITLE" "$TODAY"
  } > "$home/data/backlog.md"
  add_task "$home" 3406 ship ship 'working: rebasing onto the new base'
  add_task "$home" 7001 ship ship 'paused: upstream release lands Thursday'
  record_busy "$home" 3406
  record_idle "$home" 7001

  out=$(view "$home" | unwrap)
  assert_contains "$out" "IN FLIGHT (1)" "the working task belongs in flight"
  assert_contains "$out" "WAITING (1)" "the declared wait belongs in waiting"
  assert_contains "$out" "DONE TODAY (1)" "the landed work belongs in done today"
  over=$(printf '%s\n' "$out" | grep '^[●◐○✓] ' | jq -Rr 'select(length > 84) | "\(length): \(.)"')
  [ -z "$over" ] || fail "every section must clip its entries, not only NEEDS YOU: $over"
  assert_not_contains "$out" "VERDICT" "no section may render a verdict body"
  pass "in-flight, waiting, and done-today entries clip the same way as needs-you"
}

test_in_flight_shows_age() {
  local home out
  home=$(make_home flight)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] 3406 - merge-strategy (repo: alpha) (kind: ship) (since 2026-08-10)
EOF
  add_task "$home" 3406 ship ship 'working: rebasing onto the new base'
  record_busy "$home" 3406
  touch -d '45 minutes ago' "$home/state/3406.status"

  out=$(view "$home" | unwrap)
  assert_contains "$out" "IN FLIGHT (1)" "a working task belongs in flight"
  assert_contains "$out" "3406 merge-strategy — working 45m" \
    "in-flight work should render a humanized age"
  assert_not_contains "$out" "NEEDS YOU" "work under way must not be reported as needing the captain"
  pass "in-flight work renders with a humanized age"
}

test_paused_and_scout_wait() {
  local home out
  home=$(make_home waiting)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] 7001 - release gate (repo: alpha) (kind: ship) (since 2026-08-10)
- [ ] 2909 - review scout (repo: alpha) (kind: scout) (since 2026-08-08)
EOF
  add_task "$home" 7001 ship ship 'paused: upstream release lands Thursday'
  add_task "$home" 2909 scout scout 'needs-decision: two options for the rollout'
  mkdir -p "$home/data/2909"
  printf '# findings\n' > "$home/data/2909/report.md"
  record_idle "$home" 7001
  record_idle "$home" 2909

  out=$(view "$home" | unwrap)
  assert_contains "$out" "WAITING (2)" "a declared wait and a delivered report both wait"
  assert_contains "$out" "7001 release gate — upstream release lands Thursday" \
    "a declared external wait should render its reason"
  assert_contains "$out" "2909 review scout — report ready, decisions open" \
    "a delivered report with open decisions waits rather than paging the captain"
  assert_not_contains "$out" "NEEDS YOU" "neither entry should be reported as needing the captain"
  pass "declared waits and delivered-report scouts render as WAITING"
}

test_done_today_filters_by_date() {
  local home out
  home=$(make_home done-today)
  cat > "$home/data/backlog.md" <<'EOF'
## Done
- [x] 3410 - re-verify (repo: alpha) (kind: ship) (merged 2026-08-10)
- [x] 3409 - last week's work (repo: alpha) (kind: ship) (merged 2026-08-01)
EOF
  out=$(view "$home" | unwrap)
  assert_contains "$out" "DONE TODAY (1)" "only today's landed work counts as done today"
  assert_contains "$out" "3410 re-verify" "today's landed work should be listed"
  assert_not_contains "$out" "last week" "older landed work must not appear"
  pass "done-today lists only work that landed today"
}

test_render_writes_nothing() {
  local home before after
  home=$(make_home readonly)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] 3412 - contracts (repo: alpha) (kind: ship) (since 2026-08-09)
EOF
  add_task "$home" 3412 ship ship 'needs-decision: pick a shape'
  record_idle "$home" 3412

  # Baseline AFTER the fixture is fully built, so only the render is measured.
  before=$(find "$home" -printf '%p|%y|%s|%T@\n' | sort)
  view "$home" > /dev/null
  view "$home" --wide > /dev/null
  after=$(find "$home" -printf '%p|%y|%s|%T@\n' | sort)
  [ "$before" = "$after" ] || {
    printf '%s\n' "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)" >&2
    fail "rendering the fleet must not create, remove, or touch any file in the home"
  }
  pass "a render performs no writes anywhere in the home"
}

test_watch_redraws_and_exits_on_interrupt() {
  local home out rc
  home=$(make_home watch)
  out=$TMP_ROOT/watch.out
  # The loop must run in the FOREGROUND to be interruptible at all: a shell
  # ignores SIGINT in the jobs it backgrounds, and a disposition inherited as
  # ignored can no longer be trapped, so a backgrounded run would prove nothing.
  # A helper interrupts it by pid once it is up.
  ( sleep 3; pkill -INT -P $$ -f 'fm-fleet-view\.sh --watch' ) &
  PATH="$FAKEBIN:$PATH" NO_COLOR=1 FM_FLEET_VIEW_WIDTH=40 FM_FLEET_VIEW_TODAY="$TODAY" \
    FM_HOME="$home" timeout 20 "$VIEW" --watch 1 > "$out" 2>&1
  rc=$?
  wait
  expect_code 0 "$rc" "an interrupted watch loop must exit cleanly"
  [ "$(grep -c 'FLEET' "$out")" -ge 2 ] \
    || fail "a watch loop should redraw at least twice in three seconds at a 1s interval"
  pass "watch redraws on its interval and exits cleanly on interrupt"
}

test_watch_rejects_a_bad_interval() {
  local home out rc
  home=$(make_home badinterval)
  out=$(view "$home" --watch nonsense 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a non-numeric refresh interval must be refused"
  assert_contains "$out" "whole number" "the refusal should name the concrete requirement"
  pass "an invalid refresh interval is refused rather than silently defaulted"
}

test_missing_backlog_still_renders_live_work() {
  local home out
  home=$(make_home nobacklog)
  add_task "$home" 3412 ship ship 'working: no backlog entry exists'
  record_busy "$home" 3412
  out=$(view "$home")
  expect_code 0 "$?" "an absent backlog must not crash the render"
  assert_contains "$out" "3412" "a task with no backlog title should still render by its number"
  pass "an absent backlog degrades to task numbers instead of failing"
}

test_narrow_pane_never_overflows() {
  local home wide
  home=$(make_home narrow)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] 3412 - a deliberately long work item title that will not fit a narrow pane (repo: alpha) (kind: ship) (since 2026-08-09)
EOF
  add_task "$home" 3412 ship ship 'needs-decision: choose between the queue-backed design and the direct call path'
  record_idle "$home" 3412

  # Width is counted in characters, not bytes: the section glyphs and the em
  # dash are multibyte, so a byte-counting wrap folds a 40-column pane early.
  # jq measures codepoints regardless of locale, which awk and wc do not.
  wide=$(view "$home" | jq -Rr 'select(length > 40) | "\(length): \(.)"')
  [ -z "$wide" ] || fail "no rendered line may exceed the pane width: $wide"
  pass "a narrow pane wraps prose without overflowing its width"
}

test_empty_fleet_is_all_quiet
test_needs_you_classification
test_narrow_pane_never_overflows
test_long_title_stays_glanceable
test_long_title_clipping_covers_every_section
test_in_flight_shows_age
test_paused_and_scout_wait
test_done_today_filters_by_date
test_render_writes_nothing
test_watch_redraws_and_exits_on_interrupt
test_watch_rejects_a_bad_interval
test_missing_backlog_still_renders_live_work
