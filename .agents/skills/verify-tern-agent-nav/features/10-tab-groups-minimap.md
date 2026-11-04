# Tab outlines and ghost layout map

Open **…** in the **Agents** header to change **Group rows by tab** and **Show layout map**. Both default on. Session-level **+ / …** keep their existing launch behavior.

## Acceptance checkpoints

- Each Tern Session retains its header. Its agent rows follow native tab order, then spatial block order from left to right across each row and top to bottom, in both grouped and flat modes. Reorder a native tab and arrange three blocks with a stacked left column and a full-height right block: reading order must differ from creation order and depth-first traversal, with no rows moved into another tab's box.
- Only tabs with at least two agent rows have an unfilled outline. All four corners are rounded. Content has 2px of additional padding above and below the rows. The subdued secondary title sits in a break in the top border, with 4px padding on either side of the text. The title's text starts exactly at the row logo/avatar's left edge, not at the agent title column. The trailing border resumes immediately after the title box; even a long truncated title leaves room for the upper-right corner.
- Use a named Unicode tab and a long name. The displayed label preserves the name, truncates within the rail, and exposes the full title as a tooltip. Unnamed tabs use their focused content title; the navigator title never becomes a tab label.
- A tab with two agent rows has a 48×32 ghost map at the right. If the selected block is among the first 50% of that group's spatially ordered agent rows, use the lower corner; otherwise use the upper corner. An odd middle row belongs to the latter half. Groups without the selected block use the upper corner. The map adds no extra row and does not shrink or move the agent rows.
- A tab with one agent row renders that ordinary row without a tab title, outline, map, or highlight nodes, even when it also contains ordinary terminals. Adding a second agent shows the group and map; removing it restores the ordinary row.
- In one Tern Session, mix group → group → ordinary row → ordinary row → group. Consecutive ordinary rows retain their compact spacing; each boundary involving an outlined group has the same larger gap. Turning grouping off leaves every ordinary row compact.
- The map is hidden when the pointer is outside its tab group. Hovering the group shows its soft cells. Leaving hides the map and all hover indicators. There is no backing surface, outline, border, or highlight ring.
- Content split direction and relative proportions match the native tree. The navigator is excluded; other content panes remain as muted cells. Floats appear at their owner's corner and zoom retains the underlying tree.
- Hover each agent row in turn, hold the pointer down, release, and observe the clicked state. Exactly that pane's rectangle brightens; the indicator rectangle matches the base cell in every phase, remains within the map, and the row never scales or moves on press. Hover alone does not change native focus or fill an inactive row.
- Select rows on both sides of the 50% boundary. The map and indicator switch corners together, instantly, with no position, size, or transform transition. Hold down the selected row and the next row: temporary native focus on the rail must not change the remembered content selection or flip the map's corner. Cell geometry relative to the map stays fixed while switching tabs; hover may transition cell colors only.
- The map is informational: it has no click targets and never intercepts row navigation.
- Turning grouping off restores the flat list and hides all maps, while retaining the map preference. The map switch is disabled with an explanation. Turning grouping on restores that preference.
- The map switch hides maps without removing tab boxes. Both preferences survive plugin reload. Opening either display or harness menu closes the other; changing a switch keeps the current menu open.
- Verify light and dark themes, a narrow rail, split/close/move, and plugin reload. Confirm ordinary row status colors, selected-row background, click navigation and rail width remain correct.

## Live proof

Use the isolated native GUI from `../SKILL.md` on display 1, desktop 4. Always pass its control socket and sandbox config explicitly:

```sh
TERN_CONFIG_DIR=/tmp/tern-sandbox/config TERN_DAEMON_SOCKET=/tmp/tern-sandbox/daemon.sock \
python3 tests/smoke.py --existing-window --control /tmp/nav-verify.sock \
  --only test_tab_groups_and_minimap,test_spatial_order_and_map_motion,test_map_click_position_and_spacing --artifacts /tmp/tern-nav-tab-groups
```

Run from the launched window's working directory when collecting relative screenshot paths. Synchronize the current plugin source into the sandbox before running: an installed copy is not updated by `--plugin` alone. The focused tests cover native tab ownership/reordering, spatial ordering in grouped and flat modes, stable relative map geometry across tab switches, Unicode title, logo alignment, two-row fit, single-agent absence, content ratios, hover/press/click projection, selected-half corner placement, mixed compact/group gaps, ghost visibility and both persisted switches. Keep screenshots, `tab-map-geometry.json`, `spatial-order-motion.json` and `map-click-position-spacing.json` from the run.

Useful selectors: `.agent-nav-tab`, `.agent-nav-tab-name`, `.agent-nav-tab-line`, `.agent-nav-tab-body`, `.agent-nav-map-<tab>`, `.agent-nav-cell-<pane>`, `.agent-nav-indicator-<pane>`, `.agent-nav-row-<pane>`, `.agent-nav-display-menu`.

`ctl tree` identifies rows; `ctl dump` gives rendered rectangles, opacity and background colors. Take a fresh rectangle before `ctl move`, capture before/after opacity and exact indicator-to-cell correspondence, then save a screenshot. Plain text from `plugins expect` cannot prove geometry or color.

The host CSS rejects `~` and `:has()`. Hover projection uses row descendants positioned against the shared tab body; do not restore unsupported cross-element selectors or polling.
