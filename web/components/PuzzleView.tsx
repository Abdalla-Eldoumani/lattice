"use client";

// The puzzle-view dispatcher (VIZ-04): one component that switches on the puzzle `kind` and renders
// the matching per-puzzle view from the shared `useSolver` cell-state model. Sudoku is the existing
// grid, moved here unchanged; graph, queens, and nonogram each have their dedicated renderer. The
// dispatcher is exhaustive over `PuzzleKind` so a new kind is a compile error until wired.

import { type Cell } from "../lib/replay";
import { type PuzzleKind } from "../lib/protocol";
import { GraphView } from "./GraphView";
import { QueensBoard } from "./QueensBoard";
import { NonogramBoard } from "./NonogramBoard";

export function PuzzleView({
  kind,
  grid,
  n,
  box,
  definition,
}: {
  kind: PuzzleKind;
  grid: Cell[];
  n: number;
  box: number;
  definition: string;
}) {
  switch (kind) {
    case "sudoku":
      return <SudokuGrid grid={grid} n={n} box={box} />;
    case "graph":
      return <GraphView definition={definition} grid={grid} />;
    case "queens":
      return <QueensBoard grid={grid} n={n} />;
    case "nonogram":
      return <NonogramBoard definition={definition} grid={grid} />;
  }
}

export function SudokuGrid({ grid, n, box }: { grid: Cell[]; n: number; box: number }) {
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
        <span className="font-[family-name:var(--font-display)] text-2xl" style={{ color }}>
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
