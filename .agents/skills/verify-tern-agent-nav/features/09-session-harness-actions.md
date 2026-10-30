# Session actions and harness dropdown

Each workspace header has **+** followed by **…**. The plus button creates an omp tab in that workspace. The ellipsis opens a compact dropdown anchored to that header.

## Acceptance checkpoints

- Each visible workspace has both icon buttons, including after navigation or plugin reload.
- Opening the dropdown leaves all agent-row rectangles unchanged. Its width follows its content, stays compact in a wide rail, and fits a narrow rail.
- The dropdown has an opaque background in both themes and no clipped shadow.
- Clicking outside within the rail, selecting a harness, changing pane focus, and closing the panel dismiss the dropdown. Switching the mode keeps it open.
- The top row reads **Enable Tern UI** on the left and has a switch on the right. On selects Tern Chat UI. Off selects Native TUI. The choice survives reload.
- The plus button creates a new tab in the clicked workspace, including when another workspace is current. In Native TUI mode omp uses its classic terminal renderer. In Tern Chat UI mode it uses its native Tern frontend.
- OMP is the first item. Tern's built-in Claude Code, Codex, and GitHub Copilot registrations follow it, then `agents.custom` in configured order. No installation-file or PATH discovery runs.
- A custom agent with a recognizable name has its harness icon. Other names have a UTF-8 first-character avatar.
- Selecting a built-in in Native TUI mode bypasses Tern's automatic ACP shell wrapper. Tern Chat UI mode opens that agent through `tern acp`.
- Custom ACP agents launch through their Tern registration so Tern applies their arguments and environment. Tern does not configure a native TUI command for these entries. They are disabled in Native TUI mode.
- Workspace labels remain visibly fainter than read, completed agent rows in light and dark themes.

## Blocked host capabilities

The requested window-level dropdown and Escape dismissal remain unverified and unsupported by the current host API. Canvas hit-testing is pane-scoped even for `position: fixed`. Tern strips `popover` and `popovertarget` attributes. A plugin Escape binding is rejected because the preset owns the key. Do not mark these acceptance criteria passed or substitute the pane-local menu for them.

## Live verification

Use the isolated daemon and window from `../SKILL.md`. Keep the user's normal window out of the drive.

Read `.agent-nav-session-row`, `.agent-nav-action`, `.agent-nav-menu`, `.agent-nav-menu-item`, `.agent-nav-mode-switch`, and `.agent-nav-avatar` with `tern ctl --control /tmp/nav-verify.sock 'tree SELECTOR'`. Take a fresh rectangle before each pointer click. Use `pick X Y` to confirm that the target is the intended button before `click X Y`.

Record agent-row rectangles before and after opening the menu. Compare them directly. Exercise each dismissal path and inspect a screenshot at both rail edges. To check launch behavior, read back the target session's tab list and the new pane's foreground process with the sandbox daemon's `tern ls --json` and `tern process PANE --json`. Capture its visible UI with `tern capture PANE --surfaces`.

Use disposable custom ACP registrations for the unknown-name avatar and Chat UI path. Starting the agent must not send a prompt or trigger a model turn. Retain the launch command, process state, screenshot, and failure logs in the run-local evidence directory.
