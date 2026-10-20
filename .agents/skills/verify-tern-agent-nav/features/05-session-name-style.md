# Tern session names: as written, fainter than agent titles

## Sub-features

- Session headers render the Tern session name **as written** — no uppercasing, no reformatting
  (`build_view` line 591: `ui.el("div", { class = "agent-nav-session", text = g.name })`).
- Session names are visually fainter than agent titles: 12px / 500 / `var(--t4)` vs agent rows'
  13px / 400 / `var(--t2)` (`styles.css` lines 31–40 vs 42–58).

## How to get to it (user POV)

Every group in the panel starts with the Tern session's name (e.g. `Default`, `Test`), lighter
than the agent rows under it.

## Driving it with the harness

```sh
tern capture "Agent Navigations" --surfaces   # names appear exactly as in `tern ls --json`
tern ls --json | python3 -c 'import json,sys; print([s["name"] for s in json.load(sys.stdin)["sessions"]])'
```

Compare the capture's session lines against the daemon's names: identical casing, no
`text-transform` side effect (capture renders the final surface text).

## Gotchas

- The audit regression was a `string.upper`-style display transform; guard by asserting the
  capture contains the exact mixed-case name (`Ask User …` style session names make this obvious).
- A session with zero navigable panes renders no header at all — absence is not a bug.

## Proof (2026-10-20 pass)

- `02-nav-rows.html`: `Default` and `Test` appear verbatim (no uppercasing) as group headers,
  while agent titles under them carry full color emphasis. Source-cited: `window.luau` line 591,
  `styles.css` lines 31–40 (`color: var(--t4); font-size: 12px; font-weight: 500`).
