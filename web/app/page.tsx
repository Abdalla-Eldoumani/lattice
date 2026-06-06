"use client";

// The Sudoku visualizer (VIZ-01/02/03): a 9x9 grid that animates the engine's event stream, the
// step/play/pause/restart controls that drive it, and the thinking panel with the live counters.

import { type ReactNode, useState } from "react";
import { type Cell, useSolver } from "../lib/useSolver";

const PUZZLES: Record<string, string> = {
  easy: "53..7....\n6..195...\n.98....6.\n8...6...3\n4..8.3..1\n7...2...6\n.6....28.\n...419..5\n....8..79",
  "hard-17": ".......1.\n4........\n.2.......\n....5.4.7\n..8...3..\n..1.9....\n3..4..2..\n.5.1.....\n...8.6...",
  "4x4": "1...\n...2\n.3..\n..4.",
};

export default function Home() {
  const solver = useSolver();
  const [puzzleKey, setPuzzleKey] = useState("easy");
  const [playing, setPlaying] = useState(false);
  const n = solver.size;
  const box = Math.round(Math.sqrt(n));

  const onPlayPause = () => {
    if (playing) {
      solver.pause();
      setPlaying(false);
    } else {
      solver.play(12);
      setPlaying(true);
    }
  };

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
          <SudokuGrid grid={solver.grid} n={n} box={box} />
          <Controls
            puzzleKey={puzzleKey}
            setPuzzleKey={setPuzzleKey}
            playing={playing}
            disabled={solver.conn !== "open"}
            onStart={() => {
              setPlaying(false);
              solver.start(PUZZLES[puzzleKey]);
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

function SudokuGrid({ grid, n, box }: { grid: Cell[]; n: number; box: number }) {
  if (grid.length === 0) {
    return (
      <div className="flex h-[28rem] w-[28rem] items-center justify-center rounded-[var(--radius-md)] border border-[color:var(--color-border)] text-sm text-[color:var(--color-ink-mute)]">
        pick a puzzle and press start
      </div>
    );
  }
  return (
    <div
      className="grid border-2 border-[color:var(--color-border-strong)] bg-[color:var(--color-surface)]"
      style={{ gridTemplateColumns: `repeat(${n}, minmax(0, 1fr))`, width: "28rem", height: "28rem" }}
    >
      {grid.map((cell, i) => {
        const r = Math.floor(i / n);
        const c = i % n;
        const thickRight = (c + 1) % box === 0 && c + 1 !== n;
        const thickBottom = (r + 1) % box === 0 && r + 1 !== n;
        return (
          <CellView
            key={i}
            cell={cell}
            n={n}
            box={box}
            thickRight={thickRight}
            thickBottom={thickBottom}
          />
        );
      })}
    </div>
  );
}

function CellView({
  cell,
  n,
  box,
  thickRight,
  thickBottom,
}: {
  cell: Cell;
  n: number;
  box: number;
  thickRight: boolean;
  thickBottom: boolean;
}) {
  const color =
    cell.status === "conflict"
      ? "var(--color-state-conflict)"
      : cell.status === "solved"
        ? "var(--color-state-solved)"
        : cell.status === "decided"
          ? "var(--color-accent)"
          : "var(--color-ink)";
  return (
    <div
      className={`relative flex items-center justify-center border-[0.5px] border-[color:var(--color-border)] transition-colors ${
        cell.status === "conflict" ? "cell-conflict" : ""
      } ${cell.status === "decided" ? "cell-decision" : ""}`}
      style={{
        borderRightWidth: thickRight ? 2 : undefined,
        borderRightColor: thickRight ? "var(--color-border-strong)" : undefined,
        borderBottomWidth: thickBottom ? 2 : undefined,
        borderBottomColor: thickBottom ? "var(--color-border-strong)" : undefined,
      }}
    >
      {cell.value !== null ? (
        <span
          className="font-[family-name:var(--font-display)] text-2xl"
          style={{ color }}
        >
          {cell.value}
        </span>
      ) : (
        <div
          className="tabular grid h-full w-full p-[2px] text-[color:var(--color-ink-mute)]"
          style={{ gridTemplateColumns: `repeat(${box}, 1fr)`, fontSize: "0.5rem", lineHeight: 1 }}
        >
          {Array.from({ length: n }, (_, k) => k + 1).map((d) => (
            <span
              key={d}
              className="flex items-center justify-center transition-opacity"
              style={{ opacity: cell.candidates.includes(d) ? 1 : 0 }}
            >
              {d}
            </span>
          ))}
        </div>
      )}
    </div>
  );
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
    <div className="flex flex-wrap items-center justify-center gap-2">
      <select
        value={puzzleKey}
        onChange={(e) => setPuzzleKey(e.target.value)}
        className="rounded-[var(--radius-sm)] border border-[color:var(--color-border)] bg-[color:var(--color-surface-2)] px-2 py-1.5 text-sm text-[color:var(--color-ink)]"
      >
        {Object.keys(PUZZLES).map((k) => (
          <option key={k} value={k}>
            {k}
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
      className={`rounded-[var(--radius-sm)] border px-3 py-1.5 text-sm transition-colors disabled:opacity-40 ${
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

      <div className="flex flex-col gap-1 text-sm">
        <span className="text-[color:var(--color-ink-mute)]">current decision</span>
        <span className="tabular text-[color:var(--color-accent)]">
          {d ? `cell ${d.cell} = ${d.value} @ level ${d.level}` : "--"}
        </span>
      </div>

      <div className="flex flex-col gap-1 text-sm">
        <span className="text-[color:var(--color-ink-mute)]">last step</span>
        <span className="tabular text-[color:var(--color-ink-dim)]">{solver.lastReason || "--"}</span>
      </div>

      <div className="flex flex-col gap-1.5 border-t border-[color:var(--color-border)] pt-4">
        <Counter label="decisions" value={solver.counters.decisions} />
        <Counter label="propagations" value={solver.counters.propagations} />
        <Counter label="backtracks" value={solver.counters.backtracks} />
        <Counter label="conflicts" value={solver.counters.conflicts} />
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
