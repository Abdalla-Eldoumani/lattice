// Headless verification of the visualizer (VIZ-01/02/03) without a browser: connect to a running
// lattice-server, single-step through the whole event stream, replay it through the SAME reducer the
// UI uses (`lib/replay.ts`), and assert the reconstructed grid equals the puzzle's known solution.
// hard-17 exercises decisions, conflicts, backtracks, and the snapshot-restore path. The CSS motion
// itself needs a browser; this proves the state the motion renders is correct.
//
//   start lattice-server on :8080, then:  npm run verify:replay

import { parseEvent } from "../lib/protocol";
import { applyEvent, gridToString, initialState, type ReplayState } from "../lib/replay";

const SERVER = process.env.SOLVER_WS ?? "ws://127.0.0.1:8080/";

interface Case {
  name: string;
  puzzle: string;
  expected: string;
}

const CASES: Case[] = [
  { name: "diff-4x4", puzzle: "1...\n...2\n.3..\n..4.", expected: "1234341243212143" },
  {
    name: "easy",
    puzzle: "53..7....\n6..195...\n.98....6.\n8...6...3\n4..8.3..1\n7...2...6\n.6....28.\n...419..5\n....8..79",
    expected: "534678912672195348198342567859761423426853791713924856961537284287419635345286179",
  },
  {
    name: "hard-17",
    puzzle: ".......1.\n4........\n.2.......\n....5.4.7\n..8...3..\n..1.9....\n3..4..2..\n.5.1.....\n...8.6...",
    expected: "693784512487512936125963874932651487568247391741398625319475268856129743274836159",
  },
];

function runCase(c: Case): Promise<{ name: string; ok: boolean; detail: string }> {
  return new Promise((resolve) => {
    const ws = new WebSocket(SERVER);
    let state: ReplayState = initialState(c.puzzle);
    let settled = false;
    const finish = (ok: boolean, detail: string) => {
      if (settled) return;
      settled = true;
      ws.close();
      resolve({ name: c.name, ok, detail });
    };
    ws.addEventListener("open", () =>
      ws.send(JSON.stringify({ v: 1, t: "start", puzzle: c.puzzle, mode: "trace" })),
    );
    ws.addEventListener("message", (e) => {
      const ev = parseEvent(String((e as MessageEvent).data));
      if (!ev) return;
      state = applyEvent(state, ev);
      if (ev.t === "solution") {
        const got = gridToString(state.grid);
        const k = state.counters;
        finish(
          got === c.expected,
          got === c.expected
            ? `reconstructed the solution (${k.decisions} decisions, ${k.propagations} propagations, ${k.backtracks} backtracks)`
            : `MISMATCH expected=${c.expected} got=${got}`,
        );
      } else {
        ws.send(JSON.stringify({ t: "step" }));
      }
    });
    ws.addEventListener("error", () => finish(false, "websocket error (is lattice-server on :8080?)"));
    setTimeout(() => finish(false, "timed out"), 30000);
  });
}

let allOk = true;
for (const c of CASES) {
  const r = await runCase(c);
  console.log(`${r.ok ? "PASS" : "FAIL"}  ${r.name}: ${r.detail}`);
  if (!r.ok) allOk = false;
}
process.exit(allOk ? 0 : 1);
