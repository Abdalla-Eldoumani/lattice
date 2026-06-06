# Visualizer walkthrough

`scripts/walkthrough.mjs` drives the built visualizer in headless Chromium (Playwright), captures
responsive screenshots of every view, captures a reduced-motion variant, and runs the accessibility
assertions the design contract makes. It is the automated form of the manual browser pass.

## Running it

The lattice-server must already be on `127.0.0.1:8080` (the page connects to `ws://127.0.0.1:8080/ws`);
the script does not start or stop it. From `web/`:

```bash
npm run build        # if .next is stale; the script serves the production build
npm run walkthrough  # spawns `next start` on :3100, drives Chromium, tears the server down
```

Knobs: `PORT=3200 npm run walkthrough` moves the Next port; `WALKTHROUGH_VERBOSE=1` echoes the Next
server log. The script owns only the Next server it spawns and the browser. It exits non-zero if any
accessibility assertion fails.

One environment note: on this Windows host `npm install` and `playwright install` hit a TLS leaf-
signature error behind the local cert store, fixed by running them with `NODE_OPTIONS=--use-system-ca`
(`NODE_OPTIONS=--use-system-ca npm install -D playwright` / `... npx playwright install chromium`). The
walkthrough run itself needs no network beyond localhost, so it runs plainly.

## What gets captured

`screenshots/` (gitignored — regenerate on demand) gets the full set: each of the six views at the
three breakpoints 375x812, 768x1024, 1440x900, plus one reduced-motion capture. For each view the
script selects the puzzle + engine, presses start, steps a few events and plays briefly so cells
animate, pauses, then screenshots.

The six views:

| slug       | puzzle           | engine     |
| ---------- | ---------------- | ---------- |
| `sudoku`   | sudoku · easy    | cp         |
| `graph`    | graph · petersen | cp         |
| `queens`   | queens · 8       | cp         |
| `nonogram` | nonogram · picture | cp       |
| `sat`      | cnf · sat-demo   | sat        |
| `race`     | graph · petersen | cp vs sat  |

The reduced-motion capture (`race-1440-reduced-motion.png`) drives the graph race in a context with
`reducedMotion: 'reduce'` — the densest live view (two engines, the colored graph, the SAT trail, the
counters) — to prove the busiest screen stays fully legible with all motion off.

A curated hero set (one per puzzle type at 1440 + the SAT view + the race + the reduced-motion race) is
committed under `public/screenshots/` (`sudoku.png`, `graph.png`, `queens.png`, `nonogram.png`,
`sat.png`, `race.png`, `race-reduced-motion.png`) so docs and the README can reference them. The bulk
set is not committed.

## Accessibility assertions

All run at 1440x900 against the live page and a real solve. The script prints `[PASS]`/`[FAIL]` per
check and exits non-zero on any failure. Last run: **20/20 passed**.

- thinking panel has an aria-live region — PASS
- every control reachable by Tab + receives focus — PASS for: puzzle picker, engine picker, start, step,
  play, restart, play-speed slider, share, tour, help (`?`), how-it-works link. (The engine picker is
  intentionally `disabled` and so not Tab-reachable on a single-engine puzzle — correct a11y, not a
  defect — so the check first selects the dual-encodable graph instance, which enables it.)
- focus never lands on a presentational grid/trail cell — PASS (Tab walked the whole page; every stop is
  a real control, none inside a `role="img"` board)
- keyboard shortcut (ArrowRight / Space) advances the solve — PASS (drove the live solve from the
  keyboard and the counters advanced)
- help overlay opens with `?` — PASS
- help overlay moves focus into the dialog — PASS
- help overlay traps focus (Tab stays inside) — PASS
- help overlay closes on Esc — PASS
- help overlay returns focus to the trigger — PASS
- /about route loads (200 + heading) — PASS

## Findings

- No app defects surfaced. The one assertion that initially failed was the test's own setup: the engine
  picker is correctly `disabled` on a single-engine puzzle, so it cannot take Tab focus there. The check
  now selects a dual-encodable puzzle first, which is the honest way to verify the control is reachable
  when it is interactive. This is the documented `disabled={engineOptions.length <= 1}` behavior.
- The sudoku and nonogram presets solve by propagation alone (0 decisions) at the point captured, so
  their boards show the candidate-fade / clue-fill state rather than a backtracking search. The graph,
  queens, SAT, and race captures all show real decisions on the trail / minimap.
