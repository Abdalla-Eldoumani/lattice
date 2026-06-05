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
  type SolverEvent,
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
  unsat: boolean;
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
  // Set on the engine's `unsat` event (the dead-end peer of `solved`), so the panel can show a clear
  // result line for a sound proof of no solution rather than only the "no solution" last-step text.
  unsat: boolean;
  // the search-tree the minimap draws, built by the parallel reducer from the same event stream.
  minimap: MinimapState;
  conn: ConnState;
  // The two race models, present only while a race is running. One socket carries both engines'
  // events; each event is routed by its `engine` tag into the matching side. Null for a single-engine
  // solve, which keeps the single-model fields above unchanged.
  race: { cp: RaceSide; sat: RaceSide } | null;
  // ---- The single-engine event scrubber (step-back timeline). ----------------------------------
  // The number of events received so far for the current single-engine solve (the live edge). Zero
  // before a start, and on every event arrival the buffer grows by one. Always 0 in race mode (the
  // race is play-only and not scrubbable), so the UI hides the scrubber there.
  eventCount: number;
  // The index up to which the rendered view (grid/minimap/counters/...) is reconstructed: 0 is the
  // seed (before any event), `eventCount` is the live edge. The view above always reflects THIS
  // position, so the whole panel shows one consistent historical moment.
  cursor: number;
  // True when the cursor is at the live edge (cursor === eventCount): incoming events keep advancing
  // the view. False while scrubbed back into history; new events then grow the buffer but do not move
  // the view. Also true (vacuously) in race mode, where the scrubber is inert.
  following: boolean;
  // Move the view to a specific event index (clamped to [0, eventCount]). A no-op in race mode.
  seek: (index: number) => void;
  // Step the view one event backward / forward through the received history (clamped). No-op in race.
  stepBack: () => void;
  stepForward: () => void;
  // Snap the view back to the live edge and resume following incoming events.
  jumpToLive: () => void;
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
  // The scrubber's two render-driving numbers. `eventCount` is the live edge (the buffer length);
  // `cursor` is the position the view is reconstructed to. Both are 0 until the first event arrives.
  const [eventCount, setEventCount] = useState(0);
  const [cursor, setCursor] = useState(0);

  const ws = useRef<WebSocket | null>(null);
  // The LIVE reducers: they always advance as events arrive, so following the live edge stays an O(1)
  // incremental apply per event (never a full re-replay). When the user scrubs back, the rendered view
  // is recomputed from the seed over a prefix instead, but these keep moving so jumping to live is free.
  const stateRef = useRef<ReplayState>(view);
  const minimapRef = useRef<MinimapState>(minimap);
  // The ordered event buffer for the current single-engine solve, and the cursor mirror the render
  // reads. The buffer is the history the scrubber replays a prefix of; it is reset on start/restart and
  // never populated in race mode. `cursorRef` mirrors the `cursor` state so the message handler can
  // decide follow-vs-stay without going through a render.
  const eventsRef = useRef<SolverEvent[]>([]);
  const cursorRef = useRef(0);
  // The single-engine seed (the model before any event), kept so a scrub can replay events[0..k] from
  // a clean start without re-parsing the definition. Reset alongside the buffer on start/restart.
  const seedStateRef = useRef<ReplayState>(view);
  const seedMinimapRef = useRef<MinimapState>(minimap);
  const puzzleRef = useRef<string>("");
  const kindRef = useRef<PuzzleKind>("sudoku");
  const engineRef = useRef<Engine>("cp");
  // The two race models, mutated in lockstep with the single-engine refs. Null when no race runs.
  const raceRef = useRef<{ cp: RaceModel; sat: RaceModel } | null>(null);

  // Push the rendered view from whichever model is at the cursor. In race mode the single-engine view
  // is irrelevant (the panels read `race`); in single-engine mode the view reflects the cursor: the
  // live refs when following the edge, or a from-seed replay of events[0..cursor] when scrubbed back.
  const sync = useCallback(() => {
    setView({ ...stateRef.current });
    setMinimap(minimapRef.current);
    const r = raceRef.current;
    setRace(r ? { cp: sideOf(r.cp), sat: sideOf(r.sat) } : null);
  }, []);

  // Reconstruct the view at `index` (clamped to [0, buffer length]) by replaying events[0..index] from
  // the seed, and publish it. The pure reducers make a prefix replay total and deterministic, so this
  // never throws and produces exactly the state that existed after `index` events. Updates the cursor
  // refs/state in lockstep so `following` and the keyboard step paths stay consistent.
  //
  // The replay starts from a FRESH copy of the seed's snapshot map. replay.ts carries and mutates the
  // CP `snapshots` Map in place (it is the only mutable-in-place field), so reusing the seed object
  // across renderAt calls would let one replay's level snapshots leak into the next and a CP backtrack
  // restore a stale grid. A fresh empty Map per replay keeps each scrub independent and faithful.
  const renderAt = useCallback((index: number) => {
    const events = eventsRef.current;
    const clamped = Math.max(0, Math.min(index, events.length));
    let s: ReplayState = { ...seedStateRef.current, snapshots: new Map() };
    let m = seedMinimapRef.current;
    for (let i = 0; i < clamped; i++) {
      s = applyEvent(s, events[i]);
      m = applyMinimapEvent(m, events[i]);
    }
    cursorRef.current = clamped;
    setCursor(clamped);
    setView({ ...s });
    setMinimap(m);
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
      // Single-engine mode: buffer the event so the scrubber can replay any prefix later, and advance
      // the LIVE reducers in lockstep with the stream (the cell-state model the grid renders and the
      // search-tree the minimap renders). The live refs always move so following the edge stays an
      // incremental apply; the buffer always grows so a scrubbed-back viewer never loses an event.
      eventsRef.current.push(ev);
      stateRef.current = applyEvent(stateRef.current, ev);
      minimapRef.current = applyMinimapEvent(minimapRef.current, ev);
      const count = eventsRef.current.length;
      setEventCount(count);
      // Following the live edge: advance the cursor with the buffer and publish the live view. Scrubbed
      // back: keep the view pinned at the cursor (do not yank the viewer to live) — only the count grew.
      if (cursorRef.current === count - 1) {
        cursorRef.current = count;
        setCursor(count);
        sync();
      }
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
      // Reset the scrubber: a fresh buffer seeded from this instance's start model, the cursor at the
      // (empty) live edge. Keeping the seed lets a later scrub replay events[0..k] from a clean start.
      eventsRef.current = [];
      seedStateRef.current = stateRef.current;
      seedMinimapRef.current = minimapRef.current;
      cursorRef.current = 0;
      setEventCount(0);
      setCursor(0);
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
    // Restart reseeds the same instance, so the buffer is cleared the same way `start` does and the
    // cursor returns to the empty live edge — the prior solve's history is gone.
    eventsRef.current = [];
    seedStateRef.current = stateRef.current;
    seedMinimapRef.current = minimapRef.current;
    cursorRef.current = 0;
    setEventCount(0);
    setCursor(0);
    sync();
    send({ v: PROTOCOL_VERSION, t: "restart" });
  }, [send, sync]);

  // The scrubber actions. All are no-ops in race mode (the buffer is empty there, so renderAt's clamp
  // would still leave the view at the seed; the explicit guard documents the intent and skips the work).
  // `seek` re-renders the view at an absolute index; the step actions move relative to the current
  // cursor; `jumpToLive` snaps to the live edge (the buffer length). renderAt clamps every index.
  const seek = useCallback(
    (index: number) => {
      if (raceRef.current) return;
      renderAt(index);
    },
    [renderAt],
  );
  const stepBack = useCallback(() => {
    if (raceRef.current) return;
    renderAt(cursorRef.current - 1);
  }, [renderAt]);
  const stepForward = useCallback(() => {
    if (raceRef.current) return;
    renderAt(cursorRef.current + 1);
  }, [renderAt]);
  const jumpToLive = useCallback(() => {
    if (raceRef.current) return;
    renderAt(eventsRef.current.length);
  }, [renderAt]);

  // Following the live edge: the cursor sits at the buffer end, so incoming events advance the view.
  // Vacuously true before any event (0 === 0) and in race mode (both 0), where the scrubber is inert.
  const following = cursor === eventCount;

  return useMemo(
    () => ({
      grid: view.grid,
      size: view.size,
      counters: view.counters,
      currentDecision: view.currentDecision,
      learnedClause: view.learnedClause,
      lastReason: view.lastReason,
      solved: view.solved,
      unsat: view.unsat,
      minimap,
      conn,
      race,
      eventCount,
      cursor,
      following,
      seek,
      stepBack,
      stepForward,
      jumpToLive,
      start,
      step,
      play,
      pause,
      restart,
    }),
    [
      view,
      minimap,
      conn,
      race,
      eventCount,
      cursor,
      following,
      seek,
      stepBack,
      stepForward,
      jumpToLive,
      start,
      step,
      play,
      pause,
      restart,
    ],
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
    unsat: m.state.unsat,
    minimap: m.minimap,
    kind: m.kind,
  };
}
