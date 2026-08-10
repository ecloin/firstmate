# Fleet view

`bin/fm-fleet-view.sh` renders the fleet for a person to read.
Its default rendering is the captain sidebar: a narrow, needs-you-first surface meant for a split pane next to a firstmate session, so a glance answers "what is waiting on me, and what is still moving?".
`--wide` keeps the full-width Markdown tables for a whole-fleet read.

Run `bin/fm-fleet-view.sh --help` for the exact flags; this page covers what the surface is for and what it promises.

## Read-only

The view never changes fleet state.
It takes no session lock, drains no queued notifications, starts no monitoring, sends nothing to any worker, cleans nothing up, and writes no file under `state/` or `data/`.
That makes it safe to leave redrawing in a pane while a live session and its monitoring operate on the same home.

It gets there by not parsing fleet state at all.
Every field it renders comes from `bin/fm-fleet-snapshot.sh --json`, which is itself read-only and owns the schema.
`tests/fm-fleet-view.test.sh` pins the guarantee by comparing every file in a fixture home before and after a render, including modification times.

## Usage

```sh
bin/fm-fleet-view.sh                 # render once and exit
bin/fm-fleet-view.sh --watch         # redraw every 5s; Ctrl-C exits
bin/fm-fleet-view.sh --watch 15      # redraw on your own interval
bin/fm-fleet-view.sh --wide          # full-width Markdown tables
bin/fm-fleet-view.sh --json          # the underlying snapshot
```

Open it beside a session in a WezTerm split pane:

```sh
wezterm cli split-pane --right --percent 30 -- \
  wsl bash -lc 'cd <fm home> && bin/fm-fleet-view.sh --watch'
```

Each redraw takes a fresh snapshot of the whole home, so prefer a calm interval over a tight one on a busy fleet.

## What the sections mean

`NEEDS YOU` is the only section that asks for anything.
It holds decisions waiting on an answer, blockers, work that is finished and waiting for your word to merge or your eyes on a review, and any worker that has stopped responding.
A pull request entry always carries its full URL, a finished local-only task carries a runnable review command, and a stopped worker is reported rather than repaired.

`IN FLIGHT` is work under way, with how long it has been since the worker last said anything.

`WAITING` is work that is neither moving nor yours yet: a declared wait on something outside, or an investigation whose findings are delivered while its decisions are still being routed.

`DONE TODAY` lists work that landed today.

Anything the view says about a worker's own state is that worker's most recent word, not an independent verification.

## Environment

`NO_COLOR` disables color, which is otherwise used only when writing to a terminal.
`FM_FLEET_VIEW_WIDTH` fixes the render width instead of measuring the terminal.
`FM_FLEET_VIEW_TODAY` overrides the date used by `DONE TODAY`, which exists so tests are deterministic.
