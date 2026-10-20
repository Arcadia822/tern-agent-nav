---
name: verify-tern-agent-nav
description: "Drive the Tern Agent Navigations plugin the way a user does — live sandbox daemon + real Tern window, palette/keyboard, real agent panes — and prove every feature from the feature map. Use for verifying agent-nav behavior before release or after Tern upgrades."
---

# Verify Tern Agent Navigations

This skill drives the **user's current plugin code** (the main worktree, including uncommitted
edits) inside an isolated Tern sandbox daemon, so the user's real Tern GUI is never touched.

The feature map lives in `features/` — read `features/README.md` first; it lists every feature and
the audit checkpoints (previously regressing behaviors) each file must prove.

## Launch

One sandbox daemon + one long-lived GUI window; drive that window serially for the whole pass.

```sh
# 1. sandbox daemon (idempotent — skip if `tern ls` already answers)
export TERN_DAEMON_SOCKET=/tmp/tern-sandbox/daemon.sock
export TERN_CONFIG_DIR=/tmp/tern-sandbox/config
nohup /Applications/Tern.app/Contents/MacOS/tern daemon \
  --socket "$TERN_DAEMON_SOCKET" --handoff "$TERN_DAEMON_SOCKET.state.handoff" \
  > /tmp/tern-sandbox/daemon.log 2>&1 &

# 2. link the plugin under test into the sandbox config (one-time per checkout state)
mkdir -p /tmp/tern-sandbox/config/plugins
# previous passes used a copy at /tmp/tern-sandbox/config/plugins/agent-nav;
# re-sync it from the main worktree (window.luau, styles.css, plugin.toml) before driving,
# or replace it with a symlink to /Users/arcadia/data/tern-agent-nav if the host reloads symlinked plugins

# 3. the plugin under test must be re-loaded after any source re-sync
tern plugin reload

# 4. one GUI window with a stable control endpoint (the drive handle)
nohup /Applications/Tern.app/Contents/MacOS/tern --control /tmp/nav-verify.sock /tmp \
  > /tmp/nav-verify-window.log 2>&1 &
sleep 4   # ready when /tmp/nav-verify.sock exists and `ctl state` answers
```

Ready signal: `/tmp/nav-verify.sock` exists and
`tern ctl --control /tmp/nav-verify.sock state` returns JSON with `"ok": true`.

Teardown is in **Cleanup**. Note the launch order: daemon first, window second; the window's
`window_start` triggers the plugin's first `follow` (panel mounts in the window's shown tab).

## Doctor

Run before the first drive, again after any failed drive, and whenever anything looks off:

```sh
export TERN_DAEMON_SOCKET=/tmp/tern-sandbox/daemon.sock
export TERN_CONFIG_DIR=/tmp/tern-sandbox/config
tern plugin list                 # must list: agent-nav 0.1.0 Agent Navigations … ready
tern ls --json                   # daemon answers, sessions parse as JSON
tern capture "Agent Navigations" --surfaces   # nav canvas reachable; first line is the canvas
                                 # metadata {"v":1,"owner":"agent-nav","title":"Agent Navigations",…}
tern ctl --control /tmp/nav-verify.sock state # window answers, has "viewport" and "sessions"
```

Healthy = all four answer. A failed `plugin list` or a nav canvas capture that returns empty means
the plugin was disabled or the source re-sync failed — `tern plugin reload` once, then re-doctor.
Failed drive → doctor again before retrying; a wedged window (doctor can't see UI state) → quit and
relaunch the window, not the daemon.

## Drive

**Routing rule (learned the hard way):** `tern ctl` takes the whole world command as ONE shell
argument; passing it as multiple argv items silently no-ops for plugin/world commands while still
answering `{"ok":true}` — e.g. `tern ctl 'plugins run plugin.agent-nav.toggle'` works,
`tern ctl plugins run plugin.agent-nav.toggle` does not. Harness scenario commands (`key`, `click`,
`tab`) also accept multi-argv. Never trust an `ok:true` you did not observe a state change for.

Primary drive handle is the window control endpoint (real user paths):

```sh
W='tern ctl --control /tmp/nav-verify.sock'

# REAL user paths to the plugin's three commands:
$W 'palette "Agent Nav"'            # open the command palette filtered to Agent Nav
$W key enter                        # run the selected command (first match: Agent Nav: Toggle)
$W key ctrl+alt+n                   # the Toggle keybinding
$W 'plugins run plugin.agent-nav.toggle'         # direct action invocation
$W 'plugins run plugin.agent-nav.toggle_side'    # Agent Nav: Toggle left / right
$W 'plugins run plugin.agent-nav.reset_width'    # Agent Nav: Reset Width

# Observers (daemon-routed; note --window routing is first-window):
tern ls --json                      # layout truth: which tab holds the rail, split ratio, cols
tern capture "Agent Navigations" --surfaces      # nav rows: session names + agent titles (plain text)
tern capture SESSION/BLOCK --surfaces            # an agent pane's visible screen (status hints)
$W state                            # window truth: tabs, palette, theme, focused pane
$W shot NAME                        # PNG + layout JSON -> target/shots/tern/live/ (run from the window's cwd)
```

Layout truth (`tern ls --json`): the rail is the canvas block titled `Agent Navigations`; its share
of the tab is `ratio` when it is split node `a` (left side) and `1 - ratio` when it is node `b`
(right side). Compare against kv:

```sh
cat /tmp/tern-sandbox/config/plugin-data/agent-nav/kv.json
# {"agent_nav.enabled": bool, "agent_nav.side": "left"|"right", "agent_nav.share": float}
```

A pane's status state comes from its visible screen (no scrollback): Copilot's
`enter accept · tab next · ctrl+d decline` line means waiting-for-human (purple), `esc esc
interrupt` / `working esc esc edit prompt` mean running (yellow + shimmer), `p.busy`, `p.at_prompt`,
bell alert and nonzero exit round out the map — see features/07 and features/02.

Visual/theme drives: `$W shot` captures the current theme; switch theme first with
`$W 'theme dark <name>'` / `$W 'theme light <name>'` (state reports `theme_light` / `theme_dark`
names) and shoot both. `record start NAME` films the window — use it for the running shimmer if a
live turn is in flight. `tern ctl` (env-routed) `plugins expect <text>` waits until the plugin
surface shows text — plain text only; CSS classes and attrs are NOT observable via the CLI, so
class/color claims are source-cited (see each feature file).

## Evidence

Collect into a run-local evidence dir (e.g. `/tmp/tern-agent-nav-verify-evidence/`), one file per
drive, named `NN-<feature>.<ext>`. Proof standards:

- Exercise the real user path (palette/keybinding) for lifecycle features; direct
  `plugins run` only as a second witness.
- Capture the action AND the resulting state: e.g. for toggle, the kv line and the
  `tern ls --json` rail entry before and after; for width, the split ratio vs `agent_nav.share`.
- Verify side effects next to visible state: kv.json writes are the plugin's persisted state —
  read the file, don't infer it.
- Screenshots (`shot`) for anything visual; text captures for rows/titles.
- State the observed pane state (screen capture) alongside the nav's expected status class —
  the class itself is not CLI-observable (see features/03).

## Cleanup

```sh
# kill the window YOU launched (by recorded pid, never by process name)
kill <window pid from launch>

# restore sandbox kv to the pre-run values you recorded at start (kv.json is the plugin's state)
# then reload so the plugin re-reads it:
tern plugin reload
```

Cleanup removes the window and restores kv; it never deletes the evidence dir. The sandbox
daemon may be left running (it is pre-existing sandbox infrastructure); record any layout changes
the run made (rail position in a specific tab) in the run notes instead of trying to reverse
layout surgery. Evidence survives: re-check the named evidence dir after cleanup.

## Helpers

`helpers/verify.sh` — wraps the env + the drives above. Executable. Invocation shown in place:

```sh
.agents/skills/verify-tern-agent-nav/helpers/verify.sh doctor    # the Doctor checklist
.agents/skills/verify-tern-agent-nav/helpers/verify.sh rows      # nav rows capture (text)
.agents/skills/verify-tern-agent-nav/helpers/verify.sh toggle    # palette-toggle off/on with kv+ratio transcript
.agents/skills/verify-tern-agent-nav/helpers/verify.sh shot name # window screenshot into target/shots
```

Run notes (features covered, unreachable prerequisites, confirmed drift, outcome) go to a scratch
location, never committed.
