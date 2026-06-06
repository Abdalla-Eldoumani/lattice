# The visualizer

The web app in [`web/`](../web) is a Next.js front end that connects to a running lattice engine,
receives its reasoning as a stream of JSON events, and animates that stream: candidates leaving
cells as constraints propagate, the search committing to a value, a dead end flashing, the
backtrack, the recovery. Nothing on the board is a scripted re-enactment. Every move is the engine
working, sent to the browser one step at a time.

This document covers how the front end is built. For the wire format it consumes see
[PROTOCOL.md](PROTOCOL.md); for the engines that produce the events see
[ARCHITECTURE.md](ARCHITECTURE.md); for the visual language and the accessibility contract see
[DESIGN.md](DESIGN.md). For setup and build commands see [DEVELOPMENT.md](DEVELOPMENT.md).

![The Sudoku grid mid-solve](../web/public/screenshots/sudoku.png)

## The stack

- **Next.js 16, App Router.** The interactive page is a client component (it holds a live socket and
  local animation state); the `/about` explainer is a static server component with no client JS.
- **React 19, TypeScript.**
- **Tailwind v4, CSS-first.** There is no `tailwind.config.js`. The theme is the `@theme` block in
  [`web/app/globals.css`](../web/app/globals.css), and PostCSS runs `@tailwindcss/postcss`. Add a
  design token by editing `@theme`, not a JS config. The token set is documented in
  [DESIGN.md](DESIGN.md).
- **Fonts** load through `next/font` in [`web/app/layout.tsx`](../web/app/layout.tsx) (Fraunces,
  Inter, IBM Plex Mono) and are exposed as the `--font-*` variables the tokens reference. There are
  no `<link>` font tags.

## The data path

The flow is one direction for reasoning and one for control:

```
engine  --WebSocket-->  parseEvent  -->  pure reducers  -->  React state  -->  renderers
browser --WebSocket-->  control messages (start / step / play / pause / restart)
```

### The socket

[`web/lib/protocol.ts`](../web/lib/protocol.ts) is the TypeScript side of the wire contract; its
other side is the Haskell `Lattice.Event` ADT. It is a versioned (`v: 1`), tag-discriminated union.
`parseEvent` validates the version on receipt and returns `null` for anything off-version or
unparseable, so a protocol bump fails loudly rather than rendering garbage. The default server URL is
`ws://127.0.0.1:8080/ws`, overridable with `NEXT_PUBLIC_SOLVER_WS`. Events speak in puzzle
coordinates (cell indices, vertex ids), never internal solver variable ids.

### The replay reducer

[`web/lib/replay.ts`](../web/lib/replay.ts) is a pure, React-free reducer. It turns the event stream
into a per-puzzle cell-state model: a flat array of cells, each with a `value`, a `candidates` list,
a `status` (`given` / `open` / `decided` / `propagated` / `solved` / `conflict`), and an optional
SAT decision `level`. `applyEvent(state, ev)` returns the next state. Each event type maps to a
faithful update:

- `propagate` (CP) removes the eliminated value from the cell's candidate list.
- `propagate` (SAT, `ev.engine === "sat"`) assigns the variable its forced polarity with the
  `propagated` status, growing the trail vector on demand if a high-id variable lands past the seed.
- `decision` assigns the value, sets the `decided` status, and snapshots the grid for that decision
  level (CP) so a later backtrack restores it.
- `conflict` flags the cell `conflict`.
- `backtrack` (CP) restores the whole grid from the per-level snapshot taken when that level opened;
  (SAT) wipes every cell assigned above the backjump level back to unassigned.
- `learn` (SAT) carries the 1UIP clause into the state and tallies the learned-clause counter.
- `restart` (SAT) wipes the assigned trail back to unassigned and numbers the restart.
- `solution` writes the assignment and sets `solved`; `unsat` sets `unsat`, the dead-end peer of
  `solved`.
- `stats` overwrites the four CP counters authoritatively.

The CP `snapshots` map is the one field mutated in place across a replay; everything rendered is
produced fresh. Keeping the reducer pure and React-free is load-bearing: the headless replay check
(below) drives the exact same function the browser does, so the verification exercises the real
logic, not a parallel copy.

### The React hook

[`web/lib/useSolver.ts`](../web/lib/useSolver.ts) is a thin wrapper around the reducer. It owns the
WebSocket, applies each incoming event to the live reducer state, and exposes the rendered fields
plus the control actions (`start`, `step`, `play`, `pause`, `restart`) and the scrubber actions. The
hook deliberately holds no solver logic of its own — it routes events into `replay.ts` and
`minimap.ts` and publishes their output. That is why
[`web/scripts/verify-replay.ts`](../web/scripts/verify-replay.ts) can reconstruct the same state
headlessly: it imports `applyEvent` and replays a live engine stream through it without a browser,
then asserts the reconstructed grid equals the puzzle's known solution.

## The renderers

[`web/components/PuzzleView.tsx`](../web/components/PuzzleView.tsx) is the dispatcher. It switches on
the puzzle `kind` and renders the matching per-puzzle view from the shared cell-state model. The
switch is exhaustive over `PuzzleKind`, so adding a kind is a compile error until it is wired.

Each renderer owns the mapping from the flat cell model to its own geometry, and each carries a
second, non-color signal for every state so color is never the only cue (the accessibility rule; see
[DESIGN.md](DESIGN.md)).

| Kind | Component | Geometry | The second signal |
|---|---|---|---|
| `sudoku` | `SudokuGrid` (in `PuzzleView.tsx`) | An n×n grid, box borders thickened. Cell index is the variable. | Candidate numerals fade; a decision pulses the accent; a conflict flashes red. |
| `graph` | [`GraphView`](../web/components/GraphView.tsx) | Fixed x/y from the puzzle JSON, never re-laid-out. Cell index is the vertex. | A color-class numeral inside each vertex; a clashing edge and its endpoints stroke conflict-red; a fresh decision takes an accent ring. |
| `queens` | [`QueensBoard`](../web/components/QueensBoard.tsx) | An n×n board; one variable per row, its value the column. | A queen glyph (♛) marks a placement; a solved square carries a check mark; an attacked square flashes red. |
| `nonogram` | [`NonogramBoard`](../web/components/NonogramBoard.tsx) | A grid with clue gutters; one boolean variable per cell. | An ink block for a filled cell, a faint × for an eliminated one, blank for unknown. |
| `dimacs` | [`TrailView`](../web/components/TrailView.tsx) | The SAT assignment vector: one cell per variable, banded by decision level. | A `T`/`F` glyph for polarity; an accent ring for a decision vs a plain border for a forced literal; a struck-through id for a conflict literal; an `L0`/`L1` label, not the hue, identifies the band. |

![Graph coloring with the fixed layout](../web/public/screenshots/graph.png)

The graph view reads its layout once from the definition and memoizes it; a color change re-renders
fills and labels only, never the geometry, so the view never jitters. The TrailView bounds its cell
size by the variable count and collapses the trailing unassigned run into a `+N vars` count, so tens
of variables render large and hundreds still fit.

![The SAT assignment trail](../web/public/screenshots/sat.png)

## The search-tree minimap

[`web/lib/minimap.ts`](../web/lib/minimap.ts) is a second pure, React-free reducer, run alongside
`replay.ts` over the same event stream. It builds a compact search tree: one node per decision at its
level, the current path marked, abandoned subtrees demoted to dead ends on backtrack, the path marked
solved on solution. Only `decision`, `backtrack`, and `solution` shape it — it is a search-tree view,
not a propagation view. The render window keeps the current path plus the most recent `RECENT_WINDOW`
(24) nodes visible and collapses the rest into a `+N nodes` count, so a hard solve with thousands of
nodes still draws a bounded SVG.

[`web/components/Minimap.tsx`](../web/components/Minimap.tsx) draws the visible node set as SVG dots,
colored by node state, with a ring on the current node (the non-color cue). It holds the one
JS-driven animation in the whole app — a freshly added node grows its radius from zero. That tween is
gated behind [`web/lib/useReducedMotion.ts`](../web/lib/useReducedMotion.ts), a
`useSyncExternalStore` matchMedia hook with an SSR default of "reduced" so the server and the first
client render agree on no motion. Under reduced motion the node appears at full size instantly: the
state still updates, only the growth tween is skipped. Every other animation in the app is CSS and is
already collapsed by the global reduced-motion block in `globals.css`. The rule throughout is to gate
the animation, never the state update.

## The CP-vs-SAT race

A dual-encodable instance (graph coloring, which the server builds as both a CP model and a CNF) can
run both engines side by side. The race keeps **one socket** but holds **two reducer pairs** — a CP
model seeded from the native kind and a SAT model seeded as a `dimacs` trail sized to the CNF's
variable count. Every event in a race carries an `engine` tag (`cp` or `sat`); the hook routes each
event by that tag into the matching side, so the two panels never cross-contaminate. An untagged or
unknown tag is ignored for the split — it cannot belong to a panel — rather than corrupting one.

[`web/app/page.tsx`](../web/app/page.tsx) renders the two-panel layout (`lg:grid-cols-2`, stacking to
one column on narrow screens) when a race is live, and the single-panel layout otherwise. Each panel
is its own accessible region with its own renderer, counters, and result line; the CP panel shows the
puzzle's native renderer, the SAT panel shows the TrailView of the CNF encoding. One control bar
drives both engines over the same socket.

![A CP-vs-SAT race on one instance](../web/public/screenshots/race.png)

## Features

### The event scrubber

A step-back timeline under the single-engine controls lets the viewer replay backward and forward
through the events already received and rebuild the whole view (grid, minimap, counters, thinking
panel) at any earlier point. The hook buffers the single-engine stream in an ordered array and tracks
a `cursor` (the index the view is reconstructed to) against `eventCount` (the live edge). While
following the edge, incoming events advance the view incrementally; when scrubbed back, the view is
re-derived by replaying the prefix `events[0..cursor]` from the seed through the pure reducers. New
events always grow the buffer even while scrubbed back, so jumping to live is free, but the view stays
pinned at the cursor — the viewer is never yanked to the live edge.

Each prefix replay starts from a fresh snapshots map, because `replay.ts` mutates the CP snapshot map
in place; reusing one would leak one scrub's level snapshots into the next and corrupt a CP backtrack
restore. The scrubber is single-engine only: in race mode the buffer stays empty and the scrubber is
hidden, because the race is play-only and stays live.

### The conflict explainer

[`web/lib/explain.ts`](../web/lib/explain.ts) is a pure reconstructor. Given the buffered events and a
cursor, it finds the conflict at (or most recently before) the cursor and reports only what the event
stream genuinely conveys. The honesty contract here is load-bearing: the protocol carries no
propagation antecedents — no event says which constraint or clause caused a removal — so the explainer
never fabricates a causal "value X removed because Y" chain.

- For a CP conflict it surfaces the conflict cell, the values that `propagate` events removed from it
  since the last decision (listed plainly, with no claimed cause), the decisions still active on the
  path and the level, and the level the following backtrack returned to.
- For a SAT conflict it surfaces the conflict variable, the active decisions and level, the engine's
  own 1UIP learned clause (the one genuinely causal statement, because the engine itself derived and
  emitted it), and the non-chronological backjump level.

An absent fact — for example a backtrack that has not yet arrived at the live edge — is omitted, never
guessed. [`web/components/ConflictExplainer.tsx`](../web/components/ConflictExplainer.tsx) renders it
as an `aria-live` panel that names the conflict in words, with the conflict-red border and a `⊥` glyph
as secondary, non-color-only cues. In the thinking panel an "explain conflict" button appears when the
cursor sits on or just past a conflict; it works on a live solve and when scrubbed onto a conflict, and
auto-closes when the inspectable conflict changes so the open panel never describes a stale event.

### Shareable permalinks

[`web/lib/share.ts`](../web/lib/share.ts) encodes the current selection (`kind`, `engine`, raw
`definition`) into a URL hash — `#share=<base64url>` of a compact JSON `{ k, e, d }` — with no server
or database. The link is self-contained. The hash, not a query string, is read entirely client-side
after mount, so the static app never round-trips to a server and nothing leaks into server logs. The
base64url path keeps every definition shape intact (Sudoku newlines, JSON graph/nonogram blobs, raw
DIMACS) in one URL-safe string. `decodeShare` is totally defensive: a missing, malformed, oversized
(over 16 KB), wrong-key, or invalid-kind/engine hash returns `null`, so the page falls back to the
default instead of crashing or sending the server garbage. A shared link that matches a known preset
restores that preset; an off-preset instance shows a synthetic "from link" picker entry. The share
button is not gated on the socket — a link describes a selection, not a live solve — and its feedback
is an `aria-live` "link copied" line, with a read-only fallback field when the clipboard is
unavailable.

### The play-speed control

A range input sets the play cadence in events per second (`SPEED_MIN` 1 to `SPEED_MAX` 60, default
12), with a tabular `N ev/s` readout beside it as the non-color cue. The band sits inside the server's
`[0.1, 1000]` clamp, so any value is honored verbatim. Changing it mid-play re-sends `play(newSpeed)`,
and the server's check-and-set supersedes the running loop, so the new speed takes effect at once;
while paused it only records the value. The one slider drives both single-engine and race modes.

### The keyboard-shortcut help overlay

[`web/components/HelpOverlay.tsx`](../web/components/HelpOverlay.tsx) is a `role="dialog"` modal opened
by the `?` button or the `?`/`h` key and dismissed by Esc or the close button. Focus moves into the
dialog on open and returns to the trigger on close, Tab is trapped to the panel, and the page's window
key handler suppresses every page key while it is open so the dialog owns the keyboard. The page's
shortcuts are: `Space` live-step, `←` step back through history, `→` step forward (a live step at the
latest, a history forward-step when scrubbed back), `P` play/pause, `?`/`H` open help, `Esc` close.
The history-nav arrows are pure client replay and work without an open socket; the live keys need one.
Shortcuts never fire while focus is in a select, input, or textarea.

### The guided tour

[`web/components/Tour.tsx`](../web/components/Tour.tsx) is an on-demand stepper opened from a "tour"
button in the header, walking a first-time viewer through the page regions with short, honest
captions. It is a `role="dialog"` modal with next/prev/close, a focus trap, Esc to exit, and ←/→ to
step — the same contract as the help overlay. It outlines the region each step names with an accent
ring drawn around the live element (found by a `data-tour-id` attribute, skipped when the region is
absent in the current layout). The step text carries the meaning, so the tour reads fully under
reduced motion. It holds no solver state and never drives the engine.

### The "how it works" page

[`web/app/about/page.tsx`](../web/app/about/page.tsx) is a static server component (no client JS) that
explains in plain language what lattice is and how to read the visualizer. Its prose is grounded in
the real engines and renderers and states only what the code does, because the project's premise is
that the reasoning shown is genuine. The header on the main page links to it.

## The npm scripts

Run these from [`web/`](../web). Setup is in [DEVELOPMENT.md](DEVELOPMENT.md).

| Script | Command | What it does |
|---|---|---|
| `dev` | `next dev` | The development server. |
| `build` | `next build` | The production build. |
| `start` | `next start` | Serve the production build. |
| `lint` | `tsc --noEmit` | Type-check the whole app. |
| `verify:replay` | `tsx scripts/verify-replay.ts` | Headless reconstruction: connect to a running engine, single-step through each puzzle's stream, replay it through the same `replay.ts` reducer the UI uses, and assert the reconstructed state matches the known solution. Covers Sudoku, graph, queens, nonogram, DIMACS, and a CP-vs-SAT race on one instance. |
| `walkthrough` | `node scripts/walkthrough.mjs` | Headless Playwright pass: serve the production build, drive Chromium across the views at 375/768/1440, capture a reduced-motion variant, and run the accessibility assertions (the thinking aria-live region, every control Tab-reachable, focus never on a presentational cell, the keyboard shortcuts advancing the solve, the help overlay's focus trap and focus return, the `/about` route). Prints a PASS/FAIL line per check and exits non-zero on any failure. |

Both `verify:replay` and `walkthrough` require the lattice engine server already running on
`127.0.0.1:8080`; neither manages it. The walkthrough owns only the Next server it spawns and the
browser. A curated set of screenshots is committed under
[`web/public/screenshots/`](../web/public/screenshots).

![Reduced-motion: the busiest view stays legible with animation off](../web/public/screenshots/race-reduced-motion.png)
