# Running state: text shimmer, not background or glyph animation

## Sub-features

- A running agent's row title uses **Tern's native per-character shimmer** — the sweep omp's own
  working label uses — rendered via a `shimmer` node (`mode = "classic"`), never a CSS background
  sweep or a glyph position/size animation (`build_view` lines 603–609).
- Shimmer colors come from `--sh-*` in `styles.css`: all phases are opaque.
  Light mode uses dark amber text with a darker sweep over a static bright yellow
  row background. Dark mode uses amber text with a brighter sweep. Color themes
  must not replace the semantic amber or reduce text opacity during the sweep.
- Only the running row shimmers; other rows are static.

## How to get to it (user POV)

Start any agent turn (omp, Codex, Copilot); its nav row title sweeps.

## Driving it with the harness

```sh
# a running turn is the prerequisite; find one, or start it the user way (type a prompt)
tern capture "Agent Navigations" --surfaces   # running row present while the turn runs
tern capture SESSION/BLOCK --surfaces         # the pane's screen shows the working hints
W='tern ctl --control /tmp/nav-verify.sock'
$W 'record start shimmer'                     # film the window: the sweep is visible frame to frame
$W 'record stop'
```

## Gotchas

- **The shimmer itself is not CLI-observable as text**: the canvas capture shows the title only,
  and `plugins expect` sees plain surface text (attrs/classes excluded). The proof standard is
  (a) source-cited shimmer node + `--sh-*` CSS, and (b) a screen recording or shot sequence while a
  turn runs.
- A pane with native agent state `working` is running (`build_view` lines 505–529); terminal
  agents without state need `busy`/`at_prompt`/spinner-title/screen hints.
- Only the text animates (`.agent-nav-title .sf-shimmer`). The light-mode yellow
  row background is a static state cue, never an animated background sweep.

## Proof (2026-10-20 pass)

- Historical implementation used a theme-warning band over faded text. Current
  `--sh-*` colors above replace it with opaque text and an appearance-aware sweep.
- Live row-state: all 11 sandbox panes were idle during the pass (no in-flight turn), so no
  recording was captured. **verified-unreachable live**: prerequisite is an in-flight agent turn;
  route attempted — scanned every sandbox pane's screen for spinner/working hints
  (evidence `03-toggle-preset-width.txt` scan notes); starting one requires a model invocation,
  out of sandbox etiquette without approval. Next pass: start a turn in a test agent pane and film
  with `record`.
