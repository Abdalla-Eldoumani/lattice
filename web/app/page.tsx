"use client";

// The Sudoku visualizer (VIZ-01/02/03): a 9x9 grid that animates the engine's event stream, the
// step/play/pause/restart controls that drive it, and the thinking panel with the live counters.

import { type ReactNode, useCallback, useEffect, useState } from "react";
import { useSolver } from "../lib/useSolver";
import { PuzzleView } from "../components/PuzzleView";
import { Minimap } from "../components/Minimap";
import { DEFAULT_PUZZLE_KEY, PUZZLES } from "../lib/puzzles";

// the shared focus ring: a visible 2px --color-border-strong outline on every control, so a keyboard
// user always sees where focus is (the accessibility contract, VIZ-08). focus-visible (not focus)
// keeps it keyboard-only, never a mouse-click halo.
const FOCUS_RING =
  "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[color:var(--color-border-strong)]";

export default function Home() {
  const solver = useSolver();
  const [puzzleKey, setPuzzleKey] = useState(DEFAULT_PUZZLE_KEY);
  const [playing, setPlaying] = useState(false);
  const n = solver.size;
  const box = Math.round(Math.sqrt(n));
  const selected = PUZZLES[puzzleKey];

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

      <div className="grid gap-8 lg:grid-cols-[auto_1fr]">
        <section className="flex flex-col items-center gap-5">
          <PuzzleView
            kind={selected.kind}
            grid={solver.grid}
            n={n}
            box={box}
            definition={selected.definition}
          />
          <Controls
            puzzleKey={puzzleKey}
            setPuzzleKey={setPuzzleKey}
            playing={playing}
            disabled={solver.conn !== "open"}
            onStart={() => {
              setPlaying(false);
              solver.start(selected.definition, selected.kind);
            }}
            onStep={solver.step}
            onPlayPause={onPlayPause}
            onRestart={() => {
              setPlaying(false);
              solver.restart();
            }}
          />
        </section>

        <ThinkingPanel solver={solver} />
      </div>
    </main>
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
  playing,
  disabled,
  onStart,
  onStep,
  onPlayPause,
  onRestart,
}: {
  puzzleKey: string;
  setPuzzleKey: (k: string) => void;
  playing: boolean;
  disabled: boolean;
  onStart: () => void;
  onStep: () => void;
  onPlayPause: () => void;
  onRestart: () => void;
}) {
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

function ThinkingPanel({ solver }: { solver: ReturnType<typeof useSolver> }) {
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
      </div>

      <div className="border-t border-[color:var(--color-border)] pt-4">
        <Minimap minimap={solver.minimap} />
      </div>

      {solver.solved && (
        <p className="tabular text-sm text-[color:var(--color-state-solved)]">solved</p>
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
