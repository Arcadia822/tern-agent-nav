# Nav rows grouped by Tern session, with agent session titles

## Sub-features

- Rows group by **Tern Session** (`Default`, `Test`, …); a Tern session with no navigable panes is
  not shown (`build_view` lines 587–614).
- Each row's title is the pane title the harness writes: omp and Codex/Copilot write their session
  title into the pane title; the row shows it as-is (`build_view` lines 569–574 fall back to the
  cwd's last folder or `Pane <id>` when untitled).
- Codex marks a working turn with a braille spinner frame (U+2800..U+28FF) at the title start;
  the row strips it (`spinnerTitle`, lines 369–381).

## How to get to it (user POV)

Toggle the panel on (`Ctrl+Alt+N` or palette `Agent Nav: Toggle`); rows appear immediately.

## Driving it with the harness

```sh
tern capture "Agent Navigations" --surfaces   # plain text rows: session names, then agent titles
tern ls --json                                # pane titles as the daemon sees them
```

## Gotchas

- The capture loses CSS classes; it proves titles/grouping, not status styling (see 03/02).
- Titles update asynchronously: omp writes the session title only once the turn names the session;
  a drive right after spawning an agent may show the fallback title.
- `tern capture` needs the daemon env (`TERN_DAEMON_SOCKET` + `TERN_CONFIG_DIR`).

## Proof (2026-10-20 pass)

- `/tmp/tern-agent-nav-verify-evidence/02-nav-rows.html`: groups `Default` / `Test`; omp titles
  (`🔧 修复 claude code cli 安装`, `🌀 解释耗散结构`), copilot titles (`Ask User Life Questions -
  GitHub Copilot`). Session title update witnessed live: a first capture minutes earlier showed the
  same group WITHOUT `🔧 修复 claude code cli 安装`; the title appeared as omp named the session,
  and the nav re-rendered it (title event handler, lines 798–803).
