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
// server dispatches on in `app/server/Main.hs`. `dimacs` carries raw CNF text for the SAT engine.
export type PuzzleKind = "sudoku" | "graph" | "queens" | "nonogram" | "dimacs";

// Which solver runs a `start`. `race` runs CP and SAT side by side on a dual-encodable instance,
// each event tagged with the engine that produced it. Defaults to `cp` on the server.
export type Engine = "cp" | "sat" | "race";

// ---------------------------------------------------------------------------
// Server -> client: the reasoning stream (the CP engine emits the first five).
// ---------------------------------------------------------------------------
//
// Every event optionally carries an `engine` tag (`cp` | `sat`); the server stamps it so a race's
// interleaved CP and SAT streams can be split into two panels. It is absent on a single-engine
// stream (the field is additive and the protocol stays v1).

// A decision: the search assigned `value` to `cell` at the given decision level. For SAT, `cell` is
// the variable id, `value` the polarity (0/1), `level` the decision level.
export interface DecisionEvent {
  v: typeof PROTOCOL_VERSION;
  t: "decision";
  cell: number;
  value: number;
  level: number;
  engine?: Engine;
}

// A propagation step: `removed` was eliminated from `cell`'s domain. For SAT, a forced literal.
export interface PropagateEvent {
  v: typeof PROTOCOL_VERSION;
  t: "propagate";
  cell: number;
  removed: number;
  engine?: Engine;
}

// A conflict: a domain emptied at `cell` (for SAT, a falsified clause's variable).
export interface ConflictEvent {
  v: typeof PROTOCOL_VERSION;
  t: "conflict";
  cell: number;
  engine?: Engine;
}

// A backtrack: the search undid the decision at `level` (for SAT, the backjump target level).
export interface BacktrackEvent {
  v: typeof PROTOCOL_VERSION;
  t: "backtrack";
  level: number;
  engine?: Engine;
}

// A learned clause from SAT 1UIP analysis, its literals in puzzle/variable coordinates.
export interface LearnEvent {
  v: typeof PROTOCOL_VERSION;
  t: "learn";
  clause: number[];
  engine?: Engine;
}

// A SAT restart fired: the trail unwound to level 0, learned clauses and activities kept.
export interface RestartEvent {
  v: typeof PROTOCOL_VERSION;
  t: "restart";
  engine?: Engine;
}

// A full solution: cell/value pairs, puzzle-relative.
export interface SolutionEvent {
  v: typeof PROTOCOL_VERSION;
  t: "solution";
  assignment: [number, number][];
  engine?: Engine;
}

// A sound proof that no solution exists.
export interface UnsatEvent {
  v: typeof PROTOCOL_VERSION;
  t: "unsat";
  engine?: Engine;
}

// Running counters (the UI also derives these by tallying the stream). The SAT counters
// `learnedClauses` and `restarts` are tallied UI-side from the learn/restart events, so this event
// keeps its four CP counters rather than widening.
export interface StatsEvent {
  v: typeof PROTOCOL_VERSION;
  t: "stats";
  decisions: number;
  propagations: number;
  backtracks: number;
  conflicts: number;
  engine?: Engine;
}

export type SolverEvent =
  | DecisionEvent
  | PropagateEvent
  | ConflictEvent
  | BacktrackEvent
  | LearnEvent
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
  kind: PuzzleKind; // which encoder the server routes the definition to
  puzzle: string; // the raw puzzle definition the server parses
  mode: Mode;
  engine?: Engine; // which solver runs; absent defaults to cp on the server (additive, v1)
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

// The known server-to-client event tags, mirroring the `SolverEvent` union and the Haskell
// `Lattice.Event` ADT. `parseEvent` narrows an incoming `t` against this set so an unknown tag is
// rejected, matching the engine's `fail "unknown event tag"` strictness on its side of the wire.
const EVENT_TAGS = new Set<string>([
  "decision",
  "propagate",
  "conflict",
  "backtrack",
  "learn",
  "restart",
  "solution",
  "unsat",
  "stats",
]);

// Validate the version AND the tag on receipt so a protocol bump or a garbled/hostile frame fails
// loudly (returns null) rather than rendering garbage. Total: never throws on malformed JSON or a
// non-object payload.
export function parseEvent(raw: string): SolverEvent | null {
  try {
    const msg = JSON.parse(raw) as SolverEvent;
    if (msg.v !== PROTOCOL_VERSION) return null;
    if (!EVENT_TAGS.has(msg.t)) return null;
    return msg;
  } catch {
    return null;
  }
}
