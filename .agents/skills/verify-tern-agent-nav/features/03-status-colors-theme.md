# Status colors remain distinct across Tern themes

## Sub-features (status precedence in `build_view`)

1. waiting for user input / approval → `.status-attention` → `var(--ansi5)` (purple)
2. running → `.status-running` → amber text shimmer; light mode adds a bright yellow row background
3. finished & unread (turn ended while pane unfocused) → `.status-done-unread` → `--agent-nav-unread` (green)
4. error (delivery error or nonzero exit) → `.status-error` → `--agent-nav-error` (red), semibold
5. finished & read / idle → `.status-done-read` → `var(--t2)` (muted default)

Unread clears when the pane is focused (lines 545–548); running→finished while unfocused sets
unread (lines 531–543); bell alerts on inactive panes count as unread (540–543).

## How to get to it (user POV)

Running, unread and error use appearance-aware semantic colors from `styles.css`:
running text is `light-dark(#854d0e, #f5a524)`, unread is
`light-dark(#15803d, #3ecf8e)`, and error is `light-dark(#c1121f, #ff6166)`.
Light-mode running rows have a bright `#ffed99` background and an opaque darker
shimmer sweep (`#422006`). Dark mode keeps the transparent row background and
uses a brighter sweep. Error rows are semibold to strengthen the status cue.
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

## Gotchas

- `capture --surfaces` exposes text only. Use window `ctl 'dump SELECTOR'` to
  inspect status classes and computed colors, together with a live input state
  witness and a screenshot.
- `--ansi5` is the theme's ansi-magenta (purple); confirm the theme maps it so in both modes.
- Error state needs an agent turn that actually fails (delivery error / nonzero exit) — same
  prerequisite as a live running turn.

## Proof (2026-10-20 pass)

- Historical source mapping used `--warn`/`--ok`/`--bad` for running/unread/error.
  The current semantic colors above replace them; status precedence is unchanged.
- Live inputs witnessed: copilot ask picker on screen (`04-copilot-ask-screen.txt` → attention
  input), idle/read panes in rows capture (`02-nav-rows.html` → done-read input).
- Visual: `07-window-shot-right-rail.png` shows the panel rendered in the sandbox's dark theme
  (dark-dracula) with theme-variable colors.
- Unreached live: running (yellow), done-unread (green), error (red) rows — prerequisite is a
  live turn or a failing turn; routes attempted (screen scan of all sandbox panes). Next pass:
  start a turn, then unfocus it and let it finish for done-unread.

## Regression checkpoint (2026-10-30)

- In a real Tern window render running, unread and error, including native
  shimmer. Check `ctl 'dump SELECTOR'` and inspect light/dark screenshots.
- In `light-forest`, running must have `rgb(133, 77, 14)` text on
  `rgb(255, 237, 153)`, unread `rgb(21, 128, 61)`, and error `rgb(193, 18, 31)`
  at weight 600. Running text must remain opaque throughout the shimmer.
- Dark appearance must use running `rgb(245, 165, 36)`, unread
  `rgb(62, 207, 142)`, and error `rgb(255, 97, 102)`. Switching color theme must
  not change these hues. Hover and current-row states must retain the running
  row's light-mode yellow background.
- A fixture canvas can prove style rendering; it does not prove live agent state
  detection. Record those two kinds of evidence separately.
