// The pure event-replay reducer: it turns the engine's event stream into the visualizer's Sudoku
// domain model. Kept free of React so both the `useSolver` hook and the headless replay check drive
// the exact same logic. Backtracks restore faithfully via a per-decision-level snapshot stack.

import type { SolverEvent } from "./protocol";

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

export function initialState(text: string): ReplayState {
  const { grid, size } = parseGridText(text);
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
