# Puzzle formats

Sample instances the engine and the gallery load. Every instance here has been verified:
Sudoku puzzles have exactly one solution, the graph carries a fixed layout.

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

## N-queens

Parametric, no file. The CLI and gallery take `N` directly.

## Adding instances

Verify before committing: a Sudoku instance must have exactly one solution (check with the
brute-force solver), and a graph instance must include coordinates for every vertex. Do not
commit an instance you have not verified.
