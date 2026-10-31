# Session actions and harness dropdown

Each workspace header has **+** followed by **…**. The plus button starts omp in that workspace. **Open in new tab** selects a new tab or a right split in its current tab. The ellipsis opens a compact dropdown anchored to that header.

## Acceptance checkpoints

- Each visible workspace has both icon buttons, including after navigation or plugin reload.
- Opening the dropdown leaves all agent-row rectangles unchanged. Its width follows its content, stays compact in a wide rail, and fits a narrow rail.
- The dropdown has an opaque background in both themes and no clipped shadow.
- Clicking outside within the rail, selecting a harness, changing pane focus, and closing the panel dismiss the dropdown. Switching either switch keeps it open.
- The top row reads **Enable Tern UI** on the left and has a switch on the right. On selects Tern Chat UI. Off selects Native TUI. The choice survives reload.
- The row below reads **Open in new tab** with the same left-label/right-switch layout and `role="switch"` / `aria-checked`. It defaults to on, persists on its own key, and changing either switch leaves the dropdown open.
- There is no divider between the two settings; a single divider separates the settings from the harness list.
- Settings use the same row padding and font as harness items, with no extra vertical margins or gaps between the two settings.
- The switches are independent: **Enable Tern UI** still selects Tui vs Chat, and **Open in new tab** only selects the landing place.
- The plus button tooltip and accessible name follow **Open in new tab**: **New agent tab** when on, **New agent block** when off.
- With **Open in new tab** on, the plus button and a harness pick create a new tab in the clicked workspace, including when another workspace is current and when that workspace's shown tab is not its first tab. In Native TUI mode omp uses its classic terminal renderer. In Tern Chat UI mode it uses its native Tern frontend.
- With it off, both entry points split the new block off the right of the agent block the clicked workspace's shown tab displays, in that same tab: the workspace's tab count is unchanged and focus lands on the new block. A non-first shown tab splits in that tab, not the first, and clicking from another current workspace splits the clicked workspace's shown tab.
- With it off and the navigator rail focused, the click still splits the rail's content sibling: the rail is never the split target.
- A launch that cannot resolve a content target keeps the existing error toast and adds no tab (it does not fall back to a new tab).
- Queue a real harness selection in tab A while restoration owns parked panes, then select tab B in the same session before the launch drains. The launched block must belong to A. If A is closed first, no harness may start in B or another tab; verify with a controlled local ACP registration and a successful launch case before asserting absence.
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

After changing tabs or workspaces, wait for the navigator to move into the shown tab and for its new frame to render before reading click coordinates. The daemon layout can update before the canvas frame does.

Record agent-row rectangles before and after opening the menu. Compare them directly. Exercise each dismissal path and inspect a screenshot at both rail edges. To check launch behavior, read back the target session's tab list and the new pane's foreground process with the sandbox daemon's `tern ls --json` and `tern process PANE --json`. Capture its visible UI with `tern capture PANE --surfaces`.

To drive **Open in new tab**, read the clicked workspace's tab list (`tern ls --json`) and its current tab's tree before and after the click: on, the tab count grows by one; off, the count is unchanged and the new pane is to the right of content, with the rail still an outer leaf. Verify focus with `tern ctl ... state` and the launched process with `tern process PANE --json`. Repeat with that workspace's second tab selected, with the rail focused, and with another workspace current, then reload the plugin to confirm both keys persisted.

Use disposable custom ACP registrations for the unknown-name avatar and Chat UI path. Starting the agent must not send a prompt or trigger a model turn. Retain the launch command, process state, screenshot, and failure logs in the run-local evidence directory.
