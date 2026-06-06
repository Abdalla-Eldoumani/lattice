"use client";

// The nonogram board (VIZ-04, ENCODE-04 render). A grid with the row clues down the left and the
// column clues across the top, animating the engine's cell-boolean stream into the recognizable
// picture. The nonogram encoder uses one variable per grid cell (cell = row-major index r*cols + c)
// whose VALUE is the bit (1 ink, 0 blank), so the shared cell-state model already carries everything
// this renderer needs: it owns the var<->coordinate interpretation (cell index -> (r,c)) and reads
// each cell's state directly, the same client-owns-geometry pattern GraphView and QueensBoard follow.
//
// The three cell states are visually distinct WITHOUT relying on hue (VIZ-08, the second signal):
//   - filled  (ink block): value === 1, or the only surviving candidate is 1 (line-AC forced ink)
//   - eliminated (faint x): value === 0, or the only surviving candidate is 0 (forced blank)
//   - unknown (blank): still both bits possible
// A filling cell pulses its border once in accent (cell-decision); an eliminated cell fades to the
// faint x; a contradicted clue flashes the conflict color; solved cells settle to a solved border.

import { useMemo } from "react";
import { type Cell } from "../lib/replay";

interface NonogramSpec {
  rows: number;
  cols: number;
  rowClues: number[][];
  colClues: number[][];
}

// A clue stack is an array of finite numbers (one run length per block). A non-array entry or a
// NaN/Infinity run would propagate into the layout sizing or silently mis-render the board, so the
// renderer fails closed on it rather than drawing a board that does not match the puzzle.
function isClueStack(c: unknown): c is number[] {
  return Array.isArray(c) && c.every((run) => typeof run === "number" && Number.isFinite(run));
}

// Parse the bundled nonogram definition once (the client owns its geometry, like GraphView). A
// malformed definition yields a small empty board rather than throwing, so the canvas still renders.
// The renderer is the "client owns geometry" boundary: a ragged or oversized clue array (lengths not
// matching rows/cols, or a non-array inner clue) returns the empty board instead of a wrong picture.
function parseSpec(definition: string): NonogramSpec {
  try {
    const d = JSON.parse(definition) as Partial<NonogramSpec>;
    if (
      Number.isInteger(d.rows) &&
      Number.isInteger(d.cols) &&
      Array.isArray(d.rowClues) &&
      Array.isArray(d.colClues) &&
      d.rowClues.length === d.rows &&
      d.colClues.length === d.cols &&
      d.rowClues.every(isClueStack) &&
      d.colClues.every(isClueStack)
    ) {
      return {
        rows: d.rows as number,
        cols: d.cols as number,
        rowClues: d.rowClues as number[][],
        colClues: d.colClues as number[][],
      };
    }
  } catch {
    // fall through to the empty board
  }
  return { rows: 0, cols: 0, rowClues: [], colClues: [] };
}

// The three render states, derived from the shared cell-state model. A decided/forced 1 is ink; a
// decided/forced 0 is eliminated (the faint x); anything still ambiguous is unknown.
type Mark = "ink" | "eliminated" | "unknown";

function markOf(cell: Cell | undefined): Mark {
  if (!cell) return "unknown";
  if (cell.value === 1) return "ink";
  if (cell.value === 0) return "eliminated";
  // No decision yet: read the surviving candidates the line-AC propagation narrowed.
  if (cell.candidates.length === 1) return cell.candidates[0] === 1 ? "ink" : "eliminated";
  return "unknown";
}

export function NonogramBoard({ definition, grid }: { definition: string; grid: Cell[] }) {
  const spec = useMemo(() => parseSpec(definition), [definition]);
  const { rows, cols, rowClues, colClues } = spec;

  if (rows === 0 || cols === 0) {
    return (
      <div className="flex h-[28rem] w-[28rem] items-center justify-center rounded-[var(--radius-md)] border border-[color:var(--color-border)] text-sm text-[color:var(--color-ink-mute)]">
        pick a puzzle and press start
      </div>
    );
  }

  // The longest clue stacks set the width/height of the clue gutters so the numbers never clip.
  const maxRowClue = Math.max(1, ...rowClues.map((c) => c.length));
  const maxColClue = Math.max(1, ...colClues.map((c) => c.length));
  // Keep the cells square and bounded so clue tracks fit at 375 without clipping (VIZ-08 / Layout).
  const cell = Math.min(28, Math.floor(360 / (cols + maxRowClue)));
  const clueText = "var(--color-ink-dim)";

  return (
    <div className="inline-flex flex-col rounded-[var(--radius-md)] border border-[color:var(--color-border)] bg-[color:var(--color-bg)] p-2">
      {/* Column clues across the top, with an empty corner over the row-clue gutter. */}
      <div className="flex">
        <div style={{ width: maxRowClue * cell, height: maxColClue * cell }} />
        <div className="flex">
          {Array.from({ length: cols }, (_, c) => (
            <div
              key={c}
              className="tabular flex flex-col items-center justify-end bg-[color:var(--color-surface)]"
              style={{ width: cell, height: maxColClue * cell, fontSize: "0.6rem", color: clueText }}
            >
              {(colClues[c] ?? []).map((run, i) => (
                <span key={i} className="leading-tight">
                  {run}
                </span>
              ))}
            </div>
          ))}
        </div>
      </div>

      {/* Each grid row: its row clues in the left gutter, then the solve cells. */}
      {Array.from({ length: rows }, (_, r) => (
        <div key={r} className="flex">
          <div
            className="tabular flex items-center justify-end gap-1 bg-[color:var(--color-surface)] pr-1"
            style={{ width: maxRowClue * cell, height: cell, fontSize: "0.6rem", color: clueText }}
          >
            {(rowClues[r] ?? []).map((run, i) => (
              <span key={i} className="leading-none">
                {run}
              </span>
            ))}
          </div>
          <div className="flex">
            {Array.from({ length: cols }, (_, c) => (
              <NonoCell key={c} cell={grid[r * cols + c]} size={cell} />
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

function NonoCell({ cell, size }: { cell: Cell | undefined; size: number }) {
  const mark = markOf(cell);
  const status = cell?.status ?? "open";
  const conflict = status === "conflict";
  const decided = status === "decided";
  const solved = status === "solved";
  const border = solved
    ? "var(--color-state-solved)"
    : conflict
      ? "var(--color-state-conflict)"
      : "var(--color-border)";
  return (
    <div
      className={`relative flex items-center justify-center transition-colors ${
        conflict ? "cell-conflict" : ""
      } ${decided ? "cell-decision" : ""}`}
      style={{
        width: size,
        height: size,
        borderWidth: "0.5px",
        borderColor: border,
        background: "var(--color-bg)",
      }}
    >
      {mark === "ink" && (
        // an ink block: the filled state, a solid square (shape, not hue) — the primary second signal.
        <div
          className="transition-colors"
          style={{ width: "100%", height: "100%", background: "var(--color-ink)" }}
        />
      )}
      {mark === "eliminated" && (
        // a faint x: the propagation second signal for a cell that can no longer be ink (VIZ-08).
        <span
          className="leading-none"
          style={{ color: "var(--color-state-propagate)", fontSize: size * 0.7 }}
        >
          {"×"}
        </span>
      )}
      {/* unknown: blank, no glyph */}
    </div>
  );
}
