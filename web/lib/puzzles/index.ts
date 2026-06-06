// The client-owned puzzle definitions. The client owns the puzzle definition (it renders geometry
// from its own copy) and sends the raw `definition` string to the server on `start`; the server only
// needs the definition to build the model. Each entry is keyed by its picker key and carries the
// `kind` the server routes on plus the human label the picker shows.
//
// The Sudoku entries carry the grid text that was previously inline in page.tsx. The graph entry
// bundles a copy of puzzles/graph/petersen.json as a string. queens carries N as text. The nonogram
// entries bundle copies of puzzles/nonogram/*.json so the client renders the same fixture the engine
// round-trips.

import type { PuzzleKind } from "../protocol";

export interface PuzzleDef {
  kind: PuzzleKind;
  label: string;
  definition: string;
  // A dual-encodable instance (one the server can build as BOTH a CP model and a CNF) can race the
  // two engines; the engine picker offers `cp vs sat` only for these. Graph coloring is the dual-
  // encodable kind (graphCNF); the dimacs fixtures are SAT-only, the CP puzzles CP-only.
  dualEncodable?: boolean;
}

// A copy of puzzles/graph/petersen.json, bundled so the client owns its definition. The server's
// graph encoder reads `k`, `vertices`, and `edges`; the `x,y` layout is for the view (VIZ-06).
const PETERSEN = JSON.stringify({
  name: "petersen",
  kind: "graph-coloring",
  k: 3,
  vertices: [
    { id: 0, x: 200.0, y: 50.0 },
    { id: 1, x: 342.7, y: 153.6 },
    { id: 2, x: 288.2, y: 321.4 },
    { id: 3, x: 111.8, y: 321.4 },
    { id: 4, x: 57.3, y: 153.6 },
    { id: 5, x: 200.0, y: 135.0 },
    { id: 6, x: 261.8, y: 179.9 },
    { id: 7, x: 238.2, y: 252.6 },
    { id: 8, x: 161.8, y: 252.6 },
    { id: 9, x: 138.2, y: 179.9 },
  ],
  edges: [
    [0, 1], [1, 2], [2, 3], [3, 4], [4, 0],
    [0, 5], [1, 6], [2, 7], [3, 8], [4, 9],
    [5, 7], [7, 9], [9, 6], [6, 8], [8, 5],
  ],
});

// A copy of puzzles/nonogram/heart.json, bundled so the client renders the same fixture the engine
// round-trips. The server's nonogram encoder reads rows/cols and the row/column clues; `solution` is
// for the engine fixture's golden pin and is read past here.
const HEART = JSON.stringify({
  name: "heart",
  kind: "nonogram",
  rows: 10,
  cols: 10,
  rowClues: [[2, 2], [4, 4], [10], [10], [10], [8], [6], [4], [2], []],
  colClues: [[4], [6], [7], [7], [7], [7], [7], [7], [6], [4]],
});

// A copy of puzzles/nonogram/hard.json: a 7x7 nonogram that needs search past line arc-consistency
// (10 decisions, 4 backtracks under MRV), so the search visibly struggles and recovers (VIZ-07).
const HARD_NONOGRAM = JSON.stringify({
  name: "hard",
  kind: "nonogram",
  rows: 7,
  cols: 7,
  rowClues: [[1, 1], [2], [], [2, 1], [1, 4], [4], [2]],
  colClues: [[1, 1], [1, 1], [1], [1, 3], [3], [3], [1, 2]],
});

// A copy of puzzles/graph/hard.json: a dense 10-vertex 4-chromatic graph (uncolorable at k=3) that
// backtracks 3 times before recovering at k=4 (VIZ-07). The fixed circular layout drives the view.
const HARD_GRAPH = JSON.stringify({
  name: "hard",
  kind: "graph-coloring",
  k: 4,
  vertices: [
    { id: 0, x: 200.0, y: 40.0 },
    { id: 1, x: 294.0, y: 70.6 },
    { id: 2, x: 352.2, y: 150.6 },
    { id: 3, x: 352.2, y: 249.4 },
    { id: 4, x: 294.0, y: 329.4 },
    { id: 5, x: 200.0, y: 360.0 },
    { id: 6, x: 106.0, y: 329.4 },
    { id: 7, x: 47.8, y: 249.4 },
    { id: 8, x: 47.8, y: 150.6 },
    { id: 9, x: 106.0, y: 70.6 },
  ],
  edges: [
    [0, 1], [0, 3], [0, 5], [0, 6], [0, 9],
    [1, 3], [1, 4], [1, 6], [1, 7],
    [2, 4], [2, 7], [2, 8], [2, 9],
    [3, 4], [3, 7],
    [4, 7], [4, 8], [4, 9],
    [5, 6], [5, 9],
    [6, 7], [6, 8], [6, 9],
    [7, 8],
    [8, 9],
  ],
});

// Copies of puzzles/cnf/sat-demo.cnf and unsat-demo.cnf, bundled as raw DIMACS text so the client
// owns the definition and the TrailView seeds its variable count from the `p cnf N M` header. The
// server's dimacs arm runs parseDimacs over the same text. sat-demo is satisfiable (x1,x2 true,
// x3 false); unsat-demo's two unit clauses (x1) and (¬x1) contradict.
const SAT_DEMO_CNF =
  "c sat-demo: a small satisfiable CNF over 3 variables.\n" +
  "c A satisfying assignment is x1=true, x2=true, x3=false.\n" +
  "p cnf 3 3\n" +
  "1 -2 0\n" +
  "2 3 0\n" +
  "-1 -3 0\n";

const UNSAT_DEMO_CNF =
  "c unsat-demo: a small unsatisfiable CNF over 1 variable.\n" +
  "c The unit clauses (x1) and (not x1) contradict, so no assignment satisfies both.\n" +
  "p cnf 1 2\n" +
  "1 0\n" +
  "-1 0\n";

// The picker entries, in display order. The first key is the default selection.
export const PUZZLES: Record<string, PuzzleDef> = {
  "sudoku-easy": {
    kind: "sudoku",
    label: "sudoku · easy",
    definition:
      "53..7....\n6..195...\n.98....6.\n8...6...3\n4..8.3..1\n7...2...6\n.6....28.\n...419..5\n....8..79",
  },
  "sudoku-hard-17": {
    kind: "sudoku",
    label: "sudoku · hard-17",
    definition:
      ".......1.\n4........\n.2.......\n....5.4.7\n..8...3..\n..1.9....\n3..4..2..\n.5.1.....\n...8.6...",
  },
  "sudoku-4x4": {
    kind: "sudoku",
    label: "sudoku · 4x4",
    definition: "1...\n...2\n.3..\n..4.",
  },
  "graph-petersen": {
    kind: "graph",
    label: "graph · petersen",
    definition: PETERSEN,
    // Dual-encodable: the server builds both the CP graph model and graphCNF from this, so it can
    // race cp vs sat on the genuinely same instance (the race two-panel layout lands in plan 08).
    dualEncodable: true,
  },
  "graph-hard": {
    kind: "graph",
    label: "graph · hard",
    definition: HARD_GRAPH,
  },
  "queens-8": {
    kind: "queens",
    label: "queens · 8",
    definition: "8",
  },
  "queens-12-hard": {
    kind: "queens",
    label: "queens · 12 (hard)",
    definition: "12",
  },
  "nonogram-picture": {
    kind: "nonogram",
    label: "nonogram · picture",
    definition: HEART,
  },
  "nonogram-hard": {
    kind: "nonogram",
    label: "nonogram · hard",
    definition: HARD_NONOGRAM,
  },
  "cnf-sat-demo": {
    kind: "dimacs",
    label: "cnf · sat-demo",
    definition: SAT_DEMO_CNF,
  },
  "cnf-unsat-demo": {
    kind: "dimacs",
    label: "cnf · unsat-demo",
    definition: UNSAT_DEMO_CNF,
  },
};

// The default picker selection on first paint.
export const DEFAULT_PUZZLE_KEY = "sudoku-easy";
