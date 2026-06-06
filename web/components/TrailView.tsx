"use client";

// The SAT assignment-trail view (SAT-06). A SAT instance has no inherent 2D geometry, so this renders
// the assignment VECTOR: one square cell per SAT variable, in variable-id order, grouped into
// horizontal decision-level bands. It is the SAT peer of GraphView / QueensBoard / NonogramBoard and
// owns the var<->coordinate map exactly as they do (cell index == variable id, the engine's natural
// mapping every event speaks). The shared cell-state model (lib/replay) carries everything it needs:
// `value` is the polarity (0/1), `status` distinguishes decided / propagated / conflict / solved, and
// the optional `level` bands the cell.
//
// Color is NEVER the only signal for any SAT state (VIZ-08, the SAT-06 core). Each fact carries a
// non-color second signal:
//   - polarity:  a centered T / F glyph (mono); unassigned shows no glyph (blank). Polarity is read
//                off the glyph, not the fill hue.
//   - decision vs propagated: an accent RING around a decision cell vs a plain BORDER for a unit-
//                propagated literal — the absence of the ring is the "forced, not chosen" cue. (The
//                SAT engine emits trail assignments as propagate events; a true SAT decision, when one
//                is emitted, takes the ring.)
//   - in a conflict clause: the var-id is STRUCK THROUGH and the cell flashes cell-conflict.
//   - decision level: a graph-N background tint groups a band, and an L0 / L1 LABEL at the band start
//                is the real signal (the band number, not the hue, identifies the level — the same
//                "label, not hue" rule the graph view follows).
//
// Scale: the trail wraps to the canvas width and cell size shrinks with the variable count (bounded,
// the Nonogram cell-sizing model) so tens fit large and hundreds still fit; beyond a cap the trailing
// unassigned vars collapse into a `+N vars` count (the minimap's +N idiom). The polarity glyph never
// drops below numeral size. All motion is the existing CSS classes (cell-decision / cell-conflict),
// already collapsed by the global reduced-motion block in globals.css — the state stays legible
// stepwise without any animation (the glyph, ring/border, strike, and band labels carry the meaning).

import { useMemo } from "react";
import { formatClause, type Cell } from "../lib/replay";

// The bounded cell size: shrinks as the variable count grows so the vector fits the canvas without
// horizontal scroll, but never smaller than MIN so the T/F glyph stays at numeral size (the polarity
// signal is load-bearing). The Nonogram board uses the same min(cap, floor(width / count)) shape.
const CANVAS = 360;
const CELL_MAX = 40;
const CELL_MIN = 22;
// Beyond this many variables, collapse the trailing unassigned run into a `+N vars` count so the view
// stays a glance (the minimap's collapse idiom). The assigned bands always render in full.
const VAR_CAP = 96;

// A contiguous run of cells at one decision level (or the trailing unassigned run). `level === null`
// is the unassigned group, drawn untinted and dimmed; a numeric level takes a graph-N band tint.
interface Band {
  level: number | null;
  vars: number[];
}

// The graph-N tint for a level band, N = level mod 4 (the Phase-4 ramp reused as a categorical depth
// read, NOT a new semantic — the band LABEL is what identifies the level). The unassigned group has
// no tint.
function bandTint(level: number | null): string {
  if (level === null) return "transparent";
  switch (level % 4) {
    case 0:
      return "color-mix(in oklab, var(--color-graph-1) 14%, transparent)";
    case 1:
      return "color-mix(in oklab, var(--color-graph-2) 14%, transparent)";
    case 2:
      return "color-mix(in oklab, var(--color-graph-3) 18%, transparent)";
    default:
      return "color-mix(in oklab, var(--color-graph-4) 18%, transparent)";
  }
}

// Group the assignment vector into level-bands. Assigned cells (decided/propagated/solved with a
// numeric level) are grouped by their level in ascending level order; within a level the variables
// stay in id order. Every still-unassigned variable falls into the trailing `level: null` group so the
// full vector always renders (never a spinner). A cell with no level (e.g. a solved cell that was
// forced at level 0) reads as level 0.
function toBands(grid: Cell[]): Band[] {
  const assigned = new Map<number, number[]>(); // level -> var ids
  const unassigned: number[] = [];
  grid.forEach((cell, v) => {
    const isAssigned =
      cell.status === "decided" || cell.status === "propagated" || cell.status === "solved";
    if (isAssigned && cell.value !== null) {
      const lvl = cell.level ?? 0;
      const run = assigned.get(lvl) ?? [];
      run.push(v);
      assigned.set(lvl, run);
    } else {
      unassigned.push(v);
    }
  });
  const bands: Band[] = [...assigned.keys()]
    .sort((a, b) => a - b)
    .map((level) => ({ level, vars: assigned.get(level)! }));
  if (unassigned.length > 0) bands.push({ level: null, vars: unassigned });
  return bands;
}

export function TrailView({
  grid,
  learnedClause,
}: {
  grid: Cell[];
  learnedClause?: number[] | null;
}) {
  const bands = useMemo(() => toBands(grid), [grid]);

  if (grid.length === 0) {
    return (
      <div className="flex h-[28rem] w-[28rem] items-center justify-center rounded-[var(--radius-md)] border border-[color:var(--color-border)] text-sm text-[color:var(--color-ink-mute)]">
        pick a puzzle and press start
      </div>
    );
  }

  // Bound the cell size by the variable count so the vector fits the canvas (the Nonogram model).
  const cell = Math.max(CELL_MIN, Math.min(CELL_MAX, Math.floor(CANVAS / Math.max(1, Math.ceil(Math.sqrt(grid.length))))));

  // Collapse the trailing unassigned run beyond the cap into a `+N vars` count so the view stays a
  // glance (the minimap idiom). The assigned bands always render in full; only the still-unassigned
  // tail is collapsed.
  const renderedBands: Band[] = [];
  let collapsed = 0;
  let shown = 0;
  for (const band of bands) {
    if (band.level === null) {
      const room = Math.max(0, VAR_CAP - shown);
      if (band.vars.length > room) {
        renderedBands.push({ level: null, vars: band.vars.slice(0, room) });
        collapsed = band.vars.length - room;
        shown += room;
        continue;
      }
    }
    renderedBands.push(band);
    shown += band.vars.length;
  }

  return (
    <div
      className="flex w-[28rem] flex-col gap-3 rounded-[var(--radius-md)] border border-[color:var(--color-border)] bg-[color:var(--color-surface)] p-3"
      role="img"
      aria-label="sat assignment trail"
    >
      <div className="flex flex-col gap-2">
        {renderedBands.map((band) => (
          <div key={band.level === null ? "unassigned" : `L${band.level}`} className="flex items-start gap-2">
            {/* The band label is the real level signal (L0, L1, ...); the tint only groups. */}
            <span
              className="mt-1 w-7 shrink-0 text-[color:var(--color-ink-mute)] text-xs"
              style={{ fontFamily: "var(--font-sans)" }}
            >
              {band.level === null ? "—" : `L${band.level}`}
            </span>
            <div
              className="flex flex-1 flex-wrap gap-1 rounded-[var(--radius-sm)] p-1"
              style={{ background: bandTint(band.level) }}
            >
              {band.vars.map((v) => (
                <TrailCell key={v} v={v} cell={grid[v]} size={cell} />
              ))}
            </div>
          </div>
        ))}
      </div>

      {collapsed > 0 && (
        <span className="tabular text-[color:var(--color-ink-mute)] text-xs">+{collapsed} vars</span>
      )}

      {/* The learned-clause chip strip: the most recent 1UIP clause printed as math text (the second
          signal is the text itself, not a color), bordered accent for the duration of one decision
          pulse then settling to a plain border. The cell ring tie-back happens in the trail above. */}
      {learnedClause && learnedClause.length > 0 && (
        <div className="flex items-center gap-2 border-t border-[color:var(--color-border)] pt-2">
          <span className="text-[color:var(--color-ink-mute)] text-xs">learned</span>
          <span
            className="tabular cell-decision rounded-[var(--radius-sm)] border border-[color:var(--color-accent)] px-2 py-0.5 text-xs text-[color:var(--color-ink)]"
            style={{ background: "var(--color-surface-2)" }}
          >
            {formatClause(learnedClause)}
          </span>
        </div>
      )}
    </div>
  );
}

// One trail cell: the polarity fill + T/F glyph (the polarity second signal), an accent ring for a
// decision vs a plain border for a propagated literal (the ring/no-ring second signal), a struck
// var-id + cell-conflict flash for a conflict literal, and a solved border on the solution. Color is
// never the only cue for any of these.
function TrailCell({ v, cell, size }: { v: number; cell: Cell | undefined; size: number }) {
  const status = cell?.status ?? "open";
  const value = cell?.value ?? null;
  const assigned = value !== null && (status === "decided" || status === "propagated" || status === "solved");
  const conflict = status === "conflict";
  const decided = status === "decided";
  const solved = status === "solved";

  // true polarity takes an ink-tinted fill; false takes surface-2; unassigned is a dimmed surface-2.
  // The GLYPH (T / F / blank), not the fill, is what reads the polarity (VIZ-08).
  const fill = !assigned
    ? "var(--color-surface-2)"
    : value === 1
      ? "color-mix(in oklab, var(--color-ink) 22%, var(--color-surface-2))"
      : "var(--color-surface-2)";
  const border = solved
    ? "var(--color-state-solved)"
    : conflict
      ? "var(--color-state-conflict)"
      : "var(--color-border)";
  const borderWidth = solved || conflict ? "1.5px" : "0.5px";
  // The numeral glyph stays at a readable size regardless of the cell shrink (polarity is load-bearing).
  const glyph = size * 0.42;
  const idSize = Math.max(8, size * 0.26);

  return (
    <div
      className={`relative flex items-center justify-center rounded-[var(--radius-sm)] transition-colors ${
        conflict ? "cell-conflict" : ""
      } ${decided ? "cell-decision" : ""}`}
      style={{
        width: size,
        height: size,
        background: fill,
        borderWidth,
        borderStyle: "solid",
        borderColor: border,
        opacity: assigned ? 1 : 0.55,
      }}
    >
      {/* The decision ring (an accent stroke just inside the border): the decision second signal. A
          propagated literal has no ring, so the missing ring reads as "forced, not chosen". */}
      {decided && (
        <span
          className="pointer-events-none absolute rounded-[var(--radius-sm)]"
          style={{
            inset: 1,
            border: "1.5px solid var(--color-accent)",
          }}
        />
      )}
      {assigned && (
        <span
          className="tabular leading-none"
          style={{ fontSize: glyph, color: "var(--color-ink)", fontWeight: 500 }}
        >
          {value === 1 ? "T" : "F"}
        </span>
      )}
      {/* The var-id subscript; struck through when the literal is in a conflict clause (the falsified-
          literal shape cue, legible under reduced motion and for color-vision deficiency). */}
      <span
        className="tabular pointer-events-none absolute bottom-0 right-0.5 leading-none text-[color:var(--color-ink-mute)]"
        style={{
          fontSize: idSize,
          textDecoration: conflict ? "line-through" : undefined,
          textDecorationColor: conflict ? "var(--color-state-conflict)" : undefined,
        }}
      >
        {v}
      </span>
    </div>
  );
}
