// The pure event-replay reducer: it turns the engine's event stream into the visualizer's Sudoku
// domain model. Kept free of React so both the `useSolver` hook and the headless replay check drive
// the exact same logic. Backtracks restore faithfully via a per-decision-level snapshot stack.

import type { PuzzleKind, SolverEvent } from "./protocol";

export type CellStatus = "given" | "open" | "decided" | "solved" | "conflict";

export interface Cell {
  value: number | null;
  candidates: number[];
  status: CellStatus;
}

export type Grid = Cell[];

export interface Counters {
  decisions: number;
  propagations: number;
  backtracks: number;
  conflicts: number;
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
  lastReason: string;
  solved: boolean;
}

export function cloneGrid(grid: Grid): Grid {
  return grid.map((c) => ({ value: c.value, candidates: [...c.candidates], status: c.status }));
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
    counters: { decisions: 0, propagations: 0, backtracks: 0, conflicts: 0 },
    currentDecision: null,
    lastReason: "",
    solved: false,
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
      const cell = grid[ev.cell];
      if (cell) cell.candidates = cell.candidates.filter((x) => x !== ev.removed);
      return {
        ...state,
        grid,
        counters: { ...state.counters, propagations: state.counters.propagations + 1 },
        lastReason: `removed ${ev.removed} from cell ${ev.cell}`,
      };
    }
    case "decision": {
      if (!snapshots.has(ev.level)) snapshots.set(ev.level, cloneGrid(state.grid));
      const cell = grid[ev.cell];
      if (cell) {
        cell.value = ev.value;
        cell.candidates = [ev.value];
        cell.status = "decided";
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
      const snap = snapshots.get(ev.level);
      for (const k of [...snapshots.keys()]) if (k > ev.level) snapshots.delete(k);
      return {
        ...state,
        grid: snap ? cloneGrid(snap) : grid,
        counters: { ...state.counters, backtracks: state.counters.backtracks + 1 },
        currentDecision: null,
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
      return { ...state, lastReason: "no solution" };
    case "stats":
      return {
        ...state,
        counters: {
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
