# lattice documentation

lattice is a finite-domain constraint-propagation engine and a CDCL SAT engine, both written from
scratch in Haskell, paired with a Next.js front end that animates the engine's reasoning step by
step. Give it a Sudoku, a graph to color, an N-queens board, a nonogram, or a raw DIMACS CNF, and
instead of only printing an answer it streams the work: candidates leaving cells as constraints
propagate, the search committing to a value, a dead end, the backtrack, the recovery.

Both engines are held to the same correctness bar. The defense is differential testing against an
exhaustive brute-force oracle on small instances: the engine, the oracle, and (for the graph case)
both must agree on satisfiability and on the unique solution. The events the browser animates are
the engine's genuine reasoning rather than a scripted re-enactment, because the trace mode and the
fast mode share one hot loop. See [ARCHITECTURE.md](ARCHITECTURE.md) for how that fits together and
[TESTING.md](TESTING.md) for the correctness contract.

## The documents

| Document | What it covers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | The system as a whole: the two engines, the CLI, the streaming server, the visualizer, and the data flow between them. |
| [CP-ENGINE.md](CP-ENGINE.md) | The constraint engine: domains, propagators, the propagation queue, and the backtracking search. |
| [SAT-ENGINE.md](SAT-ENGINE.md) | The CDCL SAT engine: watched-literal propagation, 1UIP conflict analysis and clause learning, VSIDS branching, and restarts. |
| [PROTOCOL.md](PROTOCOL.md) | The event and control wire protocol shared by the engine and the browser. |
| [VISUALIZER.md](VISUALIZER.md) | The web app internals: the socket hook, the replay reducers, the per-puzzle renderers, and the controls. |
| [DESIGN.md](DESIGN.md) | The visual design system: color, type, spacing, motion, and the accessibility rules. |
| [TESTING.md](TESTING.md) | The correctness contract: soundness, completeness, sound propagation, and the brute-force differential. |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Setup, build, run, test, and how to contribute a change. |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Deploying the visualizer and running the engine behind it. |

## Where to start

- **Just looking.** Read [ARCHITECTURE.md](ARCHITECTURE.md). It explains what the two engines do,
  how the visualizer shows their work, and why the animated reasoning is real.
- **Building on it.** Start with the engine you care about — [CP-ENGINE.md](CP-ENGINE.md) or
  [SAT-ENGINE.md](SAT-ENGINE.md) — then read [PROTOCOL.md](PROTOCOL.md) to understand the contract
  between the engine and any client that consumes its event stream.
- **Reimplementing or porting it.** Read the whole set, and read [TESTING.md](TESTING.md) first.
  The differential against the brute-force oracle is the thing that tells you whether your version
  is correct, and it is what made this version correct.

For the project overview, build commands at a glance, and the screenshot gallery, see the top-level
[README](../README.md).
