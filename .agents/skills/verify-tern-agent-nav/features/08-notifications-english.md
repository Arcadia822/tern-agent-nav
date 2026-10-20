# Plugin notifications are all-English

## Sub-features

- The plugin surfaces user-facing messages only via `cx:toast` — two known toasts, both English
  (`window.luau`):
  - `Agent Nav: Could not open panel` (line 653, when `canvas:open` fails),
  - `Agent Nav: Cannot position panel` + upstream pane-ID explanation (lines 671–672, the
    stencil-hq/tern-sdk#30 44-bit pane-ID guard).
- Log lines are English too (`tern.log.warn`, lines 670, 711, 722).
- No other user-facing strings exist outside the panel UI (which is also English: header
  `Agents`, empty state `No agent sessions active`, canvas about-text — lines 14, 617, 622).

## How to get to it (user POV)

Toasts appear on failure paths only (panel can't open / can't be positioned); the header and
empty state appear in normal use.

## Driving it with the harness

```sh
# static proof: every toast/log/UI string in the plugin source is ASCII English
grep -n 'toast(' /Users/arcadia/data/tern-agent-nav/window.luau
grep -nP '[\x{4e00}-\x{9fff}]' /Users/arcadia/data/tern-agent-nav/window.luau /Users/arcadia/data/tern-agent-nav/styles.css || echo "no CJK in plugin source"
# live witness (empty state + header, English):
tern capture "Agent Navigations" --surfaces
```

## Gotchas

- Tern's own host toasts (outside the plugin) are out of scope — only `cx:toast` strings in this
  plugin are audited.
- The about-text and header are canvas metadata (`TITLE`/`ABOUT`, lines 13–14) — English.

## Proof (2026-10-20 pass)

- Static: `toast(` sites are the two English toasts above; no CJK characters in
  `window.luau`/`styles.css` (grep `-P '[\x{4e00}-\x{9fff}]'` empty).
- Live: `07-window-shot-right-rail.png` shows header `Agents` and empty state `No agent sessions
  active`, both English; `02-nav-rows.html` shows the canvas metadata line
  `"title":"Agent Navigations","about":"Agents across Tern sessions. Click a row to switch to its
  session and focus it."`.
