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
- Icon per harness is chosen from the command the agent block was opened with
  (`cx.agents:list()`), then the pane's foreground command (`running.line`, then the
  `tern process` probe), then its program and title (`HARNESS_ICONS`, `window.luau` lines
  40–57; `harness_icon` 1962–1971; `detect_harness` 2394–2424): omp → `app-omp`,
  codex → `provider-openai`, copilot → `mi-copilot`, claude → `mi-claude`, gemini, cursor, …
- A name counts only as a whole word, so `components/`, `prompt` and `compile` are not
  omp, and `claude-code` / `codex-acp` stay whole. An agent block whose harness is not
  yet known draws a first-letter avatar (`.agent-nav-avatar`, `badge_node` line 2328),
  never another harness's logo.
- Which panes become rows at all: `is_navigable_pane` (2426–2449) needs a named harness,
  except for a native agent block that has reported a turn (`working` / `waiting_input`,
  latched in `everActive` line 1779). Tern reports every command block as `kind: agent`,
  so without that gate a launched `pnpm run` becomes an "agent session".
  Turn evidence lasts until the native pane closes; a later list snapshot must not erase it.
  It is not persisted across plugin reloads.

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
- `detect_harness` needs the foreground command for panes started before installation or before
  the window opened. Both terminal panes and unidentified idle agent blocks fall back to
  `tern process <pane> --json` asynchronously. A cached result queues the rail's lifecycle update
  in a fresh window turn so a late result cannot redraw a canvas that is closing. No new agent
  turn or focus change is required. Known launch commands still identify in the same tick.
- `test_cold_start_wrapped_agent` runs an idle no-model agent behind an anonymous launcher,
  reloads the plugin with the panel closed, and opens it again. Only the real foreground argv
  names the harness; the original process must reappear without another turn.
- iOS runtime skips the probe (`tern.runtime.os == "ios"`, line 1830) — icons fall back to
  program/title matching there.
- Regression to guard (2026-11-02 fix): a terminal pane running `pnpm run …` under a path
  such as `…/components/` once drew an agent row with omp's logo (substring match); a
  command block Tern reports as an agent got omp's logo until its title arrived; and any
  launched command block was listed as an agent session. Evidence: rows/logos/avatars via
  `ctl 'tree .agent-nav-agent'`, `'tree .agent-nav-logo'`, `'tree .agent-nav-avatar'`
  compared against `window.luau` at HEAD.

## Proof (2026-10-20 pass)

- Source-cited: `styles.css` lines 92–110 (16px box, 16px `.sf-icon`, 14px svg override),
  `window.luau` lines 32–49, 428–453.
- Live: rows for omp / copilot / codex rendered in `02-nav-rows.html`;
  `07-window-shot-right-rail.png` shows the rail rendering (empty state in that window — no logos
  in shot). Full logo visual proof needs a window whose session holds agent panes; next pass shoot
  from the sandbox window with the agent tabs shown.
