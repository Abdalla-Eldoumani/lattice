# Development

How to set up the toolchain, build the engine and the visualizer, run them, and contribute a
change. For the shape of the system the commands act on, see [ARCHITECTURE.md](ARCHITECTURE.md);
for the test suite that gates every change, see [TESTING.md](TESTING.md).

## Environment

The Haskell side runs on Ubuntu under WSL, not on the Windows host directly. The toolchain is
pinned:

- **GHC 9.12.2** and **cabal 3.16.1.0**, installed through [ghcup](https://www.haskell.org/ghcup/).
- `cabal.project` pins both the compiler (`with-compiler: ghc-9.12.2`) and the Hackage snapshot it
  resolves against (`index-state: 2026-06-01T00:00:00Z`).
- `cabal.project.freeze` is committed and locks the entire dependency closure to exact versions, so
  a build resolves the same package set on any machine. Do not move `index-state` forward without
  regenerating the freeze file in the same change.

Install the pinned compiler with ghcup rather than using whatever GHC happens to be on `PATH`:

```bash
ghcup install ghc 9.12.2 && ghcup set ghc 9.12.2
ghcup install cabal 3.16.1.0 && ghcup set cabal 3.16.1.0
```

If a pinned version fails to resolve, stop and report it rather than editing the pin to whatever is
available. The pins are deliberate.

A fresh clone is happiest on the Linux filesystem under your home directory (for example
`~/projects/lattice`) rather than under `/mnt/c`. The Linux filesystem gives fast file IO and clean
file watching; the Windows mount is slow enough to matter for both. WSL2 forwards localhost, so a
server bound to `127.0.0.1:8080` inside WSL is reachable from the host browser at that same address
without any extra configuration.

The front end is a separate stack:

- **Next.js 16**, **React 19**, **TypeScript 6**, **Tailwind v4**, on **Node 22**.

It runs on the host (or wherever you keep Node), and it does not need WSL. The exact versions are
pinned in `web/package.json` with a committed `web/package-lock.json`.

## Build and run the engine

All of these run from the repository root, inside WSL:

```bash
cabal build all                                          # library, CLI, server, test suite
cabal run lattice-cli -- puzzles/sudoku/easy.txt         # solve a Sudoku with the CP engine
cabal run lattice-cli -- --sat puzzles/cnf/sat-demo.cnf  # solve a DIMACS CNF with the SAT engine
cabal test all                                           # the correctness suite
```

The first build will be slow because it compiles the dependency closure; later builds are
incremental. On the first build you may want `cabal update` to fetch the index at the pinned state.

### Format and lint

```bash
fourmolu --mode inplace $(git ls-files '*.hs')   # format every tracked Haskell file in place
hlint .                                          # lint
```

Formatting and linting are enforced in CI, so run both before you commit. `fourmolu.yaml` and
`.hlint.yaml` hold the project's settings; the formatter check in CI runs `fourmolu --mode check`,
which fails on any file that is not already formatted.

## Build and run the visualizer

The web app lives in `web/` and runs on the host:

```bash
npm ci          # install the locked dependencies (run inside web/)
npm run dev     # start the dev server; open the URL it prints
npm run lint    # type-check with tsc --noEmit
npm run build   # production build
```

`npm run lint` runs `tsc --noEmit`: the lint step here is the TypeScript type check, not a separate
linter invocation.

Two further scripts need the engine running (see below):

```bash
npm run verify:replay   # reconstruct every sample solution from the live engine stream
npm run walkthrough     # headless browser pass: screenshots at three widths + accessibility checks
```

`verify:replay` connects to the running engine, drives each sample instance, and checks that the
replayed event stream reconstructs the known solution end to end. `walkthrough` serves the
production build and drives Chromium across the puzzle views at 375 / 768 / 1440 pixels, captures a
reduced-motion variant, and runs the accessibility assertions, printing a pass/fail line per check
and exiting non-zero on any failure. It expects the engine to already be running on
`127.0.0.1:8080`; it manages only the front-end server, not the engine.

## The two executables

The project builds two binaries from one engine library:

- **`lattice-cli`** — the terminal solver. It reads a puzzle file, runs the engine in fast mode, and
  prints the answer. The default arm solves a CP puzzle and prints the solved grid (or `no solution`
  for a sound unsat). The `--sat <dimacs-file>` arm runs the SAT engine on a DIMACS CNF and prints
  `SAT` plus a model (signed DIMACS literals in variable order, terminated by `0`) or `UNSAT`. The
  exit-code contract: a malformed or unreadable file exits 1, wrong arguments exit 2, and a solved or
  soundly-unsolvable instance exits 0 — an `UNSAT` (like a CP "no solution") is an answer, not an
  error.
- **`lattice-server`** — the streaming visualizer server. It binds `127.0.0.1:8080` and carries the
  event protocol over a single WebSocket: the browser sends control messages (`start`, `step`,
  `play`, `pause`, `restart`), and the server runs the engine in trace mode and streams the reasoning
  back, pacing it so a solve animates at human speed.

They relate through the shared engine library under `src/`: the CLI and the server are thin IO
shells around the same pure solver. Fast mode (the CLI) and trace mode (the server) run the same hot
loop, so the events the browser animates are the engine's real reasoning rather than a re-enactment.

To watch a solve in the browser, run the server in WSL and the web app on the host:

```bash
# in WSL, from the repository root
cabal run lattice-server          # binds 127.0.0.1:8080

# in web/, on the host
npm run dev                       # the visualizer; open the printed URL
```

The browser connects to the engine over a WebSocket. The default address is `ws://127.0.0.1:8080/ws`,
which works out of the box thanks to WSL2's localhost forwarding. To point the front end at a
different engine, set `NEXT_PUBLIC_SOLVER_WS`; [DEPLOYMENT.md](DEPLOYMENT.md) covers that for hosted
setups.

## Contributing

The correctness suite is the bar. A propagation or conflict-analysis bug does not show up on easy
instances, so "it compiles" and "it solved my Sudoku" are not enough. A change is done when:

- **`cabal test all` is green.** This is the contract, not a formality. New propagators must be
  covered by the soundness and sound-propagation groups; [TESTING.md](TESTING.md) explains why and
  what each group guards against.
- **Warnings are errors.** The library and executables build with `-Wall` and a set of extra
  warnings (see the `warnings` block in `lattice.cabal`); CI treats a warning as a failure. Keep the
  tree clean.
- **`fourmolu` and `hlint` are clean.** Run `fourmolu --mode inplace $(git ls-files '*.hs')` and
  `hlint .` before committing. If you must waive an hlint hint, add it to `.hlint.yaml` with a
  one-line reason.
- **The web build passes.** If you touch `web/`, `npm run lint` and `npm run build` must pass, and
  if you change the wire protocol, change both sides in the same commit — `web/lib/protocol.ts` is
  the TypeScript mirror of the Haskell `Lattice.Event` / `Lattice.Protocol` ADTs.

CI runs on every push: it builds and tests the engine on Linux with the pinned GHC, runs
`fourmolu --mode check` and `hlint .`, and (once a `web/package-lock.json` exists) installs,
type-checks, and builds the web app. See [TESTING.md](TESTING.md) for what runs in each job and the
raised test budgets it uses.

## Repository layout

A brief map; [ARCHITECTURE.md](ARCHITECTURE.md) covers it in full.

- `src/Lattice/` — the engine library. `Core` and `CP` are the constraint solver; `SAT` is the CDCL
  engine; `Encode` holds the puzzle encoders; `Event` and `Protocol` are the wire format; `Brute` is
  the exhaustive reference oracle the tests check against.
- `app/cli/` — the `lattice-cli` terminal solver.
- `app/server/` — the `lattice-server` streaming WebSocket server.
- `test/` — the correctness suite, the load-bearing part of the project.
- `puzzles/` — verified sample instances with known solutions: Sudoku grids, a graph, a nonogram,
  and DIMACS CNF fixtures.
- `web/` — the Next.js visualizer.
- `docs/` — this documentation set.
