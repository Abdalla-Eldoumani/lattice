# Architecture

lattice has four parts: one Haskell library holding both solver engines, a terminal CLI, a
streaming server, and a web visualizer. The library is pure — it computes in `ST` or in pure
functions and never does IO. The CLI and the server are the only executables that touch the
outside world; the visualizer is a separate Next.js app. This document describes how those parts
relate and the one design decision that makes the visualizer honest.

## The big picture

```
              ┌────────────────────────────────────────────────┐
              │  lattice library  (src/Lattice/, pure / ST)     │
              │                                                  │
  puzzle ───► │  Encode ──► Model (CP)  ──► CP engine           │
  or CNF      │           └► CNF (SAT)  ──► SAT (CDCL) engine    │
              │                              │                   │
              │                  Emit callback (Event stream)    │
              └──────────────────────────────│───────────────────┘
                                             │
                  fast mode                  │  trace mode
              (ST, emit deleted)             │  (IO, emit streams)
                     │                       │
                     ▼                       ▼
              ┌────────────┐         ┌─────────────────┐    WebSocket    ┌──────────────┐
              │ app/cli    │         │ app/server      │ ◄────────────►  │ web/         │
              │ prints the │         │ Scotty + WS,    │   events  +     │ Next.js      │
              │ answer     │         │ trace solve     │   control       │ visualizer   │
              └────────────┘         └─────────────────┘                 └──────────────┘
```

A puzzle (Sudoku text, a graph JSON, an N-queens size, a nonogram, or a DIMACS CNF) enters through
an encoder. The CP encoders build a `Model` — seeded domains plus a list of constraints. The SAT
side builds a `CNF`. A graph can go either way: `Lattice.Encode.Graph.graphModel` produces the CP
model and `Lattice.SAT.Encode.graphCNF` produces the dual CNF for the same instance, which is what
lets the two engines race on genuinely the same problem.

From there the engine runs. In the CLI it runs in fast mode and the answer is printed. In the
server it runs in trace mode: every reasoning step is an `Event` that the server forwards over a
WebSocket to the browser, one step at a time, paced by control messages the browser sends back.

## The load-bearing idea: one loop, two modes

The hot loop is written once, generic over the monad, and takes a callback for emitting events.
`Lattice.Event` defines:

```haskell
type Emit m = Event -> m ()

noEmit :: (Applicative m) => Emit m
noEmit _ = pure ()
```

The CP entry point in `Lattice.CP.Solver` exposes both faces of the same search:

- `solve :: Model -> Result` is fast mode. It runs the search with `noEmit`. With `-O2` and the
  loop inlined, the dead callback and the `Event` values that would have fed it are optimized away,
  so the fast solver carries no per-step instrumentation cost.
- `solveTrace :: (Monad m) => Emit m -> Model -> m Result` is the same search threaded with a real
  emit callback, so a caller receives the decision / propagate / conflict / backtrack / solution
  stream.

The SAT side mirrors this exactly. `Lattice.SAT.Solver` exposes `solveSat :: CNF -> SatResult`
(fast, `runST` with `noEmit`) and `solveSatTrace :: Emit IO -> CNF -> IO SatResult` (trace), both
built on one `cdclLoop` that is generic over `PrimMonad m`. Both `ST` and `IO` are `PrimMonad`, so
the mutable core — the trail, the watch buffers, the clause database — is shared verbatim between
the fast and trace builds.

Why this matters: the demo can run at human pace, pausing between steps, while a real solve stays
at full speed. And because both modes execute the identical loop, the steps the browser animates
are the engine's actual reasoning, not a separate visualization that could drift from what the
solver really did. There is one source of truth, instantiated twice.

## The event protocol is the contract

The engine and the browser agree on a versioned, tagged JSON protocol. Server-to-client events
(`Lattice.Event.Event`) carry the reasoning: `Decision`, `Propagate`, `Conflict`, `Backtrack`,
`Solution`, `Unsat`, and `Stats`, plus the two SAT additions `Learned` and `Restart`.
Client-to-server control (`Lattice.Protocol.Control`) carries `Start`, `Step`, `Play`, `Pause`, and
`Restart`. Events speak puzzle coordinates — a cell index, a vertex id, a SAT variable — never the
engine's internal solver ids; the encoder owns that mapping. The TypeScript mirror of the protocol
lives in `web/lib/protocol.ts` and must move in lockstep with the Haskell side. The full wire
format, the field meanings, and the SAT conventions are in [PROTOCOL.md](PROTOCOL.md).

## The server's job

`app/server/Main.hs` is a Scotty + WebSockets server bound to `127.0.0.1:8080`. One socket carries
both directions, which is why WebSockets was chosen over server-sent events. On a `Start` message
it routes the puzzle to an encoder (by its `kind`) and a solver (by its `engine`), then forks a
trace solve. Each emitted event blocks on a per-connection gate until the client releases it, so
`Step` advances one event and `Play` releases events on a timer. Race mode forks two trace solves —
the CP model and its dual CNF — over the one socket, each event stamped with the engine that
produced it so the browser can split the interleaved streams into two panels. The server's
concurrency details (the write lock that serializes the two race threads' frames, the per-engine
step gates) are documented in the server source.

## The repository layout

```
src/Lattice/
  Core/        Types and domain operations: variables, finite domains, the constraint ADT,
               the puzzle-agnostic Model. The CP state is a persistent IntMap, so a backtrack
               is just holding the previous map.
  CP/          The constraint engine: Propagator, Queue (the fixpoint worklist), Search
               (backtracking with MRV / degree / LCV ordering), Solver (the two-mode entry).
  SAT/         The CDCL engine: Types, ClauseDB, Trail, Watched (BCP), Analyze (1UIP),
               VSIDS, Solver, Dimacs (parse/print), Encode (graph -> CNF dual).
  Encode/      The puzzle encoders: Sudoku, Graph, Queens, Nonogram.
  Event.hs     The Event ADT, the Emit callback, and the server-to-client JSON form.
  Protocol.hs  The Control ADT and the client-to-server JSON form.
  Brute.hs     The exhaustive reference oracle for the tests. Imports no engine module on
               purpose, so it shares no inference with the code it checks.
  Lattice.hs   The stable public surface callers import.

app/cli/       The terminal solver. Reads a puzzle (or, with --sat, a DIMACS file), runs the
               engine in fast mode, prints the result.
app/server/    The streaming server described above.

test/          The correctness suite, including the brute-force differential. Carries the load.
web/           The Next.js visualizer that consumes the event stream.
puzzles/       Verified sample instances with known solutions: Sudoku, graphs, a nonogram,
               and CNF fixtures.
```

## The correctness stance

A propagation or conflict-analysis bug is invisible on easy puzzles and silently wrong on hard
ones, so correctness is enforced rather than hoped for. The main defense is differential testing
against `Lattice.Brute`, an exhaustive backtracking enumerator (for CP) and a `2^n` truth-table
enumerator (for SAT) kept deliberately simple so it is too plain to be wrong, and run only on
instances small enough to finish fast. On those instances the engine, the oracle, and — for a
dual-encoded graph — the CP engine, the SAT engine, and both oracles must agree on satisfiability
and on the unique solution. The full set of properties is in [TESTING.md](TESTING.md).

## Where to read next

- The constraint engine in detail: [CP-ENGINE.md](CP-ENGINE.md).
- The SAT engine in detail: [SAT-ENGINE.md](SAT-ENGINE.md).
- The wire protocol: [PROTOCOL.md](PROTOCOL.md).
- The front end: [VISUALIZER.md](VISUALIZER.md).
- Building and running it yourself: [DEVELOPMENT.md](DEVELOPMENT.md).
