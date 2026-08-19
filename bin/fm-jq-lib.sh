#!/usr/bin/env bash
# fm-jq-lib.sh - single owner for handing jq a value whose size is unbounded.
#
# The kernel caps one execve argument at MAX_ARG_STRLEN (128 KiB on Linux),
# independent of the much larger total ARG_MAX, so `jq --argjson x "$big"` fails
# with "Argument list too long" as soon as a single value crosses that cap, even
# when the whole command line is otherwise tiny. Any value that grows with fleet
# data - backlog JSON, the task inventory, status text, secondmate roll-ups, or
# anything derived from them - must therefore reach jq through stdin rather than
# argv. Bounded scalars (ids, paths, counts, booleans) stay on argv as before.
#
# fm_jq is that path:
#
#   fm_jq backlog "$BACKLOG_JSON" tasks "$TASKS_JSON" -- \
#     -n --arg generated "$now" '{b:$backlog,t:$tasks,g:$generated}'
#
# Each <name> is bound to the parsed JSON of its value under the same $name the
# filter already used, so converting a call site does not change its filter or
# its output. Values stream to jq as a JSON document sequence and the arriving
# count is asserted inside the filter, so a truncated or empty value refuses
# instead of silently binding shifted data.
#
# Contract:
#   fm_jq <name> <json> [<name> <json> ...] -- <jq-arg>... <filter>
#   - at least one bound value is required, and the filter must be the last
#     argument; everything after -- is passed to jq verbatim.
#   - -n is required among the jq arguments and is enforced, not merely
#     documented: stdin carries the bound values, so a call site that previously
#     read its input from stdin must bind that input here as well.
#   - each <name> must be a jq identifier, because it is interpolated into the
#     filter.
#
# fm_jq_text JSON-encodes possibly-huge text without ever putting it on argv, so
# a raw status line or note can be bound through fm_jq like any other value.

fm_jq_text() {  # <text> - JSON-encode text of any size
  printf '%s' "$1" | jq -Rs .
}

fm_jq() {  # <name> <json> [<name> <json> ...] -- <jq-arg>... <filter>
  local names=() docs=() prelude='' filter i arg skip=0 null_input=0
  while [ "$#" -gt 0 ] && [ "$1" != '--' ]; do
    case "$1" in
      '' | *[!a-zA-Z0-9_]* | [!a-zA-Z_]*)
        printf 'fm_jq: %s is not a usable jq variable name\n' "$1" >&2
        return 2
        ;;
    esac
    if [ "$#" -lt 2 ]; then
      printf 'fm_jq: missing JSON value for %s\n' "$1" >&2
      return 2
    fi
    if [ -z "$2" ]; then
      printf 'fm_jq: empty JSON value for %s\n' "$1" >&2
      return 2
    fi
    names+=("$1")
    docs+=("$2")
    shift 2
  done
  if [ "${1:-}" != '--' ]; then
    printf 'fm_jq: -- must separate the bound values from the jq arguments\n' >&2
    return 2
  fi
  shift
  if [ "${#names[@]}" -eq 0 ] || [ "$#" -lt 1 ]; then
    printf 'fm_jq: needs at least one bound value and a jq filter\n' >&2
    return 2
  fi
  # Without -n jq eats the first bound document as `.`, which would shift every
  # binding by one. Refuse that up front instead of leaving it to the input-count
  # assertion, whose off-by-one message reads like a truncated value.
  for arg in "${@:1:$#-1}"; do
    if [ "$skip" -gt 0 ]; then
      skip=$((skip - 1))
      continue
    fi
    case "$arg" in
      --arg | --argjson | --slurpfile | --rawfile) skip=2 ;;
      --indent | --from-file | -f | -L) skip=1 ;;
      --args | --jsonargs) break ;;
      --null-input) null_input=1 ;;
      --*) ;;
      -?*) case "${arg#-}" in *n*) null_input=1 ;; esac ;;
    esac
  done
  if [ "$null_input" -eq 0 ]; then
    printf 'fm_jq: -n is required; fm_jq owns jq stdin to carry the bound values\n' >&2
    return 2
  fi
  for i in "${!names[@]}"; do
    prelude="${prelude}(\$__fm_jq_in[$i]) as \$${names[$i]} | "
  done
  # The count assertion keeps a silently short input stream from binding the
  # wrong value to a name.
  filter="[inputs] as \$__fm_jq_in
    | (if (\$__fm_jq_in | length) != ${#names[@]}
       then error(\"fm_jq: expected ${#names[@]} JSON inputs, got \\(\$__fm_jq_in | length)\")
       else . end)
    | ${prelude}${!#}"
  set -- "${@:1:$#-1}" "$filter"
  printf '%s\n' "${docs[@]}" | jq "$@"
}
