// The pure event-replay reducer: it turns the engine's event stream into the visualizer's Sudoku
// domain model. Kept free of React so both the `useSolver` hook and the headless replay check drive
// the exact same logic. Backtracks restore faithfully via a per-decision-level snapshot stack.

import type { PuzzleKind, SolverEvent } from "./protocol";

// `propagated` is the SAT trail's "this literal was forced by unit propagation, not chosen"
// status — the TrailView reads it as a plain border (vs the accent ring a `decided` literal gets),
// so the missing ring is the "forced not chosen" cue (the second-signal matrix). The CP renderers
// never set it (their propagation is candidate elimination, not a whole-cell assignment).
export type CellStatus = "given" | "open" | "decided" | "propagated" | "solved" | "conflict";

export interface Cell {
  value: number | null;
  candidates: number[];
  status: CellStatus;
  // The SAT decision level a trail cell was assigned at, so the TrailView can group the assignment
  // vector into level-bands. Undefined for an unassigned cell and for every CP renderer (which group
  // by their own geometry, not by level).
  level?: number;
}

export type Grid = Cell[];

export interface Counters {
  decisions: number;
  propagations: number;
  backtracks: number;
  conflicts: number;
  // The two SAT counters are tallied UI-side from the learn/restart events rather than carried on a
  // widened stats event (the protocol keeps Stats's four CP counters). Zero for a CP stream.
  learnedClauses: number;
  restarts: number;
}

export interface ReplayState {
  grid: Grid;
  size: number;
  // The nonogram needs both grid dimensions to lay out its clue tracks; `size` carries cols and this
  // carries rows. Undefined for square puzzles where `size` alone (n x n) is the shape.
  nonoRows?: number;
  // The snapshot stack is bookkeeping, not rendered; it is mutated in place across a replay.
  snapshots: Map<number, Grid>;
  counters: Counters;
  currentDecision: { cell: number; value: number; level: number } | null;
  // The most recent SAT learned clause, as the signed literal list the `learn` event carried, so the
  // TrailView can render the transient clause chip and ring its on-trail literals. Null until a learn
  // event fires (and on a CP stream, which never emits one).
  learnedClause: number[] | null;
  lastReason: string;
  solved: boolean;
  // Set on the engine's `unsat` event (a sound proof of no solution), the dead-end peer of `solved`.
  // The panel reads it to show the UNSAT result line; without it an unsat run only shows as the
  // "no solution" last-step text and a frozen trail, which a user can miss.
  unsat: boolean;
}

export function cloneGrid(grid: Grid): Grid {
  return grid.map((c) => ({
    value: c.value,
    candidates: [...c.candidates],
    status: c.status,
    level: c.level,
  }));
}

// The hard cap on how far `growGridTo` will extend a SAT trail. It matches the `dimacsVarCount`
// CEILING (the largest variable count the dimacs seed will allocate), so a legitimate solve — whose
// cells never exceed the seeded size — is never clamped, while a hostile or garbled event with a huge
// `cell` (e.g. 2_000_000_000) cannot push ~2 billion cells and OOM the tab.
const MAX_TRAIL_CELLS = 2000;

// Grow a SAT trail grid in place so index `cell` is addressable, pushing `open` cells up to it
// (IN-04). The dimacs seed sizes the trail from the `p cnf N M` header (a bound, sometimes a guess
// for a race's client-side CNF), so a high-id variable's event can reference a cell past the seed; an
// un-grown grid drops it silently (`grid[ev.cell]` is undefined). Growing on demand means the trail
// view never loses a high-variable assignment. CP grids are pre-sized by their geometry and never
// call this. The grow is capped at `MAX_TRAIL_CELLS`: a `cell` past the cap grows only up to it, so
// the out-of-bounds event is bounded-dropped (`grid[cell]` stays undefined and the apply arm's
// `if (cell)` guard skips it) rather than allocating without limit. Returns the same array (mutated)
// for chaining.
function growGridTo(grid: Grid, cell: number): Grid {
  const target = Math.min(cell, MAX_TRAIL_CELLS);
  for (let i = grid.length; i <= target; i++) {
    grid.push({ value: null, candidates: [], status: "open" });
  }
  return grid;
}

// Parse a dot-for-blank, row-per-line grid into the initial domain model (mirrors the engine's
// Sudoku encoder: a digit is a given singleton; '.'/'0' is a blank with the full candidate set).
export function parseGridText(text: string): { grid: Grid; size: number } {
  const rows = text.replace(/\r/g, "").split("\n").filter((r) => r.length > 0);
  const n = rows.length;
  const all = Array.from({ length: n }, (_, i) => i + 1);
  const grid: Grid = [];
  for (const row of rows) {
    for (const ch of row.slice(0, n)) {
      if (ch === "." || ch === "0") {
        grid.push({ value: null, candidates: [...all], status: "open" });
      } else {
        const d = Number(ch);
        grid.push({ value: d, candidates: [d], status: "given" });
      }
    }
  }
  return { grid, size: n };
}

function emptyState(grid: Grid, size: number): ReplayState {
  return {
    grid,
    size,
    snapshots: new Map(),
    counters: {
      decisions: 0,
      propagations: 0,
      backtracks: 0,
      conflicts: 0,
      learnedClauses: 0,
      restarts: 0,
    },
    currentDecision: null,
    learnedClause: null,
    lastReason: "",
    solved: false,
    unsat: false,
  };
}

export function initialState(text: string): ReplayState {
  const { grid, size } = parseGridText(text);
  return emptyState(grid, size);
}

// Build the initial model for a given puzzle kind. The client owns geometry per kind: Sudoku parses
// the grid text; the other kinds seed a non-empty grid of `open` cells (sized from the definition
// where it is cheap to read) so the canvas is never a spinner. The exact geometry of the non-Sudoku
// renderers is their own concern; this only seeds a model the dispatcher can render.
export function initialStateForKind(kind: PuzzleKind, definition: string): ReplayState {
  if (kind === "sudoku") return initialState(definition);
  if (kind === "nonogram") return nonogramInitialState(definition);
  if (kind === "dimacs") return dimacsInitialState(definition);
  const count = seedCount(kind, definition);
  const size = Math.max(1, Math.round(Math.sqrt(count)));
  const grid: Grid = Array.from({ length: count }, () => ({
    value: null,
    candidates: [],
    status: "open" as CellStatus,
  }));
  return emptyState(grid, size);
}

// The nonogram seeds one boolean cell per grid index r*cols + c with the full {0,1} candidate set,
// so a `propagate removed=0/1` tracks which bit a line clue eliminated (the renderer reads the
// remaining candidates: {1} -> forced ink, {0} -> forced blank, {0,1} -> still unknown). `size` is
// `cols` so callers can recover the grid shape; `nonoRows` carries the row count for the renderer.
function nonogramInitialState(definition: string): ReplayState {
  const { rows, cols } = nonogramDims(definition);
  const grid: Grid = Array.from({ length: rows * cols }, () => ({
    value: null,
    candidates: [0, 1],
    status: "open" as CellStatus,
  }));
  return { ...emptyState(grid, cols), nonoRows: rows };
}

// Read the rows/cols from a bundled nonogram definition; a malformed definition falls back to a
// small square so the canvas still renders rather than throwing.
export function nonogramDims(definition: string): { rows: number; cols: number } {
  try {
    const d = JSON.parse(definition) as { rows?: number; cols?: number };
    if (Number.isInteger(d.rows) && Number.isInteger(d.cols) && d.rows! > 0 && d.cols! > 0) {
      return { rows: d.rows!, cols: d.cols! };
    }
  } catch {
    // a malformed definition still seeds a default-sized model
  }
  return { rows: 10, cols: 10 };
}

// The SAT trail seeds one cell per variable (cell index == variable id, the engine's natural mapping
// that every event speaks). Every cell starts unassigned (value null, no glyph); a decision/propagate
// event fills its polarity and level, the TrailView reads them into level-bands.
function dimacsInitialState(definition: string): ReplayState {
  const n = dimacsVarCount(definition);
  const grid: Grid = Array.from({ length: n }, () => ({
    value: null,
    candidates: [],
    status: "open" as CellStatus,
  }));
  // `size` is the variable count; the TrailView lays the vector out itself (level-bands, wrapping),
  // so the sqrt heuristic the other shells use does not apply.
  return { ...emptyState(grid, n) };
}

// Read the variable count from a DIMACS `p cnf N M` problem line (a tiny, bounded, total parse). A
// missing or malformed header falls back to a small default so the canvas still seeds rather than
// throwing (the nonogramDims/seedCount precedent; threat T-05-20). N is clamped to a sane ceiling so
// a hostile header cannot seed an unbounded vector.
export function dimacsVarCount(definition: string): number {
  const DEFAULT = 8;
  const CEILING = 2000;
  for (const line of definition.replace(/\r/g, "").split("\n")) {
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith("c")) continue;
    if (trimmed.startsWith("p")) {
      // `p cnf N M` — the third whitespace token is the variable count.
      const parts = trimmed.split(/\s+/);
      const n = Number(parts[2]);
      if (Number.isInteger(n) && n > 0) return Math.min(n, CEILING);
    }
    // The first non-comment, non-problem line means the header is missing or out of order.
    break;
  }
  return DEFAULT;
}

// How many seed cells a non-Sudoku, non-nonogram kind shows before any event arrives. Read cheaply
// from the definition (graph vertex count, queens N squared); fall back to a small non-empty default.
function seedCount(kind: PuzzleKind, definition: string): number {
  if (kind === "queens") {
    const n = Number(definition.trim());
    return Number.isInteger(n) && n > 0 ? n * n : 64;
  }
  if (kind === "graph") {
    try {
      const vs = (JSON.parse(definition) as { vertices?: unknown[] }).vertices;
      if (Array.isArray(vs) && vs.length > 0) return vs.length;
    } catch {
      // a malformed definition still seeds a default-sized model
    }
    return 10;
  }
  // any future kind: a small non-empty placeholder model
  return 100;
}

// Apply one event, returning the next state. The rendered fields (grid, counters, ...) are produced
// fresh; the snapshot map is carried and mutated in place.
export function applyEvent(state: ReplayState, ev: SolverEvent): ReplayState {
  const grid = cloneGrid(state.grid);
  const snapshots = state.snapshots;
  switch (ev.t) {
    case "propagate": {
      if (ev.engine === "sat") {
        // Grow the trail on demand so a high-id variable past the seed still lands (IN-04).
        growGridTo(grid, ev.cell);
        const cell = grid[ev.cell];
        // A SAT unit propagation assigns the variable its forced polarity (`removed` carries the
        // polarity 0/1 of the forced literal, not a candidate to drop). The TrailView reads the
        // `propagated` status as a plain border — the absence of the decision ring is the "forced,
        // not chosen" second signal. The SAT engine emits forced literals (BCP and the post-backjump
        // asserting literal) as propagates, so this arm fills the trail cell's polarity, level, and
        // propagated status.
        if (cell && cell.value === null) {
          cell.value = ev.removed;
          cell.candidates = [ev.removed];
          cell.status = "propagated";
          cell.level = state.currentDecision?.level ?? 0;
        }
        return {
          ...state,
          grid,
          counters: { ...state.counters, propagations: state.counters.propagations + 1 },
          lastReason: `unit-prop var ${ev.cell} = ${ev.removed}`,
        };
      }
      // CP propagation removes a candidate value from the cell's domain.
      const cpCell = grid[ev.cell];
      if (cpCell) cpCell.candidates = cpCell.candidates.filter((x) => x !== ev.removed);
      return {
        ...state,
        grid,
        counters: { ...state.counters, propagations: state.counters.propagations + 1 },
        lastReason: `removed ${ev.removed} from cell ${ev.cell}`,
      };
    }
    case "decision": {
      // CP restores a backtrack from this per-level snapshot; SAT un-fills by the level-banded wipe in
      // the `backtrack` arm instead (the snapshot is still recorded, harmlessly, for uniformity).
      if (!snapshots.has(ev.level)) snapshots.set(ev.level, cloneGrid(state.grid));
      // SAT now emits a decision per branch (a chosen literal), so grow the trail on demand for a
      // high-id variable past the seed (IN-04); CP grids are pre-sized and stay within bounds.
      if (ev.engine === "sat") growGridTo(grid, ev.cell);
      const cell = grid[ev.cell];
      if (cell) {
        cell.value = ev.value;
        cell.candidates = [ev.value];
        cell.status = "decided";
        // The SAT trail bands by decision level; recording it on the cell lets the TrailView group
        // the assignment vector. The CP renderers ignore the field (they band by their own geometry).
        cell.level = ev.level;
      }
      return {
        ...state,
        grid,
        counters: { ...state.counters, decisions: state.counters.decisions + 1 },
        currentDecision: { cell: ev.cell, value: ev.value, level: ev.level },
      };
    }
    case "conflict": {
      const cell = grid[ev.cell];
      if (cell) cell.status = "conflict";
      return {
        ...state,
        grid,
        counters: { ...state.counters, conflicts: state.counters.conflicts + 1 },
        lastReason: `conflict at cell ${ev.cell}`,
      };
    }
    case "backtrack": {
      for (const k of [...snapshots.keys()]) if (k > ev.level) snapshots.delete(k);
      if (ev.engine === "sat") {
        // SAT backjump un-fill (WR-03). The CP snapshot stack does not apply: a SAT trail bands by
        // decision level, and a non-chronological backjump to `ev.level` un-assigns every variable
        // assigned ABOVE it. Wipe each cell whose `level > ev.level` back to open (the restart wipe
        // below, but bounded by level instead of clearing everything), so stale "assigned" cells at
        // dead levels do not accumulate until the next restart. The asserting literal the engine
        // re-asserts at `ev.level` arrives as the following propagate and re-fills its cell.
        for (const cell of grid) {
          if (
            (cell.status === "decided" || cell.status === "propagated") &&
            cell.level !== undefined &&
            cell.level > ev.level
          ) {
            cell.value = null;
            cell.candidates = [];
            cell.status = "open";
            cell.level = undefined;
          }
        }
        return {
          ...state,
          grid,
          counters: { ...state.counters, backtracks: state.counters.backtracks + 1 },
          currentDecision: null,
        };
      }
      // CP restores the whole grid from the per-decision-level snapshot taken when that level opened.
      const snap = snapshots.get(ev.level);
      return {
        ...state,
        grid: snap ? cloneGrid(snap) : grid,
        counters: { ...state.counters, backtracks: state.counters.backtracks + 1 },
        currentDecision: null,
      };
    }
    case "learn": {
      // SAT 1UIP learned a clause; tally the UI-derived learnedClauses counter (the protocol does not
      // widen Stats, so the count lives here) and carry the clause so the TrailView can render the
      // transient clause chip and ring its on-trail literals. The clause arrives as signed 1-based
      // variable ids (the DIMACS convention); `formatClause` renders it as `¬3 ∨ 7 ∨ ¬12`.
      return {
        ...state,
        counters: { ...state.counters, learnedClauses: state.counters.learnedClauses + 1 },
        learnedClause: ev.clause,
        lastReason: `learned (${formatClause(ev.clause)})`,
      };
    }
    case "restart": {
      // A SAT restart fired (trail unwound to level 0, learned clauses kept). Wipe every assigned trail
      // cell back to unassigned (the trail restart erases the whole assignment) so the TrailView reads
      // the wipe; tally the counter and number the restart for the panel line `restart #k`. Phase saving
      // means polarities often reappear — that re-fill is ordinary propagate/decision animation.
      for (const cell of grid) {
        if (cell.status === "decided" || cell.status === "propagated") {
          cell.value = null;
          cell.candidates = [];
          cell.status = "open";
          cell.level = undefined;
        }
      }
      const restarts = state.counters.restarts + 1;
      return {
        ...state,
        grid,
        counters: { ...state.counters, restarts },
        currentDecision: null,
        learnedClause: null,
        lastReason: `restart #${restarts}`,
      };
    }
    case "solution": {
      for (const [cell, value] of ev.assignment) {
        if (grid[cell]) {
          grid[cell].value = value;
          grid[cell].candidates = [value];
          grid[cell].status = "solved";
        }
      }
      return { ...state, grid, solved: true, currentDecision: null, lastReason: "solved" };
    }
    case "unsat":
      // A sound proof of no solution: set the `unsat` flag (the dead-end peer of `solved`) so the
      // panel renders a clear result line, not just the "no solution" last-step text.
      return { ...state, unsat: true, currentDecision: null, lastReason: "no solution" };
    case "stats":
      // Stats carries the four CP counters authoritatively; the SAT counters are UI-derived, so keep
      // their running tally rather than zeroing them.
      return {
        ...state,
        counters: {
          ...state.counters,
          decisions: ev.decisions,
          propagations: ev.propagations,
          backtracks: ev.backtracks,
          conflicts: ev.conflicts,
        },
      };
  }
}

// Render the current grid as a flat value string (a missing cell is '.'), for golden comparison.
export function gridToString(grid: Grid): string {
  return grid.map((c) => (c.value === null ? "." : String(c.value))).join("");
}

// Render a SAT clause (signed 1-based variable ids) as a math-text disjunction `¬3 ∨ 7 ∨ ¬12`, the
// learned-clause read-out the panel and the TrailView chip show. A negative literal reads `¬|id|`.
export function formatClause(clause: number[]): string {
  if (clause.length === 0) return "⊥"; // an empty clause is the contradiction (outright unsat)
  return clause.map((lit) => (lit < 0 ? `¬${-lit}` : String(lit))).join(" ∨ ");
}
