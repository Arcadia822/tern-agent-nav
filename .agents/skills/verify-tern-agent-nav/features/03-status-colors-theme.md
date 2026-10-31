# Status colors remain distinct across Tern themes

## Sub-features (status precedence in `build_view`)

1. waiting for user input / approval → `.status-attention` → `var(--ansi5)` (purple)
2. running → `.status-running` → amber text shimmer, with no status background
3. error (delivery error or nonzero exit) → `.status-error` → `--agent-nav-error` (red), semibold
4. finished & unread (turn ended while pane unfocused) → `.status-done-unread` → `--agent-nav-unread` (green)
5. finished & read / idle → `.status-done-read` → `var(--t2)` (muted default)

In `sample_status`, focusing a pane clears its unread flag; a running-to-finished transition while
unfocused or a bell alert sets it. A nonzero exit takes precedence over unread.

## How to get to it (user POV)

Running, unread and error use appearance-aware semantic colors from `styles.css`:
running text is `light-dark(#854d0e, #f5a524)`, unread is
`light-dark(#15803d, #3ecf8e)`, and error is `light-dark(#c1121f, #ff6166)`.
Light mode uses an opaque darker shimmer sweep (`#422006`); dark mode uses a
brighter sweep. Unfocused rows stay transparent in every interaction state.
The focused row alone uses fixed `rgba(128, 128, 128, 0.08)`, independent of
agent status. Error rows are semibold to strengthen the text cue.
These hues must stay distinct in `light-forest`, whose warning and success colors
both lean green and whose error color is brown/orange. Attention, idle text and
rail chrome continue using Tern theme variables.

## Driving it with the harness

```sh
tern capture SESSION/BLOCK --surfaces   # observe the pane's real state (hints, bell, exit)
tern capture "Agent Navigations" --surfaces  # rows present in the matching states
W='tern ctl --control /tmp/nav-verify.sock'
$W 'theme dark <name>'                  # switch theme; state reports theme_light/theme_dark names
$W 'theme light <name>'
$W shot colors                          # PNG per appearance: amber and green remain distinct
```

### Live no-model state fixture (`tests/smoke.py`)

The generated `build_no_model_client` program completes Tern's TSP handshake with a listening
inline surface and a sendable editor composer. It waits for the retained prompt's real `send`
event before reporting a finished turn. The fixture emits progress `OSC 9;4;1;50` for running,
paused progress `OSC 9;4;4;50` for attention, and `OSC 9;4;0` to clear progress. An unfocused
completion produces unread; focusing that pane clears unread. Error comes from the program
actually exiting with a nonzero status.

```sh
python3 tests/smoke.py --existing-window \
  --only test_native_tsp_five_state_fixture,test_manual_close_disables \
  --artifacts /tmp/tern-nav-native-fixture
```

The serial subset runs in one setup/teardown. `wire-clients.json` and the per-client wire event
files record starts, retained prompt delivery, render acknowledgements and shutdown. Frames
obey Tern's credit window; raw progress bytes do not provide a render acknowledgement.

## Gotchas

- `capture --surfaces` exposes text only. Use window `ctl 'dump SELECTOR'` to
  inspect status classes and computed colors, together with a live input state
  witness and a screenshot.
- `--ansi5` is the theme's ansi-magenta (purple); confirm the theme maps it so in both modes.
- Error needs a real delivery failure or nonzero program exit. The no-model fixture uses the
  latter and verifies the pane's actual exit status alongside the rendered error class.

## Proof (2026-10-20 pass)

- Historical source mapping used `--warn`/`--ok`/`--bad` for running/unread/error.
  The current semantic colors above replace them. Error now takes precedence over unread.
- Live inputs witnessed: copilot ask picker on screen (`04-copilot-ask-screen.txt` → attention
  input), idle/read panes in rows capture (`02-nav-rows.html` → done-read input).
- Visual: `07-window-shot-right-rail.png` shows the panel rendered in the sandbox's dark theme
  (dark-dracula) with theme-variable colors.
- The 2026-10-20 pass did not reach running, done-unread or error. The current no-model serial
  subset covers all five status classes, shimmer, transparent unfocused rows and
  the focused row's fixed neutral background.

## Regression checkpoint (2026-10-30)

- In a real Tern window render running, unread and error, including native
  shimmer. Check `ctl 'dump SELECTOR'` and inspect light/dark screenshots.
- In `light-forest`, running must have `rgb(133, 77, 14)` text, unread
  `rgb(21, 128, 61)`, and error `rgb(193, 18, 31)` at weight 600.
  Running text must remain opaque throughout the shimmer.
- Dark appearance must use running `rgb(245, 165, 36)`, unread
  `rgb(62, 207, 142)`, and error `rgb(255, 97, 102)`.
- Only the focused agent row has the fixed faint neutral fill. Normal, running,
  attention, unread, read, error, hover, pressed and keyboard-focus states must
  not add their own background or change the focused row's background color.
- A fixture canvas proves style rendering. The no-model agent program separately proves live
  state detection; record both the input witness and the rendered status class.
