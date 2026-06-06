# Testing

The correctness contract. For a solver, the test suite is the product: a propagation or
conflict-analysis bug is invisible on easy instances and silently wrong on hard ones, so correctness
is enforced, not hoped for. This document explains what the suite checks and why. To run it, see
[DEVELOPMENT.md](DEVELOPMENT.md); for the engines it checks, see [CP-ENGINE.md](CP-ENGINE.md) and
[SAT-ENGINE.md](SAT-ENGINE.md).

## Why differential testing

A propagator that throws away a value belonging to some real solution does not crash and does not
fail on small puzzles you can check by hand. It just quietly returns "no solution" — or a wrong
solution — on the hard instances nobody enumerated. Conflict analysis in the SAT engine has the same
failure mode: a learned clause that is not actually implied by the formula corrupts the result
without any visible symptom.

The defense is differential testing against an exhaustive brute-force reference, run on small
instances. The reference is `Lattice.Brute`: a plain backtracking enumerator for constraint problems
and a plain `2^n` truth-table enumerator for CNF. It imports no CP or SAT engine module — only the
pure data types — so it shares no inference with the engine under test. It is kept deliberately
simple: enumerate every assignment, check each constraint or clause directly, done. The point is
that it is too obvious to be wrong. It is never optimized and never run on anything but small
instances (4x4 Sudoku, tiny graphs, small N, a handful of variables), where exhaustive search
finishes fast. The engine and this independent oracle must agree; where they disagree, the engine is
wrong.

The harness is [tasty](https://hackage.haskell.org/package/tasty), with HUnit for fixed cases,
QuickCheck for the generated property tests, and tasty-golden for the pinned-solution tests.

## The CP test groups

Each property compares the CP engine against the brute-force oracle on generated small instances.

- **Soundness.** Any assignment the engine returns satisfies every constraint of the instance, checked
  directly against the constraints (all-different, not-equal, comparison, sum, line-clue). A returned
  "solution" that violates a constraint is a hard failure.
- **Completeness.** The engine reports an instance unsolvable exactly when the oracle finds no
  solution. This catches both the false unsat (calling a solvable instance unsolvable) and the false
  sat. A deterministic contradictory fixture also runs every build, so the no-solution path is
  exercised even when the generator happens not to produce an unsatisfiable grid.
- **Sound propagation.** This is the highest-value test in the suite. One fixpoint of propagation
  from the givens — no search — must never remove a value that appears in some real solution. The
  test enumerates every solution with brute force, takes the union of the values each variable holds
  across those solutions, and checks that propagation kept all of them. A propagator that prunes a
  real answer is the silent killer, and this is its guard; every new propagator is run through it
  before it is considered done.
- **Differential.** The engine and the oracle agree on satisfiability, and where the oracle finds a
  unique solution, the engine returns that same assignment.

These run for Sudoku and, with shared generators, for the sum/comparison propagators, graph coloring
(the engine agrees with the oracle on k-colorability for small random graphs), the N-queens encoder
(its solution counts match the known sequence), and nonograms (a clue-to-grid-to-clue round-trip,
plus the sound-propagation property on the line-clue propagator).

## The SAT checks

The SAT engine is held to the same bar, with checks shaped to its structure:

- **The two-watched-literal invariant.** After every propagation step, every clause still watches two
  non-false literals (or is unit / conflicting). This is checked by a scan that is active in the test
  build and constant-folded away in fast mode, so mis-propagation surfaces in tests without slowing
  the real solve.
- **The implied-clause property.** Every clause the 1UIP analysis learns is implied by the formula:
  `formula AND not-learnedClause` is unsatisfiable by the brute-force oracle. This is the SAT analogue
  of the CP sound-propagation guard — the load-bearing check that learning never corrupts the result —
  and it gates the engine.
- **Asserting and backjumping shape.** A learned clause is asserting (exactly one of its literals is
  at the conflict's current decision level), and on a constructed instance whose 1UIP jumps more than
  one level, the backjump is non-chronological (below `currentLevel - 1`, not one level up).
- **DIMACS parse-then-print identity.** Parsing a CNF and printing it back re-parses to the same CNF,
  so the wire boundary is lossless. The parser is total: every malformed input (a missing or
  non-numeric header, an out-of-range literal magnitude, an unterminated clause, an absurd variable
  count) is rejected as an error rather than silently accepted.
- **Deterministic heuristic unit tests.** The Luby restart sequence, the VSIDS activity ordering, and
  phase saving are pinned to exact values with no randomness — the Luby sequence equals its known
  prefix, a bumped variable wins the branch pick over an un-bumped one, and the overflow rescale
  preserves the order the branch pick reads.

## The three-way differential

The main guard against silent-wrong-on-hard-instances is a three-way agreement. A small graph is
dual-encoded to CNF by the engine's own encoder (`Lattice.SAT.Encode.graphCNF`), which is the dual of
the CP graph-coloring model and owns the variable-to-(vertex, color) map. Then three independent
solvers run the genuinely same instance:

- the CP engine, on the constraint model,
- the SAT engine, on the dual CNF, and
- brute force — both the `2^n` CNF oracle and the CP-side enumerator.

They must agree on satisfiability and, on a unique-solution instance, on the decoded coloring. A
wrong dual encoding would make SAT solve a different problem than CP and brute force, and it would
diverge here. Because the SAT and CP solvers share no inference with each other or with the oracles,
agreement across all three is strong evidence the result is correct.

## Test budget

These are property tests, so the budget matters. The solvers are pure and deterministic: given an
instance, the answer is fixed. So a property that passes the default 100-test pass but fails roughly
1 run in 15 is not a flake — it is a real bug that the default budget happens to miss most of the
time. A level-0 root-unit soundness bug in the SAT trail was exactly this: it slipped past 100 tests
and only showed up reliably in the tens of thousands.

For that reason the SAT differential and learning properties run at a raised QuickCheck budget
(20,000 tests by default for the SAT group, and CI can raise it further), which keeps that class of
rare-per-draw failure reliably reproducible while staying fast on the tiny instances. If a property
fails intermittently, treat it as a found bug and reproduce it at a higher budget, not as noise to
re-run.

## Golden tests

Known puzzles solve to their recorded solutions. The CP engine solves the committed fixtures under
`puzzles/` and the result is diffed against a pinned solution file; a change to the output diffs
loudly as a regression. Timings are machine-dependent and are deliberately not asserted.

## The headless web checks

Two scripts in `web/` extend the contract to the visualizer, and both need the engine running:

- **`npm run verify:replay`** connects to the live engine, drives each sample instance, and checks
  that the streamed event sequence reconstructs the known solution. It verifies that the protocol and
  the client-side replay reducers agree with the engine end to end.
- **`npm run walkthrough`** serves the production build, drives a headless browser across the puzzle
  views at three widths plus a reduced-motion variant, and runs the accessibility assertions the
  design makes — the live thinking region announces, every control is reachable by keyboard, focus
  never lands on a presentational cell, the keyboard shortcuts advance the solve, and the help overlay
  traps and restores focus. It prints a pass/fail line per check and exits non-zero on any failure.

## Continuous integration

CI runs on every push. The build-and-test job builds the engine on Linux with the pinned GHC and runs
`cabal test all`, including the SAT differential at the raised budget. A separate job runs
`fourmolu --mode check` and `hlint .`. A third job, active once a `web/package-lock.json` exists,
installs the web dependencies, type-checks, and builds the front end. Green CI is the bar for closing
a change.
