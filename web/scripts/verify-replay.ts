// Headless verification of the visualizer (VIZ-01/02/03/04) without a browser: connect to a running
// lattice-server, single-step through the whole event stream, replay it through the SAME reducer the
// UI uses (`lib/replay.ts`), and assert the reconstructed state equals the puzzle's known solution.
// Sudoku cases pin an exact grid string (hard-17 also exercises decisions, conflicts, backtracks, and
// the snapshot-restore path). The graph and queens cases reconstruct their solutions from the live
// engine stream and assert the reconstructed assignment is a valid coloring / a valid placement and
// agrees with the engine's own `solution` event (search-order-independent, so a re-ordered but still
// correct solve passes). The CSS motion itself needs a browser; this proves the state it renders is
// correct.
//
//   start lattice-server on :8080, then:  npm run verify:replay

import { parseEvent, type Engine, type PuzzleKind } from "../lib/protocol";
import {
  applyEvent,
  gridToString,
  initialState,
  initialStateForKind,
  type ReplayState,
} from "../lib/replay";

const SERVER = process.env.SOLVER_WS ?? "ws://127.0.0.1:8080/";

// A case carries the kind the server routes on (sent on `start`), the raw definition, and a checker.
// Sudoku uses an exact-string check; graph/queens validate the reconstructed assignment structurally.
// `engine` selects the solver (absent defaults to cp on the server); the SAT case sets it to "sat".
interface Case {
  name: string;
  kind: PuzzleKind;
  puzzle: string;
  engine?: Engine;
  // returns ok + a human detail; given the final reducer state and the engine's solution assignment.
  check: (state: ReplayState, assignment: [number, number][]) => { ok: boolean; detail: string };
}

// The exact-grid check the Sudoku cases use.
function expectGrid(expected: string) {
  return (state: ReplayState): { ok: boolean; detail: string } => {
    const got = gridToString(state.grid);
    const k = state.counters;
    return got === expected
      ? {
          ok: true,
          detail: `reconstructed the solution (${k.decisions} decisions, ${k.propagations} propagations, ${k.backtracks} backtracks)`,
        }
      : { ok: false, detail: `MISMATCH expected=${expected} got=${got}` };
  };
}

// The bundled petersen definition (the same fixed-layout instance the client renders, so web and
// engine check the same graph). Edges and k drive the validity check; x/y are for the view only.
const PETERSEN = {
  k: 3,
  vertexCount: 10,
  edges: [
    [0, 1], [1, 2], [2, 3], [3, 4], [4, 0],
    [0, 5], [1, 6], [2, 7], [3, 8], [4, 9],
    [5, 7], [7, 9], [9, 6], [6, 8], [8, 5],
  ] as [number, number][],
};
const PETERSEN_DEF = JSON.stringify({
  name: "petersen",
  kind: "graph-coloring",
  k: PETERSEN.k,
  vertices: Array.from({ length: PETERSEN.vertexCount }, (_, id) => ({ id, x: 0, y: 0 })),
  edges: PETERSEN.edges,
});

// A valid coloring: every vertex carries a color in 1..k, no edge joins two same-colored vertices,
// and the reducer's reconstructed grid agrees with the engine's solution assignment.
function checkGraphColoring(state: ReplayState, assignment: [number, number][]) {
  const color = new Map<number, number>(assignment);
  for (let v = 0; v < PETERSEN.vertexCount; v++) {
    const cv = color.get(v);
    if (cv === undefined || cv < 1 || cv > PETERSEN.k) {
      return { ok: false, detail: `vertex ${v} has no valid color (got ${cv})` };
    }
    if (state.grid[v]?.value !== cv) {
      return { ok: false, detail: `reducer/engine disagree at vertex ${v}` };
    }
  }
  for (const [u, w] of PETERSEN.edges) {
    if (color.get(u) === color.get(w)) {
      return { ok: false, detail: `edge ${u}-${w} is monochromatic (color ${color.get(u)})` };
    }
  }
  const k = state.counters;
  return {
    ok: true,
    detail: `valid ${PETERSEN.k}-coloring (${k.decisions} decisions, ${k.propagations} propagations, ${k.backtracks} backtracks)`,
  };
}

// Structural validity of a vertex -> color map against PETERSEN: every vertex carries a color in 1..k
// and no edge is monochromatic. The edge-disjoint half of checkGraphColoring, factored so the race's
// SAT side (which has no reducer-grid-in-vertex-coordinates to compare against) can reuse it.
function validColoring(color: Map<number, number>): { ok: boolean; detail: string } {
  for (let v = 0; v < PETERSEN.vertexCount; v++) {
    const cv = color.get(v);
    if (cv === undefined || cv < 1 || cv > PETERSEN.k) {
      return { ok: false, detail: `vertex ${v} has no valid color (got ${cv})` };
    }
  }
  for (const [u, w] of PETERSEN.edges) {
    if (color.get(u) === color.get(w)) {
      return { ok: false, detail: `edge ${u}-${w} is monochromatic (color ${color.get(u)})` };
    }
  }
  return { ok: true, detail: `valid ${PETERSEN.k}-coloring` };
}

// Decode a SAT race solution into a vertex -> color map, the inverse of the engine's graphCNF dual
// encoder (Lattice.SAT.Encode.cnfColoring): one boolean x_{v,c} per (vertex, color) lives at CNF
// variable v*k + c (color c in 0..k-1), and a vertex's color is the c whose variable is true, reported
// in the same 1..k labels the CP side uses (c -> c+1). The `solution` assignment is [variable, polarity]
// in puzzle/variable coordinates (0-based variable, polarity 0/1), so a true polarity marks the color.
function decodeSatColoring(assignment: [number, number][]): Map<number, number> {
  const truth = new Map<number, number>(assignment); // variable -> polarity (0/1)
  const color = new Map<number, number>();
  for (let v = 0; v < PETERSEN.vertexCount; v++) {
    for (let c = 0; c < PETERSEN.k; c++) {
      if (truth.get(v * PETERSEN.k + c) === 1) {
        color.set(v, c + 1);
        break;
      }
    }
  }
  return color;
}

// The bundled nonogram fixtures (the same instances the client renders). The heart is the easy
// round-trip picture; the hard one is a 7x7 that needs search past line arc-consistency, so its
// stream must contain at least one backtrack (the programmatic VIZ-07 gate). Definitions carry the
// rows/cols + clues the server parses; the flat solution string is what the reducer reconstructs.
const HEART_DEF = JSON.stringify({
  name: "heart",
  kind: "nonogram",
  rows: 10,
  cols: 10,
  rowClues: [[2, 2], [4, 4], [10], [10], [10], [8], [6], [4], [2], []],
  colClues: [[4], [6], [7], [7], [7], [7], [7], [7], [6], [4]],
});
const HEART_SOLUTION =
  "0110000110" +
  "1111001111" +
  "1111111111" +
  "1111111111" +
  "1111111111" +
  "0111111110" +
  "0011111100" +
  "0001111000" +
  "0000110000" +
  "0000000000";

const HARD_NONOGRAM_DEF = JSON.stringify({
  name: "hard",
  kind: "nonogram",
  rows: 7,
  cols: 7,
  rowClues: [[1, 1], [2], [], [2, 1], [1, 4], [4], [2]],
  colClues: [[1, 1], [1, 1], [1], [1, 3], [3], [3], [1, 2]],
});
const HARD_NONOGRAM_SOLUTION =
  "0001001" + "1100000" + "0000000" + "0110010" + "1001111" + "0001111" + "0001100";

// A nonogram check: the reconstructed 0/1 grid equals the known solution. The cell-boolean encoding
// renders each cell's value (0 or 1) straight into the reducer grid, so gridToString is the picture.
function checkNonogram(expected: string) {
  return (state: ReplayState): { ok: boolean; detail: string } => {
    const got = gridToString(state.grid);
    const k = state.counters;
    return got === expected
      ? {
          ok: true,
          detail: `reconstructed the picture (${k.decisions} decisions, ${k.propagations} propagations, ${k.backtracks} backtracks)`,
        }
      : { ok: false, detail: `MISMATCH expected=${expected} got=${got}` };
  };
}

// The hard-nonogram gate: the picture must reconstruct AND the stream must contain >= 1 backtrack
// (a zero-backtrack stream means the instance solved by pure propagation and is NOT exercising
// search, so it fails the case). This is the programmatic proof the hard fixture struggles (VIZ-07).
function checkHardNonogram(expected: string) {
  return (state: ReplayState): { ok: boolean; detail: string } => {
    const got = gridToString(state.grid);
    const k = state.counters;
    if (got !== expected) {
      return { ok: false, detail: `MISMATCH expected=${expected} got=${got}` };
    }
    if (k.backtracks < 1) {
      return {
        ok: false,
        detail: `solved with 0 backtracks (${k.decisions} decisions) - the hard fixture is not exercising search`,
      };
    }
    return {
      ok: true,
      detail: `reconstructed and backtracked (${k.decisions} decisions, ${k.propagations} propagations, ${k.backtracks} backtracks >= 1)`,
    };
  };
}

// A valid N-queens placement: one queen per row (cell = row, value = column), columns distinct, and
// both diagonals distinct; the reducer's row cells agree with the engine's assignment.
function checkQueens(n: number) {
  return (state: ReplayState, assignment: [number, number][]) => {
    const col = new Map<number, number>(assignment);
    const cols = new Set<number>();
    const up = new Set<number>();
    const down = new Set<number>();
    for (let r = 0; r < n; r++) {
      const c = col.get(r);
      if (c === undefined || c < 0 || c >= n) {
        return { ok: false, detail: `row ${r} has no valid column (got ${c})` };
      }
      if (state.grid[r]?.value !== c) {
        return { ok: false, detail: `reducer/engine disagree at row ${r}` };
      }
      if (cols.has(c) || up.has(r + c) || down.has(r - c)) {
        return { ok: false, detail: `queens attack: row ${r} col ${c}` };
      }
      cols.add(c);
      up.add(r + c);
      down.add(r - c);
    }
    const k = state.counters;
    return {
      ok: true,
      detail: `valid ${n}-queens placement (${k.decisions} decisions, ${k.propagations} propagations, ${k.backtracks} backtracks)`,
    };
  };
}

// The bundled sat-demo CNF (a copy of puzzles/cnf/sat-demo.cnf): a small satisfiable instance over 3
// variables. The server's `dimacs` kind parses this raw text via the total parseDimacs; the SAT engine
// solves it and streams the reasoning, ending in a `solution` whose assignment must satisfy every clause.
const SAT_DEMO_CNF = "c sat-demo over 3 variables\np cnf 3 3\n1 -2 0\n2 3 0\n-1 -3 0\n";

// Parse DIMACS clauses into arrays of signed 1-based literals (the same convention the engine's
// `solution` assignment and `learn` clauses use). Comments and the header are skipped; this is the
// independent oracle side of the check, so it shares no code with the engine's own parser.
function parseDimacsClauses(text: string): number[][] {
  const toks = text
    .split("\n")
    .filter((line) => !/^\s*(c|p)\b/.test(line))
    .join(" ")
    .split(/\s+/)
    .filter((t) => t.length > 0)
    .map(Number);
  const clauses: number[][] = [];
  let cur: number[] = [];
  for (const lit of toks) {
    if (lit === 0) {
      clauses.push(cur);
      cur = [];
    } else {
      cur.push(lit);
    }
  }
  return clauses;
}

// A SAT check: reconstruct the satisfying assignment from the engine's `solution` event (each pair is
// `[variable, polarity]`, polarity 0/1 in puzzle coordinates) and assert it satisfies every clause of
// the CNF. A clause is satisfied when at least one of its signed literals is true under the assignment
// (a positive literal `v` true iff variable `v-1` is 1; a negative literal `-v` true iff it is 0). This
// is the structural validator (the checkGraphColoring analog), not an exact-string check.
function checkCnf(cnfText: string) {
  const clauses = parseDimacsClauses(cnfText);
  return (_state: ReplayState, assignment: [number, number][]) => {
    const value = new Map<number, number>(assignment); // variable -> polarity (0/1)
    for (const clause of clauses) {
      const sat = clause.some((lit) => {
        const v = Math.abs(lit) - 1; // engine variable is 0-based; DIMACS is 1-based
        const pol = value.get(v);
        if (pol === undefined) return false;
        return lit > 0 ? pol === 1 : pol === 0;
      });
      if (!sat) {
        return { ok: false, detail: `clause [${clause.join(" ")}] is unsatisfied by the assignment` };
      }
    }
    return {
      ok: true,
      detail: `reconstructed a satisfying assignment for all ${clauses.length} clauses`,
    };
  };
}

const CASES: Case[] = [
  {
    name: "diff-4x4",
    kind: "sudoku",
    puzzle: "1...\n...2\n.3..\n..4.",
    check: expectGrid("1234341243212143"),
  },
  {
    name: "easy",
    kind: "sudoku",
    puzzle: "53..7....\n6..195...\n.98....6.\n8...6...3\n4..8.3..1\n7...2...6\n.6....28.\n...419..5\n....8..79",
    check: expectGrid(
      "534678912672195348198342567859761423426853791713924856961537284287419635345286179",
    ),
  },
  {
    name: "hard-17",
    kind: "sudoku",
    puzzle: ".......1.\n4........\n.2.......\n....5.4.7\n..8...3..\n..1.9....\n3..4..2..\n.5.1.....\n...8.6...",
    check: expectGrid(
      "693784512487512936125963874932651487568247391741398625319475268856129743274836159",
    ),
  },
  {
    name: "graph-petersen",
    kind: "graph",
    puzzle: PETERSEN_DEF,
    check: checkGraphColoring,
  },
  {
    name: "queens-8",
    kind: "queens",
    puzzle: "8",
    check: checkQueens(8),
  },
  {
    name: "nonogram-heart",
    kind: "nonogram",
    puzzle: HEART_DEF,
    check: checkNonogram(HEART_SOLUTION),
  },
  {
    name: "nonogram-hard",
    kind: "nonogram",
    puzzle: HARD_NONOGRAM_DEF,
    check: checkHardNonogram(HARD_NONOGRAM_SOLUTION),
  },
  {
    name: "sat-dimacs",
    kind: "dimacs",
    puzzle: SAT_DEMO_CNF,
    engine: "sat",
    check: checkCnf(SAT_DEMO_CNF),
  },
];

function initialFor(c: Case): ReplayState {
  return c.kind === "sudoku" ? initialState(c.puzzle) : initialStateForKind(c.kind, c.puzzle);
}

function runCase(c: Case): Promise<{ name: string; ok: boolean; detail: string }> {
  return new Promise((resolve) => {
    const ws = new WebSocket(SERVER);
    let state: ReplayState = initialFor(c);
    let settled = false;
    const finish = (ok: boolean, detail: string) => {
      if (settled) return;
      settled = true;
      ws.close();
      resolve({ name: c.name, ok, detail });
    };
    ws.addEventListener("open", () =>
      // send the kind so the server routes the definition to the right encoder, and the engine so a
      // SAT case runs the CDCL solver (absent, the server defaults to cp).
      ws.send(
        JSON.stringify({
          v: 1,
          t: "start",
          kind: c.kind,
          puzzle: c.puzzle,
          mode: "trace",
          ...(c.engine ? { engine: c.engine } : {}),
        }),
      ),
    );
    ws.addEventListener("message", (e) => {
      const ev = parseEvent(String((e as MessageEvent).data));
      if (!ev) return;
      state = applyEvent(state, ev);
      if (ev.t === "solution") {
        const { ok, detail } = c.check(state, ev.assignment);
        finish(ok, detail);
      } else if (ev.t === "unsat") {
        finish(false, "engine reported unsat for a solvable instance");
      } else {
        ws.send(JSON.stringify({ t: "step" }));
      }
    });
    ws.addEventListener("error", () => finish(false, "websocket error (is lattice-server on :8080?)"));
    setTimeout(() => finish(false, "timed out"), 30000);
  });
}

// The race case (SAT-06 / CR-01): one `start` with engine "race" forks BOTH engines over one socket on
// the SAME dual-encoded graph, every event engine-tagged. This is the headless peer of the two-panel UI
// flow, the one race path that was previously only checked by a one-off probe. It asserts the contract
// the panel split depends on:
//   - EVERY streamed event carries an `engine` tag (an untagged event would be dropped by the split and
//     cannot belong to a panel — threat T-05-22; one untagged event fails the case);
//   - the stream routes into two independent reducer states by tag, exactly as `useSolver` does;
//   - BOTH engines resolve (each reaches its own `solution`/`unsat`) on the genuinely same instance;
//   - the CP side reconstructs a valid k-coloring (the existing checkGraphColoring) AND the SAT side's
//     satisfying assignment decodes (via the graphCNF v*k+c map) to a valid k-coloring too.
// The race runs in play mode (the server forks the two solve threads blocked on their gates), so the
// client sends `play` after `start` to release both engines to completion rather than single-stepping.
function runRaceCase(): Promise<{ name: string; ok: boolean; detail: string }> {
  const name = "race-petersen";
  return new Promise((resolve) => {
    const ws = new WebSocket(SERVER);
    // Two independent reducer states, one per engine, routed by the event's `engine` tag — the same
    // split `useSolver` runs over the one socket. The SAT side seeds as a dimacs trail; it grows on
    // demand as high-id variable events arrive, so the seed size is not load-bearing for the check.
    const cp: ReplayState = initialStateForKind("graph", PETERSEN_DEF);
    const sat: ReplayState = initialStateForKind(
      "dimacs",
      `p cnf ${PETERSEN.vertexCount * PETERSEN.k} 0\n`,
    );
    const states = { cp, sat };
    // Each engine's `solution`/`unsat` payload, captured when it resolves; the case finishes once BOTH
    // sides are set so neither engine's result is missed.
    const result: { cp?: [number, number][] | "unsat"; sat?: [number, number][] | "unsat" } = {};
    let untagged = 0;
    let settled = false;
    const finish = (ok: boolean, detail: string) => {
      if (settled) return;
      settled = true;
      ws.close();
      resolve({ name, ok, detail });
    };

    const tryComplete = () => {
      if (result.cp === undefined || result.sat === undefined) return; // wait for both engines
      if (untagged > 0) {
        return finish(false, `${untagged} event(s) streamed without an engine tag (the split drops them)`);
      }
      if (result.cp === "unsat" || result.sat === "unsat") {
        return finish(false, "an engine reported unsat for the 3-colorable petersen instance");
      }
      const cpCheck = checkGraphColoring(states.cp, result.cp);
      if (!cpCheck.ok) return finish(false, `cp side: ${cpCheck.detail}`);
      const satColoring = decodeSatColoring(result.sat);
      const satCheck = validColoring(satColoring);
      if (!satCheck.ok) return finish(false, `sat side: ${satCheck.detail}`);
      const kc = states.cp.counters;
      const ks = states.sat.counters;
      finish(
        true,
        `both engines resolved on one tagged stream (cp ${cpCheck.detail.split(" (")[1]?.replace(")", "") ?? "valid"}; ` +
          `sat valid ${PETERSEN.k}-coloring, ${ks.decisions} decisions / ${ks.propagations} propagations / ${kc.backtracks + ks.backtracks} backtracks total)`,
      );
    };

    ws.addEventListener("open", () => {
      ws.send(
        JSON.stringify({ v: 1, t: "start", kind: "graph", puzzle: PETERSEN_DEF, mode: "trace", engine: "race" }),
      );
      // Release both engines: the race forks two solve threads blocked on their gates, and the play loop
      // releases both per tick (no single-step). A fast speed keeps the small instance well inside the timeout.
      ws.send(JSON.stringify({ v: 1, t: "play", speed: 200 }));
    });

    ws.addEventListener("message", (e) => {
      const ev = parseEvent(String((e as MessageEvent).data));
      if (!ev) return;
      // The tag is the contract the panel split depends on: an untagged event cannot be routed. Count it
      // (so the case fails) and skip it rather than corrupting a side.
      if (ev.engine !== "cp" && ev.engine !== "sat") {
        untagged++;
        return;
      }
      const side = ev.engine; // "cp" | "sat"
      states[side] = applyEvent(states[side], ev);
      if (ev.t === "solution") {
        if (result[side] === undefined) result[side] = ev.assignment;
        tryComplete();
      } else if (ev.t === "unsat") {
        if (result[side] === undefined) result[side] = "unsat";
        tryComplete();
      }
    });
    ws.addEventListener("error", () => finish(false, "websocket error (is lattice-server on :8080?)"));
    setTimeout(() => finish(false, "timed out waiting for both race engines to resolve"), 30000);
  });
}

let allOk = true;
for (const c of CASES) {
  const r = await runCase(c);
  console.log(`${r.ok ? "PASS" : "FAIL"}  ${r.name}: ${r.detail}`);
  if (!r.ok) allOk = false;
}
const race = await runRaceCase();
console.log(`${race.ok ? "PASS" : "FAIL"}  ${race.name}: ${race.detail}`);
if (!race.ok) allOk = false;
process.exit(allOk ? 0 : 1);
