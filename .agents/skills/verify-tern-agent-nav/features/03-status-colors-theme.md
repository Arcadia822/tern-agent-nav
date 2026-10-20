# Status colors follow the Tern theme (light/dark/color themes)

## Sub-features (status precedence, `build_view` lines 550–567)

1. waiting for user input / approval → `.status-attention` → `var(--ansi5)` (purple)
2. running → `.status-running` → `var(--warn)` (yellow) + text shimmer
3. finished & unread (turn ended while pane unfocused) → `.status-done-unread` → `var(--ok)` (green)
4. error (delivery error or nonzero exit) → `.status-error` → `var(--bad)` (red)
5. finished & read / idle → `.status-done-read` → `var(--t2)` (muted default)

Unread clears when the pane is focused (lines 545–548); running→finished while unfocused sets
unread (lines 531–543); bell alerts on inactive panes count as unread (540–543).

## How to get to it (user POV)

States appear as agents work/wait/finish/fail. Colors come from Tern theme variables
(`styles.css` lines 75–80), so switching the Tern theme or light/dark re-colors every row —
no hardcoded hex anywhere in the plugin's CSS.

## Driving it with the harness

```sh
tern capture SESSION/BLOCK --surfaces   # observe the pane's real state (hints, bell, exit)
tern capture "Agent Navigations" --surfaces  # rows present in the matching states
W='tern ctl --control /tmp/nav-verify.sock'
$W 'theme dark <name>'                  # switch theme; state reports theme_light/theme_dark names
$W 'theme light <name>'
$W shot colors                          # PNG per theme: row colors visibly follow the theme
```

## Gotchas

- Status **classes** are invisible to the CLI (plain text surface only): the proof standard is
  source-cited precedence + CSS vars, plus a live witness that the input state existed (screen
  capture) and the row rendered (rows capture / shot).
- `--ansi5` is the theme's ansi-magenta (purple); confirm the theme maps it so in both modes.
- Error state needs an agent turn that actually fails (delivery error / nonzero exit) — same
  prerequisite as a live running turn.

## Proof (2026-10-20 pass)

- Source-cited: `window.luau` lines 550–567 (precedence exactly as above), `styles.css` lines
  75–80 (`.status-*` mapped to `--warn`, `--ansi5`, `--ok`, `--bad`, `--t2` — all theme vars).
- Live inputs witnessed: copilot ask picker on screen (`04-copilot-ask-screen.txt` → attention
  input), idle/read panes in rows capture (`02-nav-rows.html` → done-read input).
- Visual: `07-window-shot-right-rail.png` shows the panel rendered in the sandbox's dark theme
  (dark-dracula) with theme-variable colors.
- Unreached live: running (yellow), done-unread (green), error (red) rows — prerequisite is a
  live turn or a failing turn; routes attempted (screen scan of all sandbox panes). Next pass:
  start a turn, then unfocus it and let it finish for done-unread.
