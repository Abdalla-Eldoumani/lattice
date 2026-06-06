// The wire protocol between the Haskell engine and this front end. This is the TypeScript side
// of a contract whose other side is the `Lattice.Event` ADT and its aeson instances in the
// engine. The two are kept in sync by hand: when you change one, change the other in the same
// commit. The wire form is JSON with a version field `v` and a tag field `t`.
//
// Events speak in PUZZLE coordinates (cell indices, vertex ids), never internal solver variable
// ids. The encoder owns that mapping so the UI never has to translate.

export const PROTOCOL_VERSION = 1 as const;

// In dev, the Haskell server runs separately in WSL bound to 127.0.0.1; WSL2 forwards localhost
// to the host browser. Override with NEXT_PUBLIC_SOLVER_WS if you bind elsewhere.
export const SOLVER_WS_URL =
  process.env.NEXT_PUBLIC_SOLVER_WS ?? "ws://127.0.0.1:8080/ws";

// ---------------------------------------------------------------------------
// Server -> client: the reasoning stream.
// ---------------------------------------------------------------------------

export type Engine = "cp" | "sat";
export type Mode = "trace" | "fast";

export interface Stats {
  decisions: number;
  propagations: number;
  backtracks: number;
  conflicts: number;
  learned: number; // SAT only; 0 for CP
}

// A decision: the search picked a value for a variable because propagation stalled.
export interface DecisionEvent {
  v: typeof PROTOCOL_VERSION;
  t: "decision";
  cell: number; // puzzle coordinate (e.g. flat Sudoku index 0..80)
  value: number;
  level: number; // decision level
}

// A propagation step: value `removed` was eliminated from `cell` because of `reason`.
export interface PropagateEvent {
  v: typeof PROTOCOL_VERSION;
  t: "propagate";
  cell: number;
  removed: number;
  reason: string; // human-readable constraint label, e.g. "row 3 all-different"
}

// A conflict: a domain emptied (CP) or a clause is falsified (SAT).
export interface ConflictEvent {
  v: typeof PROTOCOL_VERSION;
  t: "conflict";
  cell: number; // where the contradiction surfaced
}

// A backtrack/backjump: the search returned to `toLevel`, undoing the listed cells.
export interface BacktrackEvent {
  v: typeof PROTOCOL_VERSION;
  t: "backtrack";
  toLevel: number;
  undone: number[]; // cells whose assignments were undone
}

// SAT only: a clause learned from conflict analysis (1UIP). Literals are signed puzzle-relative
// codes; positive and negative encode polarity.
export interface LearnedEvent {
  v: typeof PROTOCOL_VERSION;
  t: "learned";
  literals: number[];
}

// SAT only: a restart fired (Luby schedule).
export interface RestartEvent {
  v: typeof PROTOCOL_VERSION;
  t: "restart";
}

// A full solution assignment, puzzle-relative.
export interface SolutionEvent {
  v: typeof PROTOCOL_VERSION;
  t: "solution";
  assignment: number[]; // value per cell, in puzzle order
}

// A sound proof that no solution exists, for instances where that is in scope.
export interface UnsatEvent {
  v: typeof PROTOCOL_VERSION;
  t: "unsat";
}

// Running counters, emitted periodically so the thinking panel stays live without one message
// per counter tick.
export interface StatsEvent {
  v: typeof PROTOCOL_VERSION;
  t: "stats";
  stats: Stats;
}

export type SolverEvent =
  | DecisionEvent
  | PropagateEvent
  | ConflictEvent
  | BacktrackEvent
  | LearnedEvent
  | RestartEvent
  | SolutionEvent
  | UnsatEvent
  | StatsEvent;

// ---------------------------------------------------------------------------
// Client -> server: control.
// ---------------------------------------------------------------------------

export interface StartControl {
  v: typeof PROTOCOL_VERSION;
  t: "start";
  puzzle: string; // puzzle id or inline spec the server can resolve
  engine: Engine;
  mode: Mode;
}

export interface StepControl {
  v: typeof PROTOCOL_VERSION;
  t: "step"; // advance exactly one event (single-step)
}

export interface PlayControl {
  v: typeof PROTOCOL_VERSION;
  t: "play";
  speed: number; // events per second
}

export interface PauseControl {
  v: typeof PROTOCOL_VERSION;
  t: "pause";
}

export interface RestartControl {
  v: typeof PROTOCOL_VERSION;
  t: "restart";
}

export type SolverControl =
  | StartControl
  | StepControl
  | PlayControl
  | PauseControl
  | RestartControl;

// Narrowing helpers. Validate the version on receipt so a protocol bump fails loudly rather
// than rendering garbage.
export function parseEvent(raw: string): SolverEvent | null {
  try {
    const msg = JSON.parse(raw) as SolverEvent;
    if (msg.v !== PROTOCOL_VERSION) return null;
    return msg;
  } catch {
    return null;
  }
}
