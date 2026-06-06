# Puzzle formats

Sample instances the engine and the gallery load. Every instance here has been verified:
Sudoku puzzles have exactly one solution, the graph carries a fixed layout, and each `hard`
preset is verified to make the search backtrack (see Hard presets below).

## Sudoku (`sudoku/*.txt`)

Plain text, one row per line, one character per cell, row-major. A digit is a given;
`.` or `0` is an empty cell. A 9x9 puzzle is 9 lines of 9 characters (box 3x3); a 4x4
puzzle is 4 lines of 4 characters (box 2x2). The parser accepts both `.` and `0` for
blanks and ignores trailing whitespace.

The 4x4 file exists for brute-force differential tests: it is small enough to enumerate
all solutions exhaustively and compare against the engine.

## Graph coloring (`graph/*.json`)

```
{ "name", "kind": "graph-coloring", "k": <colors>,
  "vertices": [ { "id", "x", "y" } ],   // x,y are fixed layout coordinates
  "edges":    [ [u, v], ... ] }          // undirected, vertex ids
```

`k` is the number of colors to try. Coordinates are precomputed so the visualizer renders
a stable layout and never re-runs a force simulation. Adjacency drives the solver
(an all-different / not-equal constraint per edge).

`graph/hard.json` is a dense 10-vertex 4-chromatic graph (uncolorable at k=3) chosen so the
CP search backtracks 3 times before recovering at k=4. The named Grotzsch graph was tried
first but colors greedily (0 backtracks) under this engine's LCV value ordering, so a
verified-backtracking instance ships instead.

## Nonogram (`nonogram/*.json`)

```
{ "name", "kind": "nonogram",
  "rows": <r>, "cols": <c>,
  "rowClues": [ [run, ...], ... ],   // one run-length list per row, top to bottom
  "colClues": [ [run, ...], ... ],   // one run-length list per column, left to right
  "solution": [ "0110...", ... ] }   // optional: the 0/1 picture, one string per row
```

The encoder builds one boolean variable per cell (0 blank, 1 ink) and one `LineClue`
constraint per row and column. Keep lines short (<= ~15 cells) so the propagator's placement
enumeration stays cheap. `nonogram/heart.json` is the 10x10 round-trip picture;
`nonogram/hard.json` is a 7x7 that needs search past line arc-consistency (10 decisions,
4 backtracks under MRV).

## CNF (`cnf/*.cnf`)

Standard DIMACS CNF. Lines beginning `c` are comments; one header `p cnf <vars> <clauses>`
declares the variable and clause counts; each clause is a list of signed 1-based literals
terminated by `0` (a clause may span lines). The parser (`Lattice.SAT.Dimacs`) maps the
1-based signed DIMACS integers to the engine's 0-based `2*var+sign` encoding at the boundary
only, rejects malformed input as a `Left` (missing/bad header, a literal magnitude past the
declared var count, a missing terminator, an out-of-range header), and the canonical printer
preserves literal order (it drops comments and normalizes whitespace, but never sorts).

These fixtures are tiny so the exhaustive `2^n` CNF oracle (`Lattice.Brute.satisfiableCNF`)
checks them instantly:

- `cnf/sat-demo.cnf` — satisfiable (3 vars, 3 clauses); a witness is x1=true, x2=true, x3=false.
- `cnf/unsat-demo.cnf` — unsatisfiable (1 var, 2 clauses); the unit clauses `(x1)` and `(not x1)`
  contradict.

## N-queens

Parametric, no file. The CLI and gallery take `N` directly. `queens · 12 (hard)` in the
gallery is the hard preset: N=12 backtracks 33 times before placing all twelve queens.

## Hard presets (VIZ-07)

Each puzzle kind has a `hard` preset in the gallery picker that makes the search visibly
struggle and recover. The rule for a hard preset: it must be solvable AND its event stream
must contain at least one `backtrack` (a fixture that solves by pure propagation does not
exercise search). The `verify-replay` nonogram-hard case asserts `backtracks >= 1`
programmatically, and the graph / queens hard presets were verified to backtrack with the
engine (counting `Backtrack` events via `solveTrace`) before commit.

## Adding instances

Verify before committing: a Sudoku or nonogram instance must have exactly one solution
(check with the brute-force solver or independent placement enumeration), a graph instance
must include coordinates for every vertex, and a `hard` preset must be verified to backtrack
with the engine. Do not commit an instance you have not verified.
