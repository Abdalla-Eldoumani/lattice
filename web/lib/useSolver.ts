"use client";

// The visualizer's engine-facing state: a WebSocket to the Haskell solver whose event stream is
// replayed onto the Sudoku domain model by the pure reducer in `replay.ts`. The hook is a thin React
// wrapper so the reducer logic is exactly what the headless replay check exercises.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  parseEvent,
  PROTOCOL_VERSION,
  SOLVER_WS_URL,
  type SolverControl,
} from "./protocol";
import { applyEvent, initialState, type Counters, type Grid, type ReplayState } from "./replay";

export type { Cell, Counters, Grid } from "./replay";

export type ConnState = "connecting" | "open" | "closed";

export interface SolverState {
  grid: Grid;
  size: number;
  counters: Counters;
  currentDecision: ReplayState["currentDecision"];
  lastReason: string;
  solved: boolean;
  conn: ConnState;
  start: (puzzle: string) => void;
  step: () => void;
  play: (speed: number) => void;
  pause: () => void;
  restart: () => void;
}

export function useSolver(): SolverState {
  const [view, setView] = useState<ReplayState>(() => initialState(""));
  const [conn, setConn] = useState<ConnState>("connecting");

  const ws = useRef<WebSocket | null>(null);
  const stateRef = useRef<ReplayState>(view);
  const puzzleRef = useRef<string>("");

  const sync = useCallback(() => setView({ ...stateRef.current }), []);

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
      if (ev) {
        stateRef.current = applyEvent(stateRef.current, ev);
        sync();
      }
    };
    return () => socket.close();
  }, [sync]);

  const start = useCallback(
    (puzzle: string) => {
      puzzleRef.current = puzzle;
      stateRef.current = initialState(puzzle);
      sync();
      send({ v: PROTOCOL_VERSION, t: "start", puzzle, mode: "trace" });
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
    stateRef.current = initialState(puzzleRef.current);
    sync();
    send({ v: PROTOCOL_VERSION, t: "restart" });
  }, [send, sync]);

  return useMemo(
    () => ({
      grid: view.grid,
      size: view.size,
      counters: view.counters,
      currentDecision: view.currentDecision,
      lastReason: view.lastReason,
      solved: view.solved,
      conn,
      start,
      step,
      play,
      pause,
      restart,
    }),
    [view, conn, start, step, play, pause, restart],
  );
}
