# Toggle lifecycle: preset/remembered width, side, reset width

## Sub-features

- **Toggle on uses the preset width**: the rail mounts at the stored `agent_nav.share` of the tab
  (`share = storedShare()`, line 204; `sizeRail(cx, tab, pane, s, share)` at the end of `pin`),
  never a fixed 50/50. Default share is 0.2 (line 16).
- **Manual width is remembered**: dragging the divider writes back the observed share
  (`noteDrag`, lines 256–266; threshold 0.005); it travels across tabs and scales with resizing.
- **Toggle off closes** the rail (`toggle` run, lines 730–748): closes the canvas, clears state;
  explicit close is "user closed" — the feature stays off (kv `agent_nav.enabled: false`).
- **Toggle left / right** moves the rail between edges (`toggle_side`, lines 751–763), first
  saving any manual drag.
- **Reset Width** drops the stored share and re-sizes to the default 0.2
  (`reset_width`, lines 765–778).
- **Multi-block tab switches preserve the remembered width**: internal ratio
  restoration can span several ticks. `noteDrag` must ignore that interval and
  widths last measured in another tab; the rebuild's temporary 50/50 split must
  never be written to `agent_nav.share`. The rail is sized before content fits.

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
- kv.json flushes lazily — read it a few seconds after the action, and don't conclude from one
  read that a command failed.
- `plugins run` acks `{"ok":true}` even for unknown actions; trust observed state changes only.

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

## Proof (2026-10-20 pass)

- `03-toggle-preset-width.txt` + kv transitions: rail mounted at share 0.404 (kv
  `agent_nav.share: 0.404`, rail `railshare=0.404`, left) — the remembered preset, not 50/50; on
  window_start it re-sized to the same 0.404 share in a wider tab (cols 28→51). After
  `reset_width`, kv share was removed and the rail re-sized to the default 0.2 (rail share
  1−0.800=0.2 on the right side) — reset width live.
- Toggle side live: kv `agent_nav.side` flipped left→right (`03-toggle-preset-width.txt`) and the
  rail rendered as split node `b` (right) in `07-window-shot-right-rail.png`.
- Toggle off: kv `agent_nav.enabled: false` was observed after a toggle-off (daemon-route drive);
  the rail-removal half of the off/on cycle did not stick in this sandbox (see run notes) —
  next pass re-drive close+reopen on the user's main window before release.
