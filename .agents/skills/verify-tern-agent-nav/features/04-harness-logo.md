# Harness logo: size, clipping, alignment, theme switching

## Sub-features

- Every row leads with a 16×16 logo box (`styles.css` lines 92–100: `.agent-nav-logo` grid,
  `place-items: center`, `flex: none`), vertically centered with the 28px row (`--l1` hover, no
  distortion) and aligned with the header/session text.
- Inside the box: Tern's own glyph icons draw at 16px (`.sf-icon` width/height 16), provider marks
  (provider-openai etc., intrinsic 24px) are scaled to 14px via the `svg` rule — the audit point:
  **no oversized or clipped logos** (`styles.css` lines 101–110).
- The logo keeps its own colors (harness brand marks are not tinted by row status), and follows
  the theme's rendering for monochrome marks so light/dark switching stays visible.
- Icon per harness is chosen from the pane's foreground command/title/program
  (`HARNESS_ICONS`, `window.luau` lines 32–49; `detect_harness` lines 428–453): omp → `app-omp`,
  codex → `provider-openai`, copilot → `mi-copilot`, claude → `mi-claude`, gemini, cursor, …

## How to get to it (user POV)

Any nav row shows the harness mark left of the title.

## Driving it with the harness

```sh
W='tern ctl --control /tmp/nav-verify.sock'
$W shot logos                # PNG: measure logo boxes against rows visually
tern capture "Agent Navigations" --surfaces   # rows exist per harness (titles identify them)
$W 'tree .agent-nav-logo'    # geometry if the window exposes the canvas DOM (empty on headless)
```

## Gotchas

- Provider marks have an intrinsic 24px box — without the svg override they blow rows to 24px.
  Regression check: open a Codex row next to an omp row; marks must be the same visual size.
- `detect_harness` needs the foreground command for panes started before the window opened; it
  probes via `tern process <pane> --json` asynchronously (`probeForeground`, lines 342–367), so a
  freshly-focused pane may render the fallback icon on the first tick.
- iOS runtime skips the probe (`tern.runtime.os == "ios"`, line 345) — icons fall back to
  program/title matching there.

## Proof (2026-10-20 pass)

- Source-cited: `styles.css` lines 92–110 (16px box, 16px `.sf-icon`, 14px svg override),
  `window.luau` lines 32–49, 428–453.
- Live: rows for omp / copilot / codex rendered in `02-nav-rows.html`;
  `07-window-shot-right-rail.png` shows the rail rendering (empty state in that window — no logos
  in shot). Full logo visual proof needs a window whose session holds agent panes; next pass shoot
  from the sandbox window with the agent tabs shown.
