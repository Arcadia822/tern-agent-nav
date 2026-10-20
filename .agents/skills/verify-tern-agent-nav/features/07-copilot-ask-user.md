# Copilot ask-user is waiting-for-human (purple), taking precedence over running

## Sub-features

- Terminal agents that report nothing to Tern still draw their question picker on screen: the
  picker's key-hint line is the signal. Copilot's ask_user hint:
  `enter accept · tab next · ctrl+d decline` (`ASK_HINTS`, `window.luau` lines 386–388).
- A question picker means the turn **waits on the user even while the title still spins**
  (`build_view` lines 520–528: screen state `ask` sets `waiting_input` and forces
  `is_running = false`).
- Precedence: attention (waiting for human) outranks running — `ag_state == "waiting_input"`
  wins over `is_running` (lines 557–560), so a spinning-title pane showing a picker renders
  purple, not yellow.
- The screen read is bounded and visible-only: last 8 rows, no scrollback
  (`screenState`, lines 411–426).
- Working detection for the same class of agents: `working esc esc edit prompt` /
  `esc esc interrupt` status lines (`WORKING_HINTS`, lines 389–394).

## How to get to it (user POV)

Ask Copilot a question via its ask_user tool; while the picker shows, its nav row is purple
(waiting), not yellow (running).

## Driving it with the harness

```sh
# witness the input state (the picker hint line on the pane's screen):
tern capture "Ask User Programming Questions - GitHub Copilot" --surfaces
# the nav must render that pane's row (capture shows the row; the class is source-cited):
tern capture "Agent Navigations" --surfaces
```

## Gotchas

- Detection **depends on these observed English hints**; a Copilot locale or hint-text change
  silently breaks it. Re-verify the hint strings after any Copilot CLI update (this is the
  regressing audit point).
- `screenState` returning nil (read failure) leaves the busy/spinner logic in charge — a broken
  read downgrades to running/idle, not attention.
- The status class itself is not CLI-observable; proof standard = screen capture (input) +
  source-cited precedence (mapping) + row present (render).

## Proof (2026-10-20 pass)

- `04-copilot-ask-screen.txt`: the sandbox's `Ask User Programming Questions - GitHub Copilot`
  pane visibly shows `↑/↓ select · enter accept · tab next · ctrl+d decline · esc cancel` —
  the ASK_HINTS substring is present on screen.
- `02-nav-rows.html`: that pane's row renders in the nav.
- Source-cited mapping: `window.luau` lines 386–394 (hints), 520–528 (ask forces waiting,
  overrides spinning title), 550–560 (attention outranks running).
