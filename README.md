# lattice

lattice is a finite-domain constraint solver written from scratch in Haskell, with a web front end that lets you watch it think. You give it a hard Sudoku, a graph to color, or an N-queens board, and instead of just printing an answer it shows the work: candidates disappearing from cells as constraints propagate, the search committing to a value, a dead end flashing red, the whole thing backing up and trying again. The point is that a person with no background in this can follow the logic and feel the reasoning, while someone who reads the source finds a real propagation engine with a serious test suite behind it rather than a toy.

The engine comes first and the visualizer comes second, on purpose. The core is a constraint-propagation solver: variables with finite domains, an all-different propagator, a propagation queue that runs to a fixpoint, and a backtracking search that makes a decision only when propagation stalls and orders its choices with minimum-remaining-values. The first thing that ships is a terminal solver that reads a puzzle file and solves a 9x9 Sudoku, green in CI, before any front-end work starts. A later milestone adds a CDCL SAT engine with watched literals, 1UIP conflict analysis, clause learning, VSIDS, and Luby restarts, plus DIMACS import and a mode that races the two engines side by side on the same instance.

Correctness is the part that actually matters here, because a propagation or conflict-analysis bug is invisible on easy puzzles and silently wrong on hard ones. The defense is differential testing against an exhaustive brute-force reference on small instances, and it lands in the first milestone rather than as something bolted on later. The suite checks that every returned assignment satisfies its constraints, that the solver never calls an instance unsolvable when a solution exists, and that propagation never throws away a value that belongs to some real solution. The brute-force oracle is kept deliberately dumb so it is too simple to be wrong, and it only ever runs on instances small enough that it finishes fast.

The architecture has one load-bearing idea. The hot loop is written once, generic over the monad, and takes a callback for emitting events. Fast mode runs it in `ST` with a callback that does nothing, which the compiler deletes, so the solver runs at full speed with no per-step overhead. Trace mode runs the same loop in `IO` with a callback that streams events to the browser over a WebSocket and can pause between steps. Both `ST` and `IO` are `PrimMonad`, so the mutable core is shared verbatim, and the demo gets to run at human pace while a real solve stays fast.

The Haskell side lives in WSL on Ubuntu, with the repo on the Linux filesystem under your home directory rather than under `/mnt/c`, which keeps file IO and watching fast. The toolchain is GHC 9.12.2 and cabal 3.16.1.0, both pinned, with the dependency closure frozen and committed. The front end is Next.js with React and Tailwind, and it is a later milestone, so there is nothing to install in `web/` until the engine is solving puzzles in the terminal. Full setup is in `docs/DEVELOPMENT.md`.

## Build and run

Inside WSL, from the repo root:

```bash
cabal build all
cabal run lattice-cli -- puzzles/sudoku/easy.txt
cabal test all
```

The first command builds the library, the CLI, and the test suite. The second solves a puzzle and prints the grid. The third runs the correctness suite, which is the bar for calling any change done. Format and lint before committing with `fourmolu --mode inplace $(git ls-files '*.hs')` and `hlint .`.

The web app, once it exists at milestone 3, runs from `web/`:

```bash
npm ci
npm run dev
```

WSL forwards localhost, so the streaming server bound to `127.0.0.1:8080` in WSL is reachable from your host browser at the same address.

## What this is not

It is not trying to beat MiniSat or Glucose on speed or on industrial instances. The goal is a correct, legible, well-tested solver you can watch, not a benchmark winner. There is no SMT and no MaxSAT. There is no database and no accounts; shareable links, if they get built, are just the instance encoded in the URL. The MVP runs locally for the demo, and a client-side WebAssembly build is left as a maybe, since the GHC WASM backend is still a preview and the server-side design does not depend on it.

## Layout

The engine is under `src/Lattice/`. The executables are under `app/` (the terminal CLI, and later the streaming server). The tests, which carry the correctness load, are under `test/`. Verified sample puzzles with known solutions live in `puzzles/`. The web visualizer is under `web/`.

## License

MIT.
