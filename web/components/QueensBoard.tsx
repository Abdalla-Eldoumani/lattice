"use client";

// The N-queens board (VIZ-04). An n x n chessboard that animates the engine's placements. The queens
// encoder uses one variable per ROW (cell = row index 0..n-1) whose VALUE is the queen's COLUMN
// (0..n-1), so a `decision cell=2 value=5` means "queen on row 2, column 5". This renderer owns that
// var<->coordinate interpretation: it reads the shared cell-state model row by row and draws a queen
// glyph on the placed square. The queen glyph (a shape, not a color) is the second non-color signal
// for a placement (VIZ-08); an attacked square flashes the conflict color and the thinking panel
// announces it. Depth comes from the alternating surface fills and 1px borders, never a shadow.

import { type Cell } from "../lib/replay";

export function QueensBoard({ grid, n }: { grid: Cell[]; n: number }) {
  if (grid.length === 0 || n <= 0) {
    return (
      <div className="flex h-[28rem] w-[28rem] items-center justify-center rounded-[var(--radius-md)] border border-[color:var(--color-border)] text-sm text-[color:var(--color-ink-mute)]">
        pick a puzzle and press start
      </div>
    );
  }

  // The model seeds one cell per row (the queens var). cell.value is the queen's column on that row,
  // or null if the row is unplaced; cell.status drives the second-signal styling.
  const rowCell = (r: number): Cell | undefined => grid[r];

  return (
    <div
      className="grid border-2 border-[color:var(--color-border-strong)]"
      style={{
        gridTemplateColumns: `repeat(${n}, minmax(0, 1fr))`,
        width: "28rem",
        height: "28rem",
      }}
    >
      {Array.from({ length: n * n }, (_, i) => {
        const r = Math.floor(i / n);
        const c = i % n;
        const cell = rowCell(r);
        // a queen is on (r,c) when this row's assigned column equals c.
        const queenHere = cell?.value === c;
        // the attacked-square flash and the placement pulse read off the ROW cell's status, which the
        // shared reducer sets from the stream (conflict on a clash, decided on a placement).
        const conflict = queenHere && cell?.status === "conflict";
        const decided = queenHere && cell?.status === "decided";
        const solved = queenHere && cell?.status === "solved";
        // light squares surface-2, dark squares surface; alternate by (r+c) parity.
        const base = (r + c) % 2 === 0 ? "var(--color-surface-2)" : "var(--color-surface)";
        const glyphColor = solved
          ? "var(--color-state-solved)"
          : conflict
            ? "var(--color-state-conflict)"
            : "var(--color-ink)";
        // a placed-and-solved square settles to a solved border (a non-color shape cue) and carries a
        // small check mark, so the solved state does not rest on the green glyph hue alone (VIZ-08).
        const border = solved ? "var(--color-state-solved)" : "var(--color-border)";
        const borderWidth = solved ? "1.5px" : "0.5px";
        return (
          <div
            key={i}
            className={`relative flex items-center justify-center transition-colors ${
              conflict ? "cell-conflict" : ""
            } ${decided ? "cell-decision" : ""}`}
            style={{ background: base, borderWidth, borderStyle: "solid", borderColor: border }}
          >
            {queenHere && (
              <span
                className="font-[family-name:var(--font-display)] leading-none"
                style={{ color: glyphColor, fontSize: `min(${Math.floor(360 / n)}px, 2.5rem)` }}
              >
                {/* black chess queen U+265B: shape carries the placement signal, not color (VIZ-08) */}
                {"♛"}
              </span>
            )}
            {solved && queenHere && (
              // the check mark (U+2713): the solved second signal, a shape independent of the border
              // and glyph hue. Tucked in the corner so it never obscures the queen.
              <span
                className="absolute right-0 top-0 leading-none"
                style={{ color: "var(--color-state-solved)", fontSize: `min(${Math.floor(140 / n)}px, 0.75rem)` }}
              >
                {"✓"}
              </span>
            )}
          </div>
        );
      })}
    </div>
  );
}
