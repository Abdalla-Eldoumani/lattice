// The wire protocol between the Haskell engine and this front end. This is the TypeScript side of a
// contract whose other side is the `Lattice.Event` / `Lattice.Protocol` ADTs and their aeson
// instances in the engine. The two are kept in sync by hand: when you change one, change the other
// in the same commit. The wire form is JSON with a version field `v` and a tag field `t`.
//
// Events speak in PUZZLE coordinates (cell indices), never internal solver variable ids — for
// Sudoku the cell index is the variable index.

export const PROTOCOL_VERSION = 1 as const;

// The Haskell server runs in WSL bound to 127.0.0.1:8080; WSL2 forwards localhost to the host
// browser. The WebSocket upgrade is path-agnostic on the server. Override with NEXT_PUBLIC_SOLVER_WS.
export const SOLVER_WS_URL =
  process.env.NEXT_PUBLIC_SOLVER_WS ?? "ws://127.0.0.1:8080/ws";

export type Mode = "trace" | "fast";

// Which puzzle the server should route the `start` definition to. Mirrors the kind set the Haskell
// server dispatches on in `app/server/Main.hs`.
export type PuzzleKind = "sudoku" | "graph" | "queens" | "nonogram";

// ---------------------------------------------------------------------------
// Server -> client: the reasoning stream (the CP engine emits the first five).
// ---------------------------------------------------------------------------

// A decision: the search assigned `value` to `cell` at the given decision level.
export interface DecisionEvent {
  v: typeof PROTOCOL_VERSION;
  t: "decision";
  cell: number;
  value: number;
  level: number;
}

// A propagation step: `removed` was eliminated from `cell`'s domain.
export interface PropagateEvent {
  v: typeof PROTOCOL_VERSION;
  t: "propagate";
  cell: number;
  removed: number;
}

// A conflict: a domain emptied at `cell`.
export interface ConflictEvent {
  v: typeof PROTOCOL_VERSION;
  t: "conflict";
  cell: number;
}

// A backtrack: the search undid the decision at `level`.
export interface BacktrackEvent {
  v: typeof PROTOCOL_VERSION;
  t: "backtrack";
  level: number;
}

// A full solution: cell/value pairs, puzzle-relative.
export interface SolutionEvent {
  v: typeof PROTOCOL_VERSION;
  t: "solution";
  assignment: [number, number][];
}

// A sound proof that no solution exists.
export interface UnsatEvent {
  v: typeof PROTOCOL_VERSION;
  t: "unsat";
}

// Running counters (the UI also derives these by tallying the stream).
export interface StatsEvent {
  v: typeof PROTOCOL_VERSION;
  t: "stats";
  decisions: number;
  propagations: number;
  backtracks: number;
  conflicts: number;
}

export type SolverEvent =
  | DecisionEvent
  | PropagateEvent
  | ConflictEvent
  | BacktrackEvent
  | SolutionEvent
  | UnsatEvent
  | StatsEvent;

// ---------------------------------------------------------------------------
// Client -> server: control.
// ---------------------------------------------------------------------------

export interface StartControl {
  v: typeof PROTOCOL_VERSION;
  t: "start";
  kind: PuzzleKind; // which encoder the server routes the definition to
  puzzle: string; // the raw puzzle definition the server parses
  mode: Mode;
}

export interface StepControl {
  v: typeof PROTOCOL_VERSION;
  t: "step";
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

// Validate the version on receipt so a protocol bump fails loudly rather than rendering garbage.
export function parseEvent(raw: string): SolverEvent | null {
  try {
    const msg = JSON.parse(raw) as SolverEvent;
    if (msg.v !== PROTOCOL_VERSION) return null;
    return msg;
  } catch {
    return null;
  }
}
