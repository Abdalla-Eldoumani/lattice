"use client";

// The Sudoku visualizer (VIZ-01/02/03): a 9x9 grid that animates the engine's event stream, the
// step/play/pause/restart controls that drive it, and the thinking panel with the live counters.

import { type ReactNode, useCallback, useEffect, useMemo, useState } from "react";
import { type RaceSide, useSolver } from "../lib/useSolver";
import { type Engine, type PuzzleKind } from "../lib/protocol";
import { PuzzleView } from "../components/PuzzleView";
import { Minimap } from "../components/Minimap";
import { DEFAULT_PUZZLE_KEY, type PuzzleDef, PUZZLES } from "../lib/puzzles";

// Which engines a given instance can run. A dimacs (raw CNF) instance is SAT-only. A dual-encodable
// instance (graph, which the server builds as both a CP model and a CNF) offers cp, sat, and the
// cp-vs-sat race. Every other CP puzzle is CP-only (no CNF encoding exists for it). The picker offers
// exactly these, so the user can never pick an engine that would not route on the server.
function engineOptionsFor(puzzle: PuzzleDef): { value: Engine; label: string }[] {
  if (puzzle.kind === "dimacs") return [{ value: "sat", label: "sat" }];
  if (puzzle.dualEncodable) {
    return [
      { value: "cp", label: "cp" },
      { value: "sat", label: "sat" },
      { value: "race", label: "cp vs sat" },
    ];
  }
  return [{ value: "cp", label: "cp" }];
}

// the shared focus ring: a visible 2px --color-border-strong outline on every control, so a keyboard
// user always sees where focus is (the accessibility contract, VIZ-08). focus-visible (not focus)
// keeps it keyboard-only, never a mouse-click halo.
const FOCUS_RING =
  "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[color:var(--color-border-strong)]";

export default function Home() {
  const solver = useSolver();
  const [puzzleKey, setPuzzleKey] = useState(DEFAULT_PUZZLE_KEY);
  const [engine, setEngine] = useState<Engine>("cp");
  const [playing, setPlaying] = useState(false);
  const n = solver.size;
  const box = Math.round(Math.sqrt(n));
  const selected = PUZZLES[puzzleKey];
  const engineOptions = useMemo(() => engineOptionsFor(selected), [selected]);
  // Keep the engine valid for the selected puzzle: when the puzzle changes, snap the engine to the
  // first option it offers if the current choice is no longer available (e.g. switching to a dimacs
  // instance forces sat; switching back to a CP-only puzzle forces cp).
  const engineValid = engineOptions.some((o) => o.value === engine);
  const effectiveEngine: Engine = engineValid ? engine : engineOptions[0].value;
  useEffect(() => {
    if (!engineValid) setEngine(engineOptions[0].value);
  }, [engineValid, engineOptions]);
  // SAT counters (learned clauses / restarts) are meaningful only for a SAT-running engine.
  const showSatCounters = effectiveEngine === "sat" || effectiveEngine === "race";
  // The race renders two panels only once useSolver has seeded both models for a race start. Until
  // then (a fresh page, or before pressing start) the single-panel layout shows the CP-side seed.
  const racing = effectiveEngine === "race" && solver.race !== null;

  const onPlayPause = useCallback(() => {
    if (playing) {
      solver.pause();
      setPlaying(false);
    } else {
      solver.play(12);
      setPlaying(true);
    }
  }, [playing, solver]);

  // keyboard control (VIZ-08): space / right-arrow single-step, p toggles play/pause. The keys drive
  // the SAME solver actions the buttons do (gate the animation, never the state — the step path is
  // the real state update). Keys are ignored while focus is in the picker or any text field so the
  // native select keyboard still works, and space's default page scroll is prevented.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || solver.conn !== "open") return;
      const el = e.target as HTMLElement | null;
      const tag = el?.tagName;
      if (tag === "SELECT" || tag === "INPUT" || tag === "TEXTAREA" || el?.isContentEditable) return;
      if (e.key === " " || e.key === "ArrowRight") {
        e.preventDefault(); // space would otherwise scroll the page
        solver.step();
      } else if (e.key === "p" || e.key === "P") {
        e.preventDefault();
        onPlayPause();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [solver, onPlayPause]);

  return (
    <main className="mx-auto flex min-h-screen max-w-5xl flex-col gap-8 px-6 py-12">
      <header className="flex items-baseline justify-between border-b border-[color:var(--color-border)] pb-4">
        <h1 className="font-[family-name:var(--font-display)] text-4xl font-normal tracking-tight">
          lattice
        </h1>
        <span className="tabular text-xs text-[color:var(--color-ink-mute)]">
          {connLabel(solver.conn)}
        </span>
      </header>

      {racing && solver.race ? (
        // Race mode (SAT-06): two side-by-side panels on one dual-encodable instance, each its own
        // renderer + counters, with the one control bar spanning the top above both. The panels sit
        // side by side at desktop (lg:grid-cols-2 gap-8) and stack single-column (CP above SAT) at
        // tablet/mobile — the panels shrink, the renderers do not.
        <div className="flex flex-col gap-8">
          <div className="flex justify-center">
            <Controls
              puzzleKey={puzzleKey}
              setPuzzleKey={setPuzzleKey}
              engine={effectiveEngine}
              setEngine={setEngine}
              engineOptions={engineOptions}
              playing={playing}
              disabled={solver.conn !== "open"}
              onStart={() => {
                setPlaying(false);
                solver.start(selected.definition, selected.kind, effectiveEngine);
              }}
              onStep={solver.step}
              onPlayPause={onPlayPause}
              onRestart={() => {
                setPlaying(false);
                solver.restart();
              }}
            />
          </div>
          <div className="grid gap-8 lg:grid-cols-2">
            <RacePanel engine="cp" side={solver.race.cp} definition={selected.definition} />
            <RacePanel engine="sat" side={solver.race.sat} definition={selected.definition} />
          </div>
        </div>
      ) : (
        <div className="grid gap-8 lg:grid-cols-[auto_1fr]">
          <section className="flex flex-col items-center gap-5">
            <PuzzleView
              kind={selected.kind}
              grid={solver.grid}
              n={n}
              box={box}
              definition={selected.definition}
              learnedClause={solver.learnedClause}
            />
            <Controls
              puzzleKey={puzzleKey}
              setPuzzleKey={setPuzzleKey}
              engine={effectiveEngine}
              setEngine={setEngine}
              engineOptions={engineOptions}
              playing={playing}
              disabled={solver.conn !== "open"}
              onStart={() => {
                setPlaying(false);
                solver.start(selected.definition, selected.kind, effectiveEngine);
              }}
              onStep={solver.step}
              onPlayPause={onPlayPause}
              onRestart={() => {
                setPlaying(false);
                solver.restart();
              }}
            />
          </section>

          <ThinkingPanel solver={solver} showSatCounters={showSatCounters} />
        </div>
      )}
    </main>
  );
}

// One race panel: a surface card with a caption engine subtitle, its own renderer (the CP panel shows
// the puzzle's native renderer, e.g. GraphView; the SAT panel shows the TrailView of the CNF encoding),
// and its own counter block. Each panel is an accessible region (aria-label "cp engine" / "sat engine")
// so a screen reader distinguishes the two engines (VIZ-08, threat T-05-23). The renderer is the hero;
// the counters sit beneath it (the single-engine hierarchy at panel scale). The SAT panel additionally
// shows the learned-clauses / restarts counters; the CP panel does NOT (they would read 0 and mislead).
function RacePanel({
  engine,
  side,
  definition,
}: {
  engine: "cp" | "sat";
  side: RaceSide;
  definition: string;
}) {
  const n = side.size;
  const box = Math.round(Math.sqrt(n));
  const d = side.currentDecision;
  return (
    <section
      aria-label={`${engine} engine`}
      className="flex flex-col items-center gap-4 rounded-[var(--radius-lg)] border border-[color:var(--color-border)] bg-[color:var(--color-surface)] p-6"
    >
      <div className="flex w-full items-baseline justify-between">
        <span className="font-[family-name:var(--font-display)] text-lg">
          {engine === "cp" ? "cp" : "sat"}
        </span>
        <span className="text-xs text-[color:var(--color-ink-dim)]">
          {engine === "cp" ? "constraint propagation" : "cdcl"}
        </span>
      </div>

      <PuzzleView
        kind={side.kind as PuzzleKind}
        grid={side.grid}
        n={n}
        box={box}
        definition={definition}
        learnedClause={side.learnedClause}
      />

      {/* The per-panel live region: each engine's current decision / last step is read out on its
          own so a screen reader follows the two engines independently (the race-mode aria contract). */}
      <div aria-live="polite" className="flex w-full flex-col gap-1 text-sm">
        <span className="text-[color:var(--color-ink-mute)]">current decision</span>
        <span className="tabular text-[color:var(--color-accent)]">
          {d ? `cell ${d.cell} = ${d.value} @ level ${d.level}` : "--"}
        </span>
      </div>

      <div className="flex w-full flex-col gap-1.5 border-t border-[color:var(--color-border)] pt-4">
        <Counter label="decisions" value={side.counters.decisions} />
        <Counter label="propagations" value={side.counters.propagations} />
        <Counter label="backtracks" value={side.counters.backtracks} />
        <Counter label="conflicts" value={side.counters.conflicts} />
        {/* The SAT-only counters live on the SAT panel only; the CP panel never shows them. */}
        {engine === "sat" && (
          <>
            <Counter label="learned clauses" value={side.counters.learnedClauses} />
            <Counter label="restarts" value={side.counters.restarts} />
          </>
        )}
      </div>

      {side.solved && (
        <p className="tabular w-full text-sm text-[color:var(--color-state-solved)]">
          {engine === "sat" ? "sat" : "solved"}
        </p>
      )}
      {/* Each race panel reflects its OWN engine's result. The unsat line mirrors the solved line:
          conflict-red with a leading ⊥ glyph (the non-color cue, VIZ-08) and role=status so the
          panel's outcome is announced even though the two engines resolve independently. */}
      {side.unsat && (
        <p
          role="status"
          className="tabular w-full text-sm text-[color:var(--color-state-conflict)]"
        >
          <span aria-hidden="true">⊥ </span>
          {engine === "sat" ? "unsat" : "unsat — no solution"}
        </p>
      )}
    </section>
  );
}

function connLabel(conn: string): string {
  if (conn === "open") return "engine connected";
  if (conn === "connecting") return "connecting to engine...";
  return "engine offline - start the lattice-server on :8080";
}

function Controls({
  puzzleKey,
  setPuzzleKey,
  engine,
  setEngine,
  engineOptions,
  playing,
  disabled,
  onStart,
  onStep,
  onPlayPause,
  onRestart,
}: {
  puzzleKey: string;
  setPuzzleKey: (k: string) => void;
  engine: Engine;
  setEngine: (e: Engine) => void;
  engineOptions: { value: Engine; label: string }[];
  playing: boolean;
  disabled: boolean;
  onStart: () => void;
  onStep: () => void;
  onPlayPause: () => void;
  onRestart: () => void;
}) {
  // The second caption appears only when a non-cp engine is reachable (a dual-encodable or dimacs
  // instance), so the race hint never shows on a CP-only puzzle.
  const raceReachable = engineOptions.some((o) => o.value === "race");
  return (
    <div className="flex flex-col items-center gap-1.5">
      <div className="flex flex-wrap items-center justify-center gap-2">
        <select
          value={puzzleKey}
          onChange={(e) => setPuzzleKey(e.target.value)}
          aria-label="puzzle"
          className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border)] bg-[color:var(--color-surface-2)] px-2 py-1.5 text-sm text-[color:var(--color-ink)] ${FOCUS_RING}`}
        >
          {Object.entries(PUZZLES).map(([k, p]) => (
            <option key={k} value={k}>
              {p.label}
            </option>
          ))}
        </select>
        {/* The engine picker: same affordance as the puzzle picker (FOCUS_RING, styling). It drives
            the engine field on start; it offers only the engines the selected instance can run. */}
        <select
          value={engine}
          onChange={(e) => setEngine(e.target.value as Engine)}
          aria-label="engine"
          disabled={engineOptions.length <= 1}
          className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border)] bg-[color:var(--color-surface-2)] px-2 py-1.5 text-sm text-[color:var(--color-ink)] disabled:opacity-40 ${FOCUS_RING}`}
        >
          {engineOptions.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
        <Btn primary disabled={disabled} onClick={onStart}>
          start
        </Btn>
        <Btn disabled={disabled} onClick={onStep}>
          step
        </Btn>
        <Btn disabled={disabled} onClick={onPlayPause}>
          {playing ? "pause" : "play"}
        </Btn>
        <Btn disabled={disabled} onClick={onRestart}>
          restart
        </Btn>
      </div>
      <span className="text-xs text-[color:var(--color-ink-mute)]">
        hard presets make the search visibly backtrack
      </span>
      {raceReachable && (
        <span className="text-xs text-[color:var(--color-ink-mute)]">
          cp vs sat races both engines on one instance
        </span>
      )}
    </div>
  );
}

function Btn({
  children,
  onClick,
  primary,
  disabled,
}: {
  children: ReactNode;
  onClick: () => void;
  primary?: boolean;
  disabled?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`rounded-[var(--radius-sm)] border px-3 py-1.5 text-sm transition-colors disabled:opacity-40 ${FOCUS_RING} ${
        primary
          ? "border-[color:var(--color-accent)] bg-[color:var(--color-accent)] text-[#16161a] hover:bg-[color:var(--color-accent-dim)]"
          : "border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] text-[color:var(--color-ink-dim)] hover:text-[color:var(--color-ink)]"
      }`}
    >
      {children}
    </button>
  );
}

function ThinkingPanel({
  solver,
  showSatCounters,
}: {
  solver: ReturnType<typeof useSolver>;
  showSatCounters: boolean;
}) {
  const d = solver.currentDecision;
  return (
    <aside className="flex flex-col gap-5 rounded-[var(--radius-md)] border border-[color:var(--color-border)] bg-[color:var(--color-surface)] p-5">
      <h2 className="font-[family-name:var(--font-display)] text-lg">thinking</h2>

      {/* the reasoning, announced as an aria-live region (VIZ-08): the current decision and the last
          step (which carries the propagation/conflict text) are read out as they change, so a screen
          reader user follows the solve without watching the grid. polite: announce after the current
          utterance, never interrupting. */}
      <div aria-live="polite" className="flex flex-col gap-5">
        <div className="flex flex-col gap-1 text-sm">
          <span className="text-[color:var(--color-ink-mute)]">current decision</span>
          <span className="tabular text-[color:var(--color-accent)]">
            {d ? `cell ${d.cell} = ${d.value} @ level ${d.level}` : "--"}
          </span>
        </div>

        <div className="flex flex-col gap-1 text-sm">
          <span className="text-[color:var(--color-ink-mute)]">last step</span>
          <span className="tabular text-[color:var(--color-ink-dim)]">
            {solver.lastReason || "--"}
          </span>
        </div>
      </div>

      <div className="flex flex-col gap-1.5 border-t border-[color:var(--color-border)] pt-4">
        <Counter label="decisions" value={solver.counters.decisions} />
        <Counter label="propagations" value={solver.counters.propagations} />
        <Counter label="backtracks" value={solver.counters.backtracks} />
        <Counter label="conflicts" value={solver.counters.conflicts} />
        {/* The two SAT-only counters, shown only for a SAT-running engine (they would read 0 and
            mislead on a CP solve). Tallied UI-side from the learn/restart events. */}
        {showSatCounters && (
          <>
            <Counter label="learned clauses" value={solver.counters.learnedClauses} />
            <Counter label="restarts" value={solver.counters.restarts} />
          </>
        )}
      </div>

      <div className="border-t border-[color:var(--color-border)] pt-4">
        <Minimap minimap={solver.minimap} />
      </div>

      {solver.solved && (
        <p className="tabular text-sm text-[color:var(--color-state-solved)]">solved</p>
      )}
      {/* The UNSAT result line (the dead-end peer of `solved`): conflict-red with a leading ⊥ glyph
          so the result reads without relying on color alone (VIZ-08), and role=status so a screen
          reader announces it. The "no solution" last-step text in the aria-live region above carries
          the same fact in prose; this is the at-a-glance result the frozen trail otherwise hides. */}
      {solver.unsat && (
        <p role="status" className="tabular text-sm text-[color:var(--color-state-conflict)]">
          <span aria-hidden="true">⊥ </span>unsat — no solution
        </p>
      )}
    </aside>
  );
}

function Counter({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex items-baseline justify-between">
      <span className="text-sm text-[color:var(--color-ink-mute)]">{label}</span>
      <span className="tabular text-base text-[color:var(--color-ink)]">{value}</span>
    </div>
  );
}
