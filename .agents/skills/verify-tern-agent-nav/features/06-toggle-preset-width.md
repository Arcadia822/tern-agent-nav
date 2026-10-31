# Toggle lifecycle: preset/remembered width, side, reset width

## Sub-features

- **Toggle on uses the preset width**: `openPanel` and `layout_open` capture the content before
  opening the canvas. `layout_apply` uses `storedShare()`; the default share is 0.2.
- **Manual width is remembered**: `noteDrag` saves a stable divider change greater than 0.005.
  It ignores an active restore and values last measured in another tab.
- **Toggle off closes the rail**: `toggle` disables the feature. Any unfinished job still returns
  the content panes it parked before it retires.
- **Toggle left / right**: `toggle_side` records a stable manual width before changing sides.
- **Reset Width**: `reset_width` removes the stored share and restores the default 0.2.
- **Deep split restoration**: `layout_apply` captures the normalized content tree. The controller
  fits parent dividers before adding descendants and persists pending placement/fit work.
  `layout_resume` reads unfinished ownership after plugin reload in the same window.

## How to get to it (user POV)

`Ctrl+Alt+N` or palette `Agent Nav: Toggle`; palette `Agent Nav: Toggle left / right`; palette
`Agent Nav: Reset Width`. Only these three commands exist.

## Driving it with the harness

```sh
.agents/skills/verify-tern-agent-nav/helpers/verify.sh toggle
# equivalent:
tern ctl 'palette "Agent Nav"'; tern ctl key enter    # run selected command (first: Toggle)
tern ls --json                                        # rail entry: cols + split ratio per tab
cat /tmp/tern-sandbox/config/plugin-data/agent-nav/kv.json
```

Rail share from `tern ls --json`: `ratio` when the canvas is split node `a` (left side),
`1 - ratio` when node `b` (right side). Compare with kv `agent_nav.share` before/after.

## Gotchas

- `tern ctl` world commands must be ONE argv item; multi-argv silently no-ops (SKILL.md Drive).
- Window timers and kv writes complete asynchronously. Advance native frames with `ctl wait`
  and poll the persisted value; a wall-clock sleep and one file read do not establish completion.
- `plugins run` acks `{"ok":true}` even for unknown actions; trust observed state changes only.
- Before checking startup geometry, wait until the native layout places the navigator at the
  requested edge and reports its default share. A fixed 250 ms wait and stale canvas bounds
  can misidentify the side while the 750 ms follow timer is still settling.
- For cell comparisons, read the visible window's `ctl state` `panes` entries, keyed by `id`.
  `tern ls` and `inspect` can retain initial 80x24 grids with zero pixel dimensions for new panes,
  even while the renderer reports their actual split sizes. Require the expected pane IDs in
  window state with positive rows and columns before using a half-cell tolerance.
- A reload interruption must be observed while the real journal still has an active stage and
  owned responsibility. Watching only after another native query can miss a short restore.
- Native resize accepts fractional cells. The half-cell limit below is an acceptance threshold.
  Minimum pane sizes can make a saved ratio unreachable in a narrow window: prove the bound
  by trying resize toward the target and away from it. Run the eight-pane accuracy fixture in
  a sufficiently large viewport (1780×940 was exercised); retain the same precision threshold.

## Multi-block regression checkpoint (2026-10-30)

1. Start with a settled rail at the default 0.2 share, then build another tab
   containing four content blocks: `right(right(A, B, 0.46), right(C, D, 0.5), 0.5)`.
   Three content splits require more than one restore tick.
2. Switch into that tab, wait through all restore ticks, then return and repeat
   on both left and right sides. Compare the rail share, content tree and kv.
3. The rail must remain within 0.01 of the remembered share; the three content
   ratios must remain intact; `agent_nav.share` must remain unchanged. A missing
   key stays missing (default width), rather than becoming 0.5.
4. Drag the settled rail divider, switch away and back, and prove the new share
   persists. Exercise Reset Width and toggle off/on afterwards.

Before the fix the four-block case saved `agent_nav.share: 0.5` and left the rail
at 50%. The fixed code kept it near 0.2 without writing the key.

5. Wait for content restoration after each side change before editing another
   divider. Compare pane IDs, split directions and hierarchy exactly; allow at
   most half a native cell of divider error, using the current pane grid sizes rather than a
   fixed fractional tolerance.

6. Add an eight-block mixed horizontal/vertical tree. Repeat both rail sides and round trips,
   compare against its pre-rail tree, then interrupt a live restore with reload and native close.
   Verify pane IDs and running programs survive, all owned parked panes return, and explicit
   user parking remains untouched.
7. Close the focused rail through the builtin **Close block** palette action. Do not use bare
   `ctl close`, which has closed the whole window. `test_manual_close_disables` verifies the
   exactly-one-pane delta, surviving tab/session, and a new visible wire frame with its real TSP
   draw acknowledgement after the close.
8. During an eight-pane restore with observed parked responsibility, focus another still-visible
   content pane in the same tab. After completion, the later selection must remain focused and
   unparked. Run this regression against the frozen pre-fix source and the candidate.

## Proof (2026-10-20 pass)

- `03-toggle-preset-width.txt` + kv transitions: rail mounted at share 0.404 (kv
  `agent_nav.share: 0.404`, rail `railshare=0.404`, left), the remembered preset rather than 50/50; on
  window_start it re-sized to the same 0.404 share in a wider tab (cols 28→51). After
  `reset_width`, kv share was removed and the rail re-sized to the default 0.2 (rail share
  1−0.800=0.2 on the right side), confirming Reset Width live.
- Toggle side live: kv `agent_nav.side` flipped left→right (`03-toggle-preset-width.txt`) and the
  rail rendered as split node `b` (right) in `07-window-shot-right-rail.png`.
- Toggle off: kv `agent_nav.enabled: false` was observed after a toggle-off (daemon-route drive);
  the rail-removal half of that historical off/on cycle did not stick in the sandbox. The current
  native-close subset verifies explicit rail closure and a fresh surviving render.
