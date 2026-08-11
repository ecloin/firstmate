#!/usr/bin/env bash
# fm-fleet-view.sh - human renderer over fm-fleet-snapshot.sh.
#
# Two renderings, one data source. The default is the captain sidebar: a narrow
# needs-you-first surface for a split pane beside a firstmate session. `--wide`
# keeps the original Markdown table rendering for a full-width read.
#
# This command intentionally does not parse fleet state itself.
# It shells out to fm-fleet-snapshot.sh --json and renders that stable
# structured contract for humans.
#
# Read-only: it acquires no lock, drains no wakes, arms no watcher, sends to no
# worker, and writes nothing under state/ or data/. It is safe to run in a loop
# beside a live session and watcher. See docs/fleet-view.md.
#
# Usage:
#   fm-fleet-view.sh                 captain sidebar, rendered once
#   fm-fleet-view.sh --watch [secs]  redraw loop, default 5s, Ctrl-C to stop
#   fm-fleet-view.sh --wide          full-width Markdown tables
#   fm-fleet-view.sh --json          the underlying snapshot
#
# WezTerm split pane:
#   wezterm cli split-pane --right --percent 30 -- \
#     wsl bash -lc 'cd <fm home> && bin/fm-fleet-view.sh --watch'
#
# Environment:
#   NO_COLOR                 set to any value to disable ANSI color.
#   FM_FLEET_VIEW_WIDTH      render width; defaults to the terminal width, or 40.
#   FM_FLEET_VIEW_TODAY      YYYY-MM-DD used for "DONE TODAY"; defaults to today.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-fleet-view.sh [--watch [seconds]] [--wide] [--json]

Render the fleet from fm-fleet-snapshot.sh.
Default is the narrow captain sidebar, needs-you first.
  --watch [seconds]  redraw loop (default 5s); Ctrl-C exits.
  --wide             full-width Markdown tables.
  --json             print the underlying snapshot.
EOF
}

MODE=sidebar
INTERVAL=5

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) shift; [ $# -eq 0 ] || { usage >&2; exit 2; }
          "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; exit $? ;;
  --wide) MODE=wide; shift ;;
  --watch)
    MODE=watch; shift
    if [ $# -gt 0 ]; then
      INTERVAL=$1; shift
      case "$INTERVAL" in
        ''|*[!0-9]*) echo "fm-fleet-view: refresh seconds must be a whole number" >&2; exit 2 ;;
      esac
      [ "$INTERVAL" -ge 1 ] || { echo "fm-fleet-view: refresh seconds must be at least 1" >&2; exit 2; }
    fi
    ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
[ $# -eq 0 ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-view: jq is not installed" >&2; exit 1; }

# Color is opt-out (NO_COLOR) and only ever applies to a terminal, so a piped or
# captured render stays plain text.
COLOR=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then COLOR=1; fi

C_HEAD='1'
C_NEEDS='33'
C_FLIGHT='32'
C_WAIT='2'
C_DONE='2'
C_WARN='31'

resolve_width() {
  local w=${FM_FLEET_VIEW_WIDTH:-}
  if [ -z "$w" ] && [ -t 1 ]; then w=$(tput cols 2>/dev/null || true); fi
  case "$w" in ''|*[!0-9]*) w=40 ;; esac
  [ "$w" -ge 24 ] || w=24
  [ "$w" -le 100 ] || w=100
  printf '%s\n' "$w"
}

paint() {  # <ansi-code> <text>
  if [ "$COLOR" = 1 ]; then printf '\033[%sm%s\033[0m\n' "$1" "$2"; else printf '%s\n' "$2"; fi
}

# Frame buffer of "<ansi-code>\t<wrap>\t<text>" lines. Wrapping and coloring
# happen once at flush time so a slow render never paints a half-drawn pane.
FRAME=''

emit() {  # <ansi-code> <indent> <text>
  FRAME="$FRAME$1"$'\t1\t'"$2$3"$'\n'
}

# A command or URL the captain copies is never folded: it goes out whole and
# lets the terminal soft-wrap it, so a double-click still selects all of it.
emit_copyable() {  # <ansi-code> <indent> <text>
  FRAME="$FRAME$1"$'\t0\t'"$2$3"$'\n'
}

# Wrap on codepoints, not bytes: the glyphs and the em dash are multibyte, and a
# byte-counting wrap folds a 40-column line several characters early. A word
# longer than the line (a PR URL) is left whole so it stays copyable.
# shellcheck disable=SC2016 # jq owns every $ expression in this literal program.
WRAP='
  def wrap($w):
    (capture("^(?<ind>[ ]*)(?<rest>.*)$")) as $m
    | (($w - ($m.ind | length)) | if . < 8 then 8 else . end) as $first
    # Continuation lines carry the two-space hanging indent below, so their own
    # budget is that much smaller or they overrun the pane by exactly that much.
    | (($first - 2) | if . < 8 then 8 else . end) as $rest
    | ($m.rest | split(" ") | map(select(. != "")))
    | (if length == 0 then [""] else
        reduce .[] as $word ([];
          if length == 0 then [$word]
          else (if length == 1 then $first else $rest end) as $budget
            | if ((.[-1] | length) + 1 + ($word | length)) <= $budget
              then .[0:-1] + ["\(.[-1]) \($word)"]
              else . + [$word] end
          end)
       end)
    # Continuation lines hang under the entry glyph so one entry reads as one
    # block in a narrow pane.
    | to_entries | map($m.ind + (if .key == 0 then "" else "  " end) + .value)[];
  (split("\t")) as $p
  | ($p[0]) as $code
  | ($p[1]) as $do_wrap
  | ($p[2:] | join("\t")) as $text
  | (if $do_wrap == "0" then $text else ($text | wrap($w)) end)
  | "\($code)\t\(.)"
'

flush_frame() {
  local code text
  [ -n "$FRAME" ] || return 0
  while IFS=$'\t' read -r code text; do
    paint "$code" "$text"
  done < <(printf '%s' "$FRAME" | jq -Rr --argjson w "$WIDTH" "$WRAP")
  FRAME=''
}

# Classify every live task and today's landed work into one flat record stream:
# "<section>\t<headline>\t<action>". All classification lives here so the shell
# below only formats, colors, and wraps.
# shellcheck disable=SC2016 # jq owns every $ expression in this literal program.
CLASSIFY='
  def clean: (. // "") | tostring | gsub("[\\t\\r\\n]"; " ") | gsub("  +"; " ")
    | sub("^ +"; "") | sub(" +$"; "");
  # A decision carries an internal routing key; the captain reads the question.
  def unkey: sub("^\\[key=[^]]*\\] *"; "");
  # One glance-sized line each: a runaway note must not push the pane around.
  def cap($n): if (length > $n) then (.[0:$n - 1] + "…") else . end;
  def humanize($s):
    if $s == null then "a moment"
    elif $s < 60 then "\($s)s"
    elif $s < 3600 then "\(($s / 60) | floor)m"
    elif $s < 86400 then "\(($s / 3600) | floor)h"
    else "\(($s / 86400) | floor)d" end;
  def short($t): ($t.backlog.title // "") | clean;
  def name($t):
    short($t) as $s
    | if $s == "" then ($t.id | tostring) else "\($t.id) \($s)" end;
  def pr_name($t; $url):
    ($url | capture("/pull/(?<n>[0-9]+)") | .n) as $n
    | short($t) as $s
    | if $n == null then name($t)
      elif $s == "" then "PR #\($n) \($t.id)"
      else "PR #\($n) \($s)" end;
  def age($t): humanize($t.paths.status_log.age_seconds);
  def decisions($t): ($t.hints.open_decisions // []);
  def decision_line($t):
    (decisions($t)) as $d
    | ($d | map(select(.verb == "blocked")) | first) as $blocked
    | (($blocked // $d[0]).summary | clean | unkey | cap(90)) as $note
    | if $blocked != null then
        (if $note == "" then "blocked, needs your help" else "blocked: \($note)" end)
      else
        (if $note == "" then "a decision is waiting on you" else "decision: \($note)" end)
      end;
  def row($section; $headline; $action): "\($section)\t\($headline | clean)\t\($action | clean)";

  ([.tasks[]?
    | . as $t
    | ($t.current_state.state // "unknown") as $state
    | ($t.kind // "ship") as $kind
    | ($t.mode // "") as $mode
    | ($t.pr.url) as $pr
    | ((decisions($t) | length) > 0) as $open
    | ($t.hints.scout_report_present == true) as $report
    | (($state == "done") or ($state == "failed")) as $terminal
    | ($t.endpoint.exists == false) as $endpoint_gone
    | if $kind == "secondmate" then
        # A second mate is persistent and idles by design, so it earns a line
        # only when it is actually holding something for the captain.
        (if $open then row("NEEDS"; "\(name($t)) — \(decision_line($t))"; "") else empty end)
      elif $endpoint_gone and ($terminal | not) then
        row("NEEDS"; "\(name($t)) — worker stopped responding"; "")
      elif $report and $open then
        row("WAIT"; "\(name($t)) — report ready, decisions open"; $t.paths.report.path // "")
      elif $open then
        row("NEEDS"; "\(name($t)) — \(decision_line($t))"; "")
      elif $terminal and ($pr != null) then
        row("NEEDS"; "\(pr_name($t; $pr)) — checks green, awaiting merge word"; $pr)
      elif $terminal and ($mode == "local-only") then
        row("NEEDS"; "\(name($t)) — ready to review on your local copy"; $t.actions.review // "")
      elif $terminal and $report then
        row("NEEDS"; "\(name($t)) — investigation finished, findings ready"; $t.paths.report.path // "")
      elif $state == "failed" then
        row("NEEDS"; "\(name($t)) — work failed"; "")
      elif $terminal then
        row("WAIT"; "\(name($t)) — finished, wrapping up"; "")
      elif $state == "paused" then
        ((($t.hints.last_event_text | clean | sub("^[a-z-]+: *"; "") | unkey | cap(70))) as $why
         | row("WAIT"; "\(name($t)) — \(if $why == "" then "waiting on something outside" else $why end)"; ""))
      elif $state == "working" then
        row("FLIGHT"; "\(name($t)) — working \(age($t))"; "")
      else
        row("FLIGHT"; "\(name($t)) — under way, no word for \(age($t))"; "")
      end
   ]
   +
   [.backlog.records[]?
    | select(.structured == true and .state == "done")
    | select(((.completion.date // "") | clean) == $today)
    | row("DONE"; "\(.id) \(.title | clean)"; "")
   ])[]
'

render_sidebar() {  # <snapshot-json>
  local snapshot=$1 records live needs today
  today=${FM_FLEET_VIEW_TODAY:-$(date +%F)}
  records=$(printf '%s' "$snapshot" | jq -r --arg today "$today" "$CLASSIFY" 2>/dev/null) || records=''

  live=$(printf '%s' "$records" | grep -c -v '^DONE	' 2>/dev/null || true)
  [ -n "$records" ] || live=0
  needs=$(printf '%s' "$records" | grep -c '^NEEDS	' 2>/dev/null || true)

  local header
  header="⚓ FLEET · $(date +%H:%M) · $live $(plural "$live" task) · $needs need you"
  emit "$C_HEAD" "" "$header"
  emit "$C_WAIT" "" "$(repeat_char '━' "$WIDTH")"

  if [ -z "$records" ]; then
    emit "$C_WAIT" "" "All quiet — nothing needs you."
    return 0
  fi

  section "$records" NEEDS "NEEDS YOU" '●' "$C_NEEDS"
  section "$records" FLIGHT "IN FLIGHT" '◐' "$C_FLIGHT"
  section "$records" WAIT "WAITING" '○' "$C_WAIT"
  section "$records" DONE "DONE TODAY" '✓' "$C_DONE"

  if [ "$needs" -eq 0 ]; then
    emit "$C_FLIGHT" "" "Nothing needs you right now."
  fi
}

section() {  # <records> <key> <title> <glyph> <color>
  local records=$1 key=$2 title=$3 glyph=$4 code=$5 rows count headline action
  rows=$(printf '%s\n' "$records" | grep "^$key	" 2>/dev/null || true)
  [ -n "$rows" ] || return 0
  count=$(printf '%s\n' "$rows" | grep -c . || true)
  emit "$C_HEAD" "" "$title ($count)"
  while IFS=$'\t' read -r _ headline action; do
    [ -n "$headline" ] || continue
    emit "$code" "" "$glyph $headline"
    [ -z "$action" ] || emit_copyable "$C_WAIT" "  " "↳ $action"
  done <<< "$rows"
}

plural() {  # <count> <singular>
  if [ "$1" = 1 ]; then printf '%s\n' "$2"; else printf '%ss\n' "$2"; fi
}

repeat_char() {  # <char> <count>
  local i out=''
  for ((i = 0; i < $2; i++)); do out="$out$1"; done
  printf '%s\n' "$out"
}

render_wide() {  # <snapshot-json>
  printf '%s\n' "$1" | jq -r '
  def dash($v): if $v == null or $v == "" then "-" else $v end;
  def endpoint_exists($t):
    if $t.endpoint.exists == null then "unknown"
    elif $t.endpoint.exists then "present"
    else "absent" end;
  def endpoint_of($t):
    if $t.kind == "secondmate" then "\(endpoint_exists($t)) / \($t.endpoint.agent_alive)"
    else endpoint_exists($t) end;
  def artifact($t):
    if $t.pr.url != null then $t.pr.url
    elif $t.paths.report.present then $t.paths.report.path
    else "-" end;
  def path_of($t):
    if $t.paths.home.present then $t.paths.home.path
    elif $t.paths.home.path != null then $t.paths.home.path + " (absent)"
    elif $t.paths.worktree.present then $t.paths.worktree.path
    elif $t.paths.worktree.path != null then $t.paths.worktree.path + " (absent)"
    else "-" end;
  def action_of($t):
    if $t.kind == "secondmate" then "\($t.actions.send) - \($t.actions.watch)"
    else $t.actions.watch end;
  def task_row($t):
    "| \($t.id) | \($t.current_state.state) / \($t.current_state.source) | \($t.kind) | \(dash($t.backlog.repo // $t.project)) | \($t.backend) | \(endpoint_of($t)) | \(artifact($t)) | \(path_of($t)) | \(action_of($t)) |";
  def blocker($r):
    if ($r.blocked_by // "") == "" then "-"
    elif ($r.blocked_reason // "") == "" then $r.blocked_by
    else "\($r.blocked_by) - \($r.blocked_reason)" end;
  def backlog_row($r):
    "| \($r.id // "-") | \(dash($r.title // $r.raw)) | \(dash($r.repo)) | \(dash($r.kind)) | \(blocker($r)) | \(dash($r.pr_url // $r.report_path // $r.local_note)) |";

  "# Fleet View",
  "",
  "Schema: \(.schema)",
  "Home: \(.fm_home)",
  "",
  "## Under Way",
  (if (.tasks | length) == 0 then
    "No live task metadata found."
   else
    "| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    (.tasks[] | task_row(.))
   end),
  "",
  "## Queued",
  (if ([.backlog.records[]? | select(.state == "queued")] | length) == 0 then
    "No queued backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "queued") | backlog_row(.))
   end),
  "",
  "## Done",
  (if ([.backlog.records[]? | select(.state == "done")] | length) == 0 then
    "No done backlog records found."
   else
    "| ID | Title | Repo | Kind | Blocked By | Artifact |",
    "| --- | --- | --- | --- | --- | --- |",
    (.backlog.records[] | select(.state == "done") | backlog_row(.))
   end),
  "",
  "## Secondmates",
  .secondmate_guidance.note
'
}

render_once() {
  local snapshot rc=0
  if ! snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null); then
    emit "$C_WARN" "" "⚠ Could not read the fleet's records just now."
    flush_frame
    return 1
  fi
  if [ "$MODE" = wide ]; then
    render_wide "$snapshot"
    return $?
  fi
  render_sidebar "$snapshot" || rc=$?
  flush_frame
  return "$rc"
}

WIDTH=$(resolve_width)

if [ "$MODE" != watch ]; then
  render_once
  exit $?
fi

cleanup_watch() {
  [ -t 1 ] && printf '\033[?25h'
  exit 0
}
trap cleanup_watch INT TERM
[ -t 1 ] && printf '\033[?25l'

while :; do
  # Render into a buffer first so a slow snapshot never leaves a half-drawn pane.
  WIDTH=$(resolve_width)
  frame=$(render_once)
  if [ -t 1 ]; then printf '\033[H\033[2J'; fi
  printf '%s\n' "$frame"
  sleep "$INTERVAL"
done
