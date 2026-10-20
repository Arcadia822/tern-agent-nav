# Feature map — Tern Agent Navigations

One file per user-facing feature. Each file answers: what it is (user POV), how to reach it, how to
drive it with the harness, and what observable end state proves it works. The map reflects the
**in-flight working-tree plugin** (main worktree `window.luau` + `styles.css`), which the sandbox
drives; line numbers cited are from that working tree.

| # | Feature file | Audit checkpoint it guards |
|---|---|---|
| 01 | [nav-rows-session-titles.md](01-nav-rows-session-titles.md) | omp/codex/copilot session title 更新进导航行 |
| 02 | [running-shimmer.md](02-running-shimmer.md) | running 只让文字 shimmer（光影在文字上，非背景/字形位移动画） |
| 03 | [status-colors-theme.md](03-status-colors-theme.md) | 状态颜色 running 黄、完成未读绿、完成已读默认、等待人类紫、错误红，全部随 Tern 主题明暗迁移 |
| 04 | [harness-logo.md](04-harness-logo.md) | harness logo 尺寸/裁切/对齐/明暗切换 |
| 05 | [session-name-style.md](05-session-name-style.md) | Tern session 名非全大写且比 agent 标题更淡 |
| 06 | [toggle-preset-width.md](06-toggle-preset-width.md) | toggle 打开时使用预设/记忆宽度，Reset Width 回默认 |
| 07 | [copilot-ask-user.md](07-copilot-ask-user.md) | copilot ask-user 识别为等待人类（紫色），且优先于 running |
| 08 | [notifications-english.md](08-notifications-english.md) | 插件通知文案全英文 |

## Harness

See `../SKILL.md` (Launch / Doctor / Drive / Evidence / Cleanup / Helpers). Short form: sandbox
daemon (`/tmp/tern-sandbox`) + one long-lived window on `/tmp/nav-verify.sock`; rows via
`tern capture "Agent Navigations" --surfaces`; layout truth via `tern ls --json`; persisted state
via `/tmp/tern-sandbox/config/plugin-data/agent-nav/kv.json`; visuals via `ctl shot`.

## Coverage honesty rules

- CSS class / color / shimmer rendering is **not** CLI-observable (`plugins expect` sees plain
  surface text only): those claims are source-cited with the live row-state as input witness.
- A feature that can't be reached live is marked `verified-unreachable` only with the concrete
  prerequisite and the route attempted.
