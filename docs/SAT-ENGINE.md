# The CDCL SAT engine

This is the boolean satisfiability engine: given a formula in conjunctive normal form (CNF), it
decides whether some assignment of true/false to the variables makes every clause true, and returns
one if so. It is a conflict-driven clause-learning (CDCL) solver — the modern architecture — built
from scratch on mutable unboxed vectors in `ST`, generic over `PrimMonad` so the identical code runs
fast in `ST` and streaming in `IO`. The two-mode design is summarized at the end and covered in full
in [ARCHITECTURE.md](ARCHITECTURE.md).

The CP engine, which solves finite-domain constraint problems with a different algorithm, is in
[CP-ENGINE.md](CP-ENGINE.md). The events this engine emits are in [PROTOCOL.md](PROTOCOL.md), and the
correctness contract is in [TESTING.md](TESTING.md).

The modules live under `src/Lattice/SAT/`. This document walks through them in roughly the order the
solver uses them: the data types, the clause store and trail, watched-literal propagation, conflict
analysis and learning, the branching heuristics, and the import/encode boundaries.

## The data types (`SAT/Types.hs`)

- A `Var` is a 0-based `Int` (`0 .. cnfVars - 1`).
- A `Lit` is a `newtype` around `Int`, encoded MiniSat-style as `2*var + sign` (sign 0 = positive,
  sign 1 = negative). Encoding a literal as a single integer is what lets the watch lists and the
  VSIDS activity array be flat unboxed vectors with O(1) indexing. The helpers are `mkLit :: Var ->
  Bool -> Lit` (true is positive), `litVar` (`shiftR 1`), `litSign` / `litPos` (the sign bit), and
  `negLit` (`xor 1`, so `negLit (negLit l) == l`). The `newtype` keeps an encoded literal from being
  mistaken for a raw array index.
- A `Clause` is `[Lit]`, a disjunction in parse order.
- A `CNF` is the variable count plus the clauses. The variable count is authoritative — it sizes
  every per-variable array — so the DIMACS parser validates that no literal's magnitude exceeds it.
- A `SatResult` is `Sat [Lit]` (a model, as the list of true literals) or `Unsat` (a sound proof that
  none exists).

The DIMACS 1-based signed integers are mapped to this 0-based encoding only at the parse boundary;
the engine itself never sees DIMACS coordinates.

## The clause database (`SAT/ClauseDB.hs`)

The clause database is a growable store of clauses, each frozen into an immutable unboxed `Vector Int`
of raw literal encodings, indexed by a `ClauseRef` (just the clause's index). Original clauses (from
the input CNF) and learned clauses (from conflict analysis) live in the same store, and a `ClauseRef`
is the antecedent edge the trail records and the conflict-analysis walk follows.

The backing store is a boxed `MVector` of those unboxed clause vectors, wrapped in a `MutVar`-held
`(buffer, used)` pair that doubles its capacity on overflow. `vector` has no growable type, so `grow`
allocates a new, larger vector and copies; doubling the capacity makes a sequence of appends
amortized O(1) rather than O(n²). `addClause` and `learnClause` are the same append (the distinct
names document intent at the call site); `clauseLits` returns a stored clause's raw unboxed vector for
the hot loop; `clauseCount` is the number stored.

## The trail (`SAT/Trail.hs`)

The trail is the engine's mutable spine and the single source of truth for undo. It holds:

- a growable buffer of assigned literals in assignment order (`tLits`), with its used count;
- a small growable buffer of per-level checkpoints (`tLevels`), one trail length per decision level;
- four per-variable unboxed `Int` arrays, each sized `nVars`, with `-1` as the "unassigned" sentinel
  rather than `Maybe` (a boxed `Maybe Int` would defeat the unboxed representation):
  - `value`: `-1` unassigned, `0` false, `1` true;
  - `level`: the decision level the variable was assigned at;
  - `reason`: the `ClauseRef` of the antecedent clause that forced it (`-1` for a decision), the
    implication-graph edge conflict analysis follows;
  - `phase`: the last-assigned polarity, kept for phase saving and persisting across restarts.

`assignLit` records a literal on the trail and writes its variable's value, level, reason, and phase.
`levelCheckpoint` opens a new decision level by recording the current trail length. `unwindTo`
truncates the trail back to a level's checkpoint, resetting each popped variable's value, level, and
reason to unassigned (the saved phase is deliberately kept, for phase saving). Crucially, `unwindTo`
is the *only* place those arrays are reset — chronological backtracking and non-chronological
backjumping are the same operation, an unwind to a lower level's checkpoint. Unwinding to level 0 (a
restart or a backjump to the root) keeps the level-0 root assignments — the input unit-clause
propagations, which are permanently fixed — and discards only the decision levels above them.

## Watched-literal propagation (`SAT/Watched.hs`)

Unit propagation (BCP) is where the solver spends most of its time, so it uses the two-watched-literal
scheme. This module owns the `SatState` the whole solver threads: the clause database, the trail, the
per-literal watch buffers, the propagation queue head, and the current decision level.

### The two watches and the invariant

Every clause of length ≥ 2 watches exactly two of its literals. `ssWatch` is a boxed vector of one
growable clause-ref buffer per *literal* (indexed `0 .. 2*nVars-1` by the literal code). `ssClauseW`
is a flat unboxed buffer holding each clause's two watched literal codes (slots `2*ref` and
`2*ref+1`), so reading "the other watch" is O(1) and moving a watch is a single write.

The invariant after every step is: every clause watches two non-false literals, or it is unit (one
watch true or unassigned, all other literals false) or conflicting (every literal false). The payoff
is that a watched literal only needs attention when it is *falsified*. When literal `p` is assigned
true, its complement `negLit p` becomes false, and the solver visits every clause watching `negLit p`.
For each such clause it applies a three-outcome move:

1. the other watch is already true — leave the watch, the clause is satisfied;
2. a non-false, non-watch literal exists — move the watch to it;
3. otherwise the other watch decides: if it is unassigned the clause is unit, so enqueue it forced by
   this clause; if it is false the whole clause is false, a conflict.

`propagate` drains the queue (the trail itself, read forward from `ssQHead`) until a fixpoint, returns
`Nothing` at a clean fixpoint or `Just clauseRef` for the first clause that becomes fully false.

### Backtrack needs no watch maintenance

The watched-literal property survives a trail unwind by construction: if two literals were non-false
at a deeper level, they are still non-false after assignments above the backjump level are undone
(undoing an assignment only un-falsifies literals). So a backtrack unwinds *only* the trail; the watch
buffers are never undone or fixed up. Writing undo code for them would be both wrong and slow.

### Attaching clauses, and a normalization corner

`newState` builds the state and attaches every input clause. `attachClause` first normalizes a clause
(`normalizeClause`): it drops duplicate literals and skips a tautology — a clause containing both a
literal and its negation, satisfied by everything. This matters because the watched scheme needs the
two watched literals to be distinct; a clause with a repeated literal (which the DIMACS grammar and
the test generator both permit) would otherwise watch the same literal twice and corrupt that
literal's watch buffer when it is later falsified. A unit clause (length 1) is forced at level 0; the
enqueue guards the literal's value first, so two contradictory input units `(x)` and `(¬x)` become a
top-level conflict rather than a silent overwrite. An empty clause is recorded as the formula's
conflict (it has no literal to watch and BCP can never repair it).

`checkInvariant` is a `Bool`-returning scan that verifies the two-watched property across every
clause. It runs in the test build and a debug solve, behind a flag that is false in fast mode and
constant-folds away. It is deliberately not wired through the base library's optimizer-dropped
assertion combinator, which `-O` would silently remove.

## Conflict analysis and learning (`SAT/Analyze.hs`)

When propagation produces a conflicting clause, `analyze1UIP` derives a new clause to learn and the
level to jump back to. This is the heart of CDCL, and there is no analog in the CP engine, which
backtracks chronologically and never analyzes a conflict.

The algorithm is the standard counter formulation (first unique implication point):

1. Seed from the conflict clause: mark each of its literals (skipping level-0 literals, which are
   permanently fixed and never belong in a learned clause). Count those at the current decision level;
   route the lower-level ones straight into the learned clause.
2. Walk the trail backward to the most recently assigned still-marked literal at the current level.
   Resolve it against its reason (antecedent) clause: absorb the reason's other literals the same way,
   unmark this literal, and decrement the count.
3. Stop when exactly one current-level literal remains. That literal is the first UIP; its negation is
   the **asserting literal** and leads the learned clause. The rest of the clause is the lower-level
   literals seen during resolution.

The stop condition is the subtle part: resolve while more than one current-level literal is marked,
stop at one. Stopping early yields a non-asserting clause that loops the search; stopping late
over-resolves.

The **backjump level** is the second-highest decision level among the learned clause's literals (0
when the clause is a unit). The asserting literal sits at the current, highest level; the
second-highest is where the clause becomes unit again, and the solver jumps straight there —
non-chronologically, not merely one level up.

Every learned clause is **implied by the formula**: it is a resolvent of input and earlier learned
clauses, so adding it removes no models. This is the SAT counterpart of the CP soundness guarantee,
and it is enforced as a property test — `formula AND not-learnedClause` is unsatisfiable by the
brute-force oracle, at a high test budget. See [TESTING.md](TESTING.md).

## The search loop and heuristics

### VSIDS, phase saving, Luby restarts (`SAT/VSIDS.hs`)

These decide *which* path the solver explores and *when* it restarts. They never change which
assignments are valid, so the differential against the oracle is the guard, not the heuristics
themselves.

- **VSIDS** keeps a persistent per-variable activity score (an unboxed `Double` vector). On a
  conflict, the variables on the conflict side are *bumped* by the current increment, and the
  increment itself is *grown* once per conflict by `1 / var_decay` (`var_decay = 0.95`). Growing the
  increment is the EVSIDS trick: for the purpose of ordering it is equivalent to multiplicatively
  decaying every activity, but costs O(1) instead of an O(nVars) sweep. `pickBranch` is an argmax
  linear scan over the *unassigned* variables. (A max-heap is the noted upgrade for large instances;
  the linear scan is fine for this project's small instances.) An overflow guard rescales every
  activity and the increment by `1e-100` when either passes `1e100` — a uniform scale, so the relative
  ordering `pickBranch` reads is preserved.
- **Phase saving** reuses a variable's last-assigned polarity (the trail's `phase` array) when
  branching, rather than a fixed default. It persists across restarts, so a restart often re-derives
  the same partial assignment quickly. The unset default follows MiniSat's negative-first convention.
- **Luby restarts**: `luby :: Int -> Int` is the pure reluctant-doubling sequence
  `1,1,2,1,1,2,4,1,1,2,1,1,2,4,8,...` (Knuth's iterative form). A restart fires after `unit * luby i`
  conflicts. It unwinds the trail to level 0 but keeps the learned clauses and the activities, so
  progress accumulates across restarts.

### The CDCL loop (`SAT/Solver.hs`)

`cdclLoop` is the loop, generic over `PrimMonad`. It first propagates the input's unit clauses (a
conflict here means the formula is unsatisfiable outright), then runs the decide / propagate / analyze
/ backjump cycle:

1. `pickBranch` chooses the highest-activity unassigned variable; `branchPhase` supplies its saved
   polarity. If every variable is assigned, the trail is a model — return `Sat`.
2. `decideLit` opens a fresh level and assigns the decision; the loop streams a `Decision` event.
3. `propagate` runs BCP. On a clean fixpoint, loop. On a conflict above level 0, `analyze1UIP` learns
   a clause and a backjump level; on a conflict at level 0, the formula is `Unsat`.
4. The learned clause is ordered for watching (asserting literal first, the highest-level remaining
   literal second — the standard learned-clause watch placement), then added and watched by
   `learnAndAttach`. The variables in it are bumped (VSIDS) and the increment decayed.
5. The trail unwinds straight to the backjump level (`unwindTo`), the decision level is reset, and the
   propagation queue head is clamped to the now-shorter trail so trail, level, and queue never desync.
6. The asserting literal is enqueued, forced by the just-learned clause, and propagation continues
   from there. The Luby schedule may fire a restart (an unwind to level 0 that keeps the clauses and
   activities).

A note on a deliberate convention divergence: this engine's `unwindTo bj` truncates the trail to where
level `bj` *opened*, removing level `bj` itself, where MiniSat's `cancelUntil(bj)` keeps level `bj`.
The practical effect is that the asserting literal becomes the only literal at `bj` and the learned
clause is not "unit" in the MiniSat sense after the unwind. This is sound, not a bug: the asserting
literal is still forced true, no other literal spuriously satisfies the clause, and every learned
clause stays implied by the formula. Both facts are locked by tests.

## DIMACS import and print (`SAT/Dimacs.hs`)

`parseDimacs :: Text -> Either String CNF` reads standard DIMACS CNF text. It is an untrusted-input
boundary, so it is total: every numeric parse is `readMaybe`-bounded, and a malformed instance is a
`Left`, never a crash or a silently wrong formula. It drops `c` comment lines, reads exactly one
authoritative `p cnf N M` header, then reads `0`-terminated clauses (whitespace and newlines are
flexible separators, so a clause may span lines). It rejects a missing or malformed header, counts
above a sane ceiling (which guards the `2*N` watch-buffer allocation against a lying header), a stray
token before the header, a literal whose magnitude exceeds `N`, and a final clause left unterminated
by `0`. The DIMACS 1-based signed literal `v` maps to `2*(v-1) + sign` here, at the boundary only.

`printDimacs :: CNF -> Text` is the canonical printer: the `p cnf N M` header, one clause per line in
original literal order, each terminated by ` 0`. The identity that matters is parse-print-reparse:
`parseDimacs (printDimacs (parseDimacs raw)) == parseDimacs raw`. The input's exact whitespace and
comments are not preserved.

## The graph-to-CNF dual encoder (`SAT/Encode.hs`)

`graphCNF :: Graph -> CNF` is the dual of the CP graph encoder (`Lattice.Encode.Graph.graphModel`):
it turns the same graph-coloring instance into CNF, so the CP engine, the SAT engine, and the
brute-force oracle all solve the genuinely same problem. This is the basis of the CP-vs-SAT race in
the visualizer and the three-way differential test.

The module owns the `var <-> (vertex, color)` map (`colorVar k v c = v*k + c`, color `c` in
`0..k-1`), the same discipline the CP encoder has over its vertex-to-variable map. The encoding is the
textbook direct coloring CNF:

- one boolean `x_{v,c}` per vertex-color pair;
- **at-least-one** per vertex: `(x_{v,0} ∨ ... ∨ x_{v,k-1})`;
- **at-most-one** per vertex, pairwise: `(¬x_{v,c} ∨ ¬x_{v,c'})` for every `c < c'`;
- **edge** per edge `(u,v)` and color `c`: `(¬x_{u,c} ∨ ¬x_{v,c})`, so adjacent vertices differ.

`cnfColoring :: Graph -> [Lit] -> Assignment` decodes a satisfying model back into a vertex-to-color
map in the same `1..k` labels the CP encoder uses (CNF color `c` becomes `c+1`), so a decoded SAT
model is directly comparable to a CP coloring. The CP graph encoder is untouched — the CNF concern is
isolated in this module.

## The two modes, briefly

`solveSat :: CNF -> SatResult` is fast mode: `runST` with a no-op emit and a no-op learn hook, both
inlined so GHC specializes them away to a tight allocation-free `ST` loop (the `-ddump-simpl` check
confirms no event constructor survives the fast path). `solveSatTrace :: Emit IO -> CNF -> IO
SatResult` is the same `cdclLoop` instantiated in `IO` with a streaming emit; both `ST` and `IO` are
`PrimMonad`, so the mutable core is shared verbatim. It streams `Decision`, `Propagate`, `Conflict`,
`Backtrack`, `Learned`, and `Restart` events and a final `Solution` or `Unsat`. The shared two-mode
mechanism is described in full in [ARCHITECTURE.md](ARCHITECTURE.md); the event shapes are in
[PROTOCOL.md](PROTOCOL.md).

## The reference oracle

`src/Lattice/Brute.hs` carries a `2^n` truth-table enumerator (`satisfiableCNF`, `solveAllCNF`) that
checks every clause directly over every possible assignment. It imports only the pure `SAT/Types.hs`
data type — no SAT engine module — so it shares no inference with the CDCL solver and is a sound,
independent reference. It runs only on tiny instances, which is exactly what an oracle is for. How it
gates the engine is in [TESTING.md](TESTING.md).
