"use client";

// The visualizer's engine-facing state: a WebSocket to the Haskell solver whose event stream is
// replayed onto the Sudoku domain model by the pure reducer in `replay.ts`. The hook is a thin React
// wrapper so the reducer logic is exactly what the headless replay check exercises.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  type Engine,
  parseEvent,
  PROTOCOL_VERSION,
  type PuzzleKind,
  SOLVER_WS_URL,
  type SolverControl,
} from "./protocol";
import {
  applyEvent,
  initialState,
  initialStateForKind,
  type Counters,
  type Grid,
  type ReplayState,
} from "./replay";
import { applyMinimapEvent, initialMinimap, type MinimapState } from "./minimap";

export type { Cell, Counters, Grid } from "./replay";

export type ConnState = "connecting" | "open" | "closed";

// One engine's view of a race: the cell-state model its panel renders plus the search-tree its
// minimap draws and the kind its PuzzleView dispatches on. The CP side carries the native kind (e.g.
// `graph`, rendering GraphView); the SAT side is always `dimacs` (rendering TrailView of the CNF).
export interface RaceSide {
  grid: Grid;
  size: number;
  counters: Counters;
  currentDecision: ReplayState["currentDecision"];
  learnedClause: number[] | null;
  lastReason: string;
  solved: boolean;
  minimap: MinimapState;
  kind: PuzzleKind;
}

export interface SolverState {
  grid: Grid;
  size: number;
  counters: Counters;
  currentDecision: ReplayState["currentDecision"];
  // The most recent SAT learned clause (signed literals), for the TrailView's transient clause chip.
  learnedClause: number[] | null;
  lastReason: string;
  solved: boolean;
  // the search-tree the minimap draws, built by the parallel reducer from the same event stream.
  minimap: MinimapState;
  conn: ConnState;
  // The two race models, present only while a race is running. One socket carries both engines'
  // events; each event is routed by its `engine` tag into the matching side. Null for a single-engine
  // solve, which keeps the single-model fields above unchanged.
  race: { cp: RaceSide; sat: RaceSide } | null;
  start: (puzzle: string, kind: PuzzleKind, engine?: Engine) => void;
  step: () => void;
  play: (speed: number) => void;
  pause: () => void;
  restart: () => void;
}

// A race side's reducer pair: the cell-state ReplayState and the search-tree MinimapState, kept in
// lockstep exactly like the single-engine refs.
interface RaceModel {
  state: ReplayState;
  minimap: MinimapState;
  kind: PuzzleKind;
}

// Build the two seeded race models from the dual-encodable puzzle. The CP side seeds from the native
// kind (graph); the SAT side seeds as a dimacs trail sized to the CNF the server encodes. The client
// does not run the encoder, so the SAT vector is sized from the graph's vertex count x k (one boolean
// x_{v,c} per vertex-color pair, the graphCNF mapping) — a bound, not an exact layout; the trail
// grows as the engine streams its assignments. A malformed definition falls back to a small vector.
function seedRace(puzzle: string, kind: PuzzleKind): { cp: RaceModel; sat: RaceModel } {
  return {
    cp: { state: initialStateForKind(kind, puzzle), minimap: initialMinimap(), kind },
    sat: {
      state: initialStateForKind("dimacs", raceCnfHeader(puzzle)),
      minimap: initialMinimap(),
      kind: "dimacs",
    },
  };
}

// A synthetic `p cnf N M` header so the dimacs seed sizes the SAT trail to the graph's CNF variable
// count (vertices x k). The server's graphCNF owns the real var<->(vertex,color) map; this only seeds
// a non-empty vector so the panel is never a spinner before the first event. A non-graph or malformed
// definition yields a header dimacsVarCount reads as its small default.
function raceCnfHeader(puzzle: string): string {
  try {
    const g = JSON.parse(puzzle) as { vertices?: unknown[]; k?: number };
    if (Array.isArray(g.vertices) && typeof g.k === "number" && g.vertices.length > 0 && g.k > 0) {
      return `p cnf ${g.vertices.length * g.k} 0\n`;
    }
  } catch {
    // a malformed definition falls back to the dimacs seed's small default
  }
  return "";
}

export function useSolver(): SolverState {
  const [view, setView] = useState<ReplayState>(() => initialState(""));
  const [minimap, setMinimap] = useState<MinimapState>(() => initialMinimap());
  const [conn, setConn] = useState<ConnState>("connecting");
  const [race, setRace] = useState<{ cp: RaceSide; sat: RaceSide } | null>(null);

  const ws = useRef<WebSocket | null>(null);
  const stateRef = useRef<ReplayState>(view);
  const minimapRef = useRef<MinimapState>(minimap);
  const puzzleRef = useRef<string>("");
  const kindRef = useRef<PuzzleKind>("sudoku");
  const engineRef = useRef<Engine>("cp");
  // The two race models, mutated in lockstep with the single-engine refs. Null when no race runs.
  const raceRef = useRef<{ cp: RaceModel; sat: RaceModel } | null>(null);

  const sync = useCallback(() => {
    setView({ ...stateRef.current });
    setMinimap(minimapRef.current);
    const r = raceRef.current;
    setRace(r ? { cp: sideOf(r.cp), sat: sideOf(r.sat) } : null);
  }, []);

  const send = useCallback((msg: SolverControl) => {
    const s = ws.current;
    if (s && s.readyState === WebSocket.OPEN) s.send(JSON.stringify(msg));
  }, []);

  useEffect(() => {
    const socket = new WebSocket(SOLVER_WS_URL);
    ws.current = socket;
    setConn("connecting");
    socket.onopen = () => setConn("open");
    socket.onclose = () => setConn("closed");
    socket.onerror = () => setConn("closed");
    socket.onmessage = (e) => {
      const ev = parseEvent(typeof e.data === "string" ? e.data : "");
      if (!ev) return;
      const r = raceRef.current;
      if (r) {
        // Race mode: one socket, two models. Route the event by its `engine` tag into the matching
        // side and apply it to that side's reducers only, so the two panels never cross-contaminate.
        // A known cp/sat tag routes; an untagged or unknown tag is ignored for the race split (it
        // cannot belong to a panel) rather than corrupting one — the safe boundary (threat T-05-22).
        const side = ev.engine === "cp" ? r.cp : ev.engine === "sat" ? r.sat : null;
        if (side) {
          side.state = applyEvent(side.state, ev);
          side.minimap = applyMinimapEvent(side.minimap, ev);
          sync();
        }
        return;
      }
      // Single-engine mode (unchanged): apply the same event to both reducers — the cell-state model
      // the grid renders and the search-tree the minimap renders — in lockstep with one event stream.
      stateRef.current = applyEvent(stateRef.current, ev);
      minimapRef.current = applyMinimapEvent(minimapRef.current, ev);
      sync();
    };
    return () => socket.close();
  }, [sync]);

  const start = useCallback(
    (puzzle: string, kind: PuzzleKind, engine?: Engine) => {
      puzzleRef.current = puzzle;
      kindRef.current = kind;
      engineRef.current = engine ?? "cp";
      if (engine === "race") {
        // Race: seed the two models the split routes into; the single-engine model is reset to the
        // CP side's seed so the page can fall back cleanly if the race is later superseded.
        const seeded = seedRace(puzzle, kind);
        raceRef.current = seeded;
        stateRef.current = seeded.cp.state;
        minimapRef.current = seeded.cp.minimap;
      } else {
        raceRef.current = null;
        stateRef.current = initialStateForKind(kind, puzzle);
        minimapRef.current = initialMinimap();
      }
      sync();
      // The engine field is additive: absent defaults to cp on the server (the existing CP path). The
      // picker passes sat for a dimacs instance and cp/sat/race per the user's choice. The one start
      // drives both engines in the race (the server forks two trace solves over this one socket).
      send({ v: PROTOCOL_VERSION, t: "start", kind, puzzle, mode: "trace", engine });
    },
    [send, sync],
  );

  const step = useCallback(() => send({ v: PROTOCOL_VERSION, t: "step" }), [send]);
  const play = useCallback(
    (speed: number) => send({ v: PROTOCOL_VERSION, t: "play", speed }),
    [send],
  );
  const pause = useCallback(() => send({ v: PROTOCOL_VERSION, t: "pause" }), [send]);
  const restart = useCallback(() => {
    // Reseed whichever models are live: the two race models if a race is running, else the single
    // model. The one restart control replays the same instance for both engines (the server side).
    if (engineRef.current === "race") {
      raceRef.current = seedRace(puzzleRef.current, kindRef.current);
      stateRef.current = raceRef.current.cp.state;
      minimapRef.current = raceRef.current.cp.minimap;
    } else {
      stateRef.current = initialStateForKind(kindRef.current, puzzleRef.current);
      minimapRef.current = initialMinimap();
    }
    sync();
    send({ v: PROTOCOL_VERSION, t: "restart" });
  }, [send, sync]);

  return useMemo(
    () => ({
      grid: view.grid,
      size: view.size,
      counters: view.counters,
      currentDecision: view.currentDecision,
      learnedClause: view.learnedClause,
      lastReason: view.lastReason,
      solved: view.solved,
      minimap,
      conn,
      race,
      start,
      step,
      play,
      pause,
      restart,
    }),
    [view, minimap, conn, race, start, step, play, pause, restart],
  );
}

// Project a race model's reducer pair into the rendered RaceSide a panel consumes — the same fields
// the single-engine path exposes, scoped to one engine. A fresh ReplayState spread keeps React's
// reference check honest (the reducer returns a new object per event, like the single-engine sync).
function sideOf(m: RaceModel): RaceSide {
  return {
    grid: m.state.grid,
    size: m.state.size,
    counters: m.state.counters,
    currentDecision: m.state.currentDecision,
    learnedClause: m.state.learnedClause,
    lastReason: m.state.lastReason,
    solved: m.state.solved,
    minimap: m.minimap,
    kind: m.kind,
  };
}
