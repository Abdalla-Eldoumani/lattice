# The constraint-propagation engine

This is the finite-domain constraint engine: the part of lattice that takes a puzzle, turns it into
variables and constraints, prunes the variables' domains by propagating those constraints, and
searches for an assignment that satisfies all of them. It is pure Haskell — no `IO`, no mutable
state in the core — and the same code runs in two modes: a fast mode that just returns
the answer, and a trace mode that streams its reasoning as events. The two-mode design is summarized
at the end of this document and covered in full in [ARCHITECTURE.md](ARCHITECTURE.md).

For the wire format the engine emits, see [PROTOCOL.md](PROTOCOL.md). For how correctness is held
down, see [TESTING.md](TESTING.md). The SAT engine, which solves a different class of problem with a
different algorithm, is in [SAT-ENGINE.md](SAT-ENGINE.md).

## The model

A problem is a set of variables, each with a finite set of values it may still take, plus a set of
constraints over those variables. The types live in `src/Lattice/Core/Types.hs`.

- A `Var` is an `Int` index. A `Value` is an `Int`. Both are plain integers; the encoders decide
  what they mean (a Sudoku cell, a graph vertex, a queen's column).
- A `Domain` is a `newtype` around `Data.IntSet` — the values a variable may still take. An empty
  domain is the conflict signal; a singleton domain is a decided variable. The `newtype` keeps a
  domain from being confused with a bare `IntSet` elsewhere.
- `Domains` is `Data.IntMap.Strict Domain`, the whole state of a solve: every variable mapped to its
  current domain. It is a persistent (immutable) map, which is the load-bearing choice for
  backtracking — see "The trail" below.
- A `Model` bundles the seeded `Domains` with a list of `Constraint`s. It is deliberately
  puzzle-agnostic: Sudoku, graph coloring, N-queens, and nonograms all produce this same shape, so
  the solver and the brute-force reference work for every encoder without knowing which puzzle they
  came from.
- A `Result` is either `Solved Assignment` (every variable pinned to one value) or `NoSolution` (a
  sound report that no assignment exists).

### Constraints

The `Constraint` type has six constructors, each carrying the variables it ranges over:

| Constructor | Meaning |
|---|---|
| `AllDifferent [Var]` | the listed variables take pairwise-distinct values |
| `NotEqual Var Var` | two variables take different values |
| `AllDiffOffset [(Var, Int)]` | the values `v + offset` are pairwise distinct |
| `SumEq [Var] Int` | the listed variables sum to the given constant |
| `LessEq Var Var` | the first variable's value is at most the second's |
| `LineClue [Var] [Int]` | a line of `{0,1}` cells whose maximal runs of 1s match the run-length clue |

`NotEqual` is its own constructor rather than `AllDifferent [a, b]` so the graph-coloring encoder can
reuse the binary case directly. `AllDiffOffset` makes the three-line N-queens encoding possible (the
columns and both diagonals each become one offset-all-different). `LineClue` expresses something no
other constraint can: contiguity. `SumEq` could fix a nonogram line's total ink, but not the pattern
of its runs, so the nonogram needs `LineClue`.

## The domain operations

Every propagator and the search loop go through six pure, total operations in
`src/Lattice/Core/Domain.hs`. None of them use `error` or a partial pattern match; totality here is
what lets the layers above reason about conflict and assignment without guarding against crashes.

- `domainOf :: Var -> Domains -> Domain` — the variable's domain, or the empty domain if it is absent
  (a total lookup; encoders seed every variable, so the default only guards misuse).
- `removeValue :: Value -> Var -> Domains -> Domains` — drop a value from a variable's domain.
  Idempotent: removing an absent value is the identity.
- `assign :: Var -> Value -> Domains -> Domains` — replace a variable's domain with the singleton
  `{x}`.
- `isEmpty :: Domain -> Bool` — true when no values remain (the conflict signal).
- `singletonValue :: Domain -> Maybe Value` — the sole value of a singleton domain, or `Nothing` when
  the size is not exactly one.
- `unassignedVars :: Domains -> [Var]` — the variables not yet decided (domain size greater than one),
  in ascending index order.

## Propagation

Propagation prunes domains: it removes values that cannot appear in any solution given the values
already removed. The rule the whole engine depends on is **soundness** — a propagator may only remove
a value that genuinely cannot appear in any solution from the current domains. A sound-propagation
property test (see [TESTING.md](TESTING.md)) checks this for every propagator. The propagators are in
`src/Lattice/CP/Propagator.hs`.

### Value elimination

`propagateConstraint :: Constraint -> Domains -> PropResult` runs one constraint over the current
domains and reports the outcome:

- `Changed [Var] Domains` — these variables' domains actually shrank; here is the updated map.
- `Unchanged` — nothing moved.
- `Conflict Var` — some variable's domain emptied.

The propagators are deliberately value-elimination propagators, the simplest sound form. They are not
the strongest possible (an all-different propagator could do full Hall-set / matching reasoning for
arc-consistency, and a line propagator could use an automaton over the run-length language), but the
simple form is sound, easy to test, and the right starting point. The source marks the upgrade
points for the stronger algorithms.

What each one does:

- **`AllDifferent`**: every variable pinned to a singleton `{v}` removes `v` from each of its peers'
  domains.
- **`NotEqual`**: if either variable is pinned, remove that value from the other.
- **`AllDiffOffset`**: each pinned `(v, off)` forbids the value `v + off`, so a peer `(u, off')` must
  not take `v + off - off'`. With offsets `0`, `i`, and `-i`, this is exactly N-queens columns and
  both diagonals.
- **`SumEq`**: a bounds propagator. A variable's value is pinned between `c` minus the most the others
  can sum to and `c` minus the least, so any value outside that band is removed.
- **`LessEq`**: a bounds propagator. From `a` remove every value greater than `b`'s maximum; from `b`
  remove every value below `a`'s minimum.
- **`LineClue`**: placement enumeration. Enumerate every `{0,1}` layout of the line whose maximal runs
  of 1s match the clue in order, keep the layouts consistent with the cells already decided, then
  force a cell to 1 (remove 0) when every surviving layout inks it, and to 0 (remove 1) when none
  does. The layout count is `C(free + runs, runs)`, cheap for short lines, which is why the fixtures
  keep lines narrow.

### The queue and the fixpoint

One propagator pass is not enough: a removal in one constraint can enable a removal in another. The
propagation loop in `src/Lattice/CP/Queue.hs` drives this to a fixpoint.

`propagateM` is the loop, generic over the monad. It keeps a worklist of constraint indices, seeded
with every constraint (so a contradictory set of givens surfaces here, before any search decision).
For each constraint it pulls off the list it runs `propagateConstraint`:

- on `Conflict`, it stops and returns `Left EmptyDomain` (emitting a `Conflict` event at the offending
  cell in trace mode);
- on `Unchanged`, it moves to the next constraint;
- on `Changed vs ds'`, it re-enqueues exactly the constraints that watch the shrunk variables `vs`,
  and continues over the updated domains (emitting a `Propagate` event for each value removed).

The "watchers" come from a watch map (`buildWatch`) built once per model: each variable maps to the
indices of the constraints that mention it. `constraintVars` is the single source of truth for which
variables a constraint mentions, so the watch map and the search heuristics stay consistent when a
constraint kind is added.

Because domains only ever shrink, the order constraints run in changes which constraint fires first
but never the final fixpoint. `propagate` is the pure fast-mode entry point: it runs `propagateM`
with a no-op emit in the `Identity` monad, which the compiler reduces back to an allocation-free
loop.

## Search

Propagation alone does not solve most instances; eventually it stalls with some variables still
holding more than one value, and the search has to guess. The backtracking search lives in
`src/Lattice/CP/Search.hs`. Its rule is **propagate first, decide only when propagation stalls** —
every decision is followed by a full propagation pass, so the search only ever branches on what
propagation could not resolve.

`searchCore` is the loop, generic over the monad. Each step:

1. Propagate to a fixpoint. On a conflict, this branch fails (return no solution).
2. If every variable is now a singleton, read off the assignment and return it (emit a `Solution`).
3. Otherwise pick an unassigned variable, order its candidate values, and try each value in turn:
   assign it (emit a `Decision`), recurse one level deeper, and on failure undo and try the next
   value (emit a `Backtrack`).

### Variable and value ordering

The ordering does not change which answers are valid — only how much of the search space gets
explored before one is found. The `Strategy` type selects between `Naive` (first unassigned variable,
values in natural order) and `Mrv` (the production strategy). The production search uses three
classic heuristics:

- **Minimum remaining values (MRV)**: pick the variable with the smallest domain. A variable with two
  values left is more likely to fail fast than one with eight, so branching on it prunes dead
  subtrees sooner. This is the `domainSize` term of `mrvKey`.
- **Degree tie-break**: among variables tied on domain size, pick the one in the most constraints (the
  highest degree). It is the most entangled, so deciding it propagates the most. This is the
  `degreeMap` term of `mrvKey`.
- **Least-constraining value (LCV)**: order the chosen variable's candidate values so the value that
  rules out the fewest options for its neighbors is tried first. It is the value most likely to leave
  a solution reachable, so it tends to find one without backtracking. This is `lcvCost`, computed over
  the `neighborMap`.

`searchStats` returns the decision count alongside the result, which is how the project measures that
MRV actually reduces decisions versus naive ordering.

### The trail

Backtracking needs to undo a decision. Because `Domains` is a persistent `IntMap`, there is no
explicit undo log: a decision pushes a new map, and the old map *is* the saved state. When a branch
fails, the search simply continues from the map it held before the decision. The previous domains are
never mutated, so "restoring" them is free — this is why the CP state is an `IntMap` rather
than a mutable array. (The `Level` type tracks decision depth and is threaded through the events; the
pure search does not otherwise read it.)

## The encoders

An encoder turns a puzzle into a `Model`. They live under `src/Lattice/Encode/`. Each one owns the
mapping from puzzle coordinates to variable indices, and decodes a solved assignment back. The
parsers for external input (Sudoku grids, graph and nonogram JSON) are total: a malformed input is a
typed error, never a crash, because the streaming server hands them untrusted text.

### Sudoku (`Encode/Sudoku.hs`)

One variable per cell, at the row-major index `r * n + c`. A blank cell's domain is `{1..n}`; a given
is the singleton of that digit. The constraints are one `AllDifferent` per row, per column, and per
box. It handles 9x9 (3x3 boxes) and 4x4 (2x2 boxes); the box side is the integer square root of the
side length. `parseGrid` reads a dot-or-zero-for-blank, one-row-per-line grid and surfaces every
malformed input — wrong line length, unexpected character, out-of-range digit — as a `ParseError`. A
contradictory but well-formed grid is not a parse error: it parses, and the solver later reports it
unsolvable.

### Graph coloring (`Encode/Graph.hs`)

One variable per vertex (ids `0..n-1`), with domain `{1..k}` for `k` colors. One `NotEqual` per edge,
so adjacent vertices take different colors. `parseGraph` reads the fixed-layout JSON in
`puzzles/graph/*.json`; the `x,y` layout coordinates are for the visualizer and are read past. It is
total and bounds-checks the untrusted input: `k < 1`, or an edge naming a vertex id outside
`0..vertexCount-1`, is rejected as a `Left` rather than seeding an all-empty domain and silently
reporting the whole instance unsatisfiable.

### N-queens (`Encode/Queens.hs`)

One variable per row (`0..n-1`); its value is the queen's column (`0..n-1`). The three classic
constraints become offset-all-different: the columns `q_i` are distinct (offset 0), the up-diagonals
`q_i + i` are distinct (offset `i`), and the down-diagonals `q_i - i` are distinct (offset `-i`).
`queensModel n` builds the model directly; there is no external parser because the only input is the
board size.

### Nonogram (`Encode/Nonogram.hs`)

One boolean variable per cell (`{0,1}`, 0 blank and 1 ink) at the row-major index `r * cols + c`. One
`LineClue` per row and per column carries that line's variables in order and its run-length clue. The
cell-boolean scheme keeps events in the `cell` = grid-index / `value` = bit shape the visualizer
already speaks. `parseNonogram` reads the JSON in `puzzles/nonogram/*.json` and is total, and it
rejects semantically malformed payloads beyond bad JSON: a negative dimension, a clue list whose
length does not match its dimension, or a non-positive run length. These would otherwise survive as a
lazy value and either crash the forked solve thread or diverge from the reference oracle on a
degenerate run, so the parser keeps the accepted input inside the range where the placement
enumeration and the oracle agree.

## The two modes, briefly

The CP entry point is `src/Lattice/CP/Solver.hs`. `solve :: Model -> Result` is fast mode: it
propagates the givens to a fixpoint and searches with no events. `solveTrace :: Emit m -> Model ->
m Result` is the same `searchCore` threaded with an emit callback, so a caller receives the
decision / propagate / conflict / backtrack / solution stream as the engine reasons.

The trick is that `searchCore` and `propagateM` are written once, generic over `PrimMonad m`, and
take an `Emit m` callback. Fast mode instantiates them with `noEmit`, a callback that does nothing,
which the compiler deletes — so fast mode pays no instrumentation cost and the events the browser
animates are the engine's genuine reasoning, not a re-enactment. The full account, including how this
is shared with the SAT engine, is in [ARCHITECTURE.md](ARCHITECTURE.md). The event types themselves
are in [PROTOCOL.md](PROTOCOL.md).

## The reference solver

`src/Lattice/Brute.hs` is a plain backtracking enumerator used only by the tests. It imports no CP
engine module on purpose: its independence from the propagator, queue, and search is exactly what
makes the differential tests meaningful. Its only concession to speed is most-constrained-variable
ordering, which is ordering alone — it enumerates the identical set of solutions and shares no
inference with the real engine, so it stays "too simple to be wrong" while still finishing a 9x9
Sudoku and N=8 queens quickly. How it is used as an oracle is described in [TESTING.md](TESTING.md).
