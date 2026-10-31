# Tern Agent Navigations

A compact navigator panel for [Tern](https://stencil.so/tern) showing agents grouped by **Tern Session → Agent Session**. Each agent is represented by a single row featuring its harness logo and session title, clickable to focus.

![Agent Navigations panel](docs/screenshot.png)

## Usage

- **Ctrl+Alt+N** or command palette `Agent Nav: Toggle`: Open or close the navigator panel.
- Command palette `Agent Nav: Toggle left / right`: Toggle panel attachment between the left and right window edge.
- Command palette `Agent Nav: Reset Width`: Reset panel width to the default ratio (20% of the active tab width).
- Click any agent row: Immediately switches to that agent's Tern session and focuses its pane.
- Each session header has **+** to start omp and **…** to choose a harness. The menu's **Open in new tab** switch selects a new tab or a right split in that session's current tab.

## Behavior & Design

- **Single panel per window, follows active tab**: Following the architecture of Overseer's Projects panel, the window keeps exactly one canvas instance. When switching tabs or sessions, the panel moves into the active tab as a full-height rail on the designated edge. The target tab's existing split hierarchy and ratios are cleanly preserved.
- **Proportional fixed width**: Dragging the divider updates the remembered share ratio (`agent_nav.share`), which travels across tabs and scales smoothly with window resizing. Intermediate widths produced while rebuilding a multi-block tab are never saved as manual divider adjustments.
- **Titles and harness**: each row shows the agent's pane title (omp, Codex and Copilot write their session title there). The harness logo comes from the pane's foreground program, so Codex and Copilot are recognised even when their title does not name them.
- **Harness menu**: OMP comes first, followed by Tern's built-in Claude Code, Codex, and GitHub Copilot registrations and your `agents.custom` entries. Known names use their harness icon. Other names use a first-character avatar. The menu opens over the rows without moving them.
- **Enable Tern UI**: controls how agents launched by the menu and `+` run. When enabled, omp uses Tern's native frontend and other agents open through `tern acp`. When disabled, omp and the built-in CLIs use their terminal interfaces. Tern's custom ACP configuration does not provide a native TUI command, so custom entries are unavailable while this switch is off. The preference defaults to enabled and persists across reloads.
- **Open in new tab**: enabled by default. On opens a new tab in the clicked Tern session; off opens a block to the right of content in that session's current tab. The navigator is never split, and the new block takes focus. Both `+` and harness picks use this preference, independently of **Enable Tern UI**. The choice persists across reloads. Changing either switch keeps the menu open; the `+` tooltip follows the selected position.
- **Row states**: running uses amber text shimmer, with dark text on a bright yellow background in light mode; finished and unread is green; error is semibold red. These semantic hues stay consistent across color themes, with separate light/dark values for readability. Waiting for input uses the theme's purple, and read rows use secondary text. Tern session names are shown as written, fainter than agent titles.
- **State sources and precedence**: authoritative agent-block state (omp and wrapped chat agents) is trusted when it reports working or waiting_input; an idle/exited report is cross-checked before it is believed — against the pane title's spinner frames (leading or trailing braille), the busy/prompt pair, and the pane's last eight visible screen rows. A stale report (ACP-wrapped panes have reported idle through a real turn) therefore cannot mask real activity. Matching uses the observed English UI text of Copilot, Codex and Claude Code; when those agents change their interfaces the hint tables in `window.luau` need updating.
- **Hook budget**: screen reads are cached per pane and staggered (at most two fresh reads per render, refreshed on cheap-signal change or after a few ticks), and the split-ratio restoration after a tab switch is spread across ticks. A full steering loop inside one hook exceeded Tern's 50 ms plugin budget, after which Tern disables the hook until reload and the panel freezes on stale state.
- **Safe lifecycle**: Explicitly closing the panel disables the feature; if the containing tab or session is closed, the panel automatically restores in the remaining active tab.
- Persisted configuration keys: `agent_nav.enabled`, `agent_nav.side`, `agent_nav.share`, `agent_nav.launch_ui`, `agent_nav.open_in_tab`.

## Known Limitations

- **Dropdown host limitation**: the current menu is confined to the navigator canvas. Clicking outside it within the rail, focusing another pane, or selecting an item closes it. Tern 0.9.8 exposes no window-level popup API to canvas plugins, filters native HTML popover attributes, and reserves Escape in its preset. The requested global dropdown and Escape dismissal remain blocked on host support. This implementation does not claim those behaviors.
- **Older Tern builds** ([stencil-hq/tern-sdk#30](https://github.com/stencil-hq/tern-sdk/issues/30)): before the fix in Tern 0.9.7, every `tern` CLI attach spent a step of the daemon-wide id counter, so a daemon that had served thousands of them handed window plugins truncated tab ids. On such a build the panel cannot move into the newer tabs and shows an explicit error instead; status display keeps working. Tern 0.9.7 no longer advances the counter on read-only CLI attaches.
- **Screen-hint matching**: status detection for terminal agents matches the observed English UI text of Copilot, Codex and Claude Code (see the hint tables in `window.luau`). A localized or reworded agent interface can hide a running or waiting state until the hints are updated.
- A Copilot pane whose monthly quota is exhausted shows as a plain finished row; it is not misreported as running.

## Development

- `tests/smoke.py` — blackbox end-to-end regression against a running Tern window.
- `tests/width_regression.py` — focused native regression for four-block tab switches and width memory. Run against an isolated GUI sandbox with `python3 tests/width_regression.py --control /tmp/navw.sock --config /tmp/navw/config --daemon /tmp/navw/daemon.sock` after installing the plugin there. It checks both rail sides, content ratios, unchanged default width memory and manual divider adjustments without invoking a model.
- `.agents/skills/verify-tern-agent-nav/` — live verification harness (launch/doctor/drive/evidence) with the feature map under `features/`.

## Installation

Requires Tern 0.9.7 or newer.

```sh
tern plugin install /path/to/tern-agent-nav --force
tern plugin reload
```

## License

[MIT](LICENSE)
