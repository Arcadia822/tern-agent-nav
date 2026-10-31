# Feature map — Tern Agent Navigations

One file per user-facing feature. Each file answers: what it is (user POV), how to reach it, how to
drive it with the harness, and what observable end state proves it works. The map reflects the
**in-flight working-tree plugin** (main worktree `window.luau` + `styles.css`), which the sandbox
drives; line numbers cited are from that working tree.

| # | Feature file | Audit checkpoint it guards |
|---|---|---|
| 01 | [nav-rows-session-titles.md](01-nav-rows-session-titles.md) | omp/codex/copilot session title 更新进导航行 |
| 02 | [running-shimmer.md](02-running-shimmer.md) | running 只让文字 shimmer（光影在文字上，非背景/字形位移动画） |
| 03 | [status-colors-theme.md](03-status-colors-theme.md) | 状态只改变文字颜色与 shimmer；聚焦行固定淡灰底、其余透明；错误红加粗 |
| 04 | [harness-logo.md](04-harness-logo.md) | harness logo 尺寸/裁切/对齐/明暗切换 |
| 05 | [session-name-style.md](05-session-name-style.md) | Tern session 名非全大写且比 agent 标题更淡 |
| 06 | [toggle-preset-width.md](06-toggle-preset-width.md) | 打开使用记忆宽度；多 block 跨 tick 重建不污染 share；拖拽与 Reset Width 正常 |
| 07 | [copilot-ask-user.md](07-copilot-ask-user.md) | copilot ask-user 识别为等待人类（紫色），且优先于 running |
| 08 | [notifications-english.md](08-notifications-english.md) | 插件通知文案全英文 |
| 09 | [session-harness-actions.md](09-session-harness-actions.md) | + / … 按钮、紧凑全局 dropdown、不透明背景、关闭交互、UI 模式、Open in new tab（tab/block 落点）、Harness 图标与字母 Avatar |

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
