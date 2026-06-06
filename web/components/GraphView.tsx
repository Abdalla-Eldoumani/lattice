"use client";

// The graph-coloring view (VIZ-06, VIZ-08). An inline SVG that draws the graph from the fixed x/y
// coordinates bundled in the puzzle JSON and never re-lays-out as colors change: the layout is read
// once from the definition and is static for the life of a solve (VIZ-06). A vertex taking a color
// fills with a categorical color from the ramp AND carries a color-id label inside it, so color is
// never the only signal for the color class (VIZ-08, the second signal). Conflict is a DISTINCT code
// path from the fill: a clashing edge and both its endpoint circles stroke in the conflict color,
// rather than swapping a categorical fill (VIZ-08, the conflict second signal).

import { useMemo } from "react";
import { type Cell } from "../lib/replay";

interface Vertex {
  id: number;
  x: number;
  y: number;
}

interface GraphLayout {
  vertices: Vertex[];
  edges: [number, number][];
  k: number;
}

// The fixed-layout viewport the fixtures are authored in (petersen.json: 400x400). Read once.
const VIEWBOX = 400;

// Map an assigned color value (1..k) to a categorical fill from the graph ramp (--color-graph-1..4,
// defined in globals.css). The ramp is warm-neutral + ochre per the design contract: color alone
// never identifies the class (the in-vertex label is the real signal, VIZ-08), so these only need to
// be visually distinct, never semantic. They are deliberately NOT the state colors (conflict/solved
// mean a solver state, not a color class).
function categoricalFill(value: number): string {
  switch (value) {
    case 1:
      return "var(--color-graph-1)";
    case 2:
      return "var(--color-graph-2)";
    case 3:
      return "var(--color-graph-3)";
    case 4:
      return "var(--color-graph-4)";
    default:
      // an out-of-ramp color id still renders distinctly rather than as an uncolored vertex
      return "var(--color-ink)";
  }
}

// The label color that keeps the numeral >= 4.5:1 on its fill (the AA mandate, VIZ-08). The ramp
// spans light fills (1,2) and dark fills (3,4), so a single label color cannot meet AA on all of
// them: graph-1/2 take a near-black bg label, graph-3/4 take the ivory ink label. The label, not the
// fill hue, is what identifies the class, so it must stay legible on every fill.
function labelColor(value: number): string {
  switch (value) {
    case 3:
    case 4:
      return "var(--color-ink)";
    default:
      return "var(--color-bg)";
  }
}

// Parse the bundled definition into the fixed layout. Total: a malformed definition yields an empty
// layout (the canvas renders nothing rather than crashing), matching the server's ignore-malformed
// behavior. The definition is author-controlled and bundled, so this is a build-time guard.
function parseLayout(definition: string): GraphLayout {
  try {
    const raw = JSON.parse(definition) as {
      vertices?: Vertex[];
      edges?: [number, number][];
      k?: number;
    };
    return {
      vertices: Array.isArray(raw.vertices) ? raw.vertices : [],
      edges: Array.isArray(raw.edges) ? raw.edges : [],
      k: typeof raw.k === "number" ? raw.k : 0,
    };
  } catch {
    return { vertices: [], edges: [], k: 0 };
  }
}

export function GraphView({ definition, grid }: { definition: string; grid: Cell[] }) {
  // Positions are read ONCE from the definition and memoized: never recomputed on a color change
  // (VIZ-06). A color change re-renders fills and labels only; the geometry is invariant.
  const layout = useMemo(() => parseLayout(definition), [definition]);

  if (layout.vertices.length === 0) {
    return (
      <div className="flex h-[28rem] w-[28rem] items-center justify-center rounded-[var(--radius-md)] border border-[color:var(--color-border)] text-sm text-[color:var(--color-ink-mute)]">
        pick a puzzle and press start
      </div>
    );
  }

  // A vertex's assigned color comes from its cell's value (cell index == vertex id, the encoder's
  // var<->vertex map). null means uncolored.
  const colorOf = (id: number): number | null => grid[id]?.value ?? null;
  const statusOf = (id: number): Cell["status"] | null => grid[id]?.status ?? null;

  // The DISTINCT conflict-state code path (VIZ-08), separate from the fill-color path: an edge is
  // clashing when its two endpoints carry the same assigned color, or when either endpoint is flagged
  // conflict by the stream. The clashing edge and both its endpoints stroke in the conflict color.
  const isClashEdge = (u: number, v: number): boolean => {
    const cu = colorOf(u);
    const cv = colorOf(v);
    if (cu !== null && cv !== null && cu === cv) return true;
    return statusOf(u) === "conflict" || statusOf(v) === "conflict";
  };
  const clashingVertices = new Set<number>();
  for (const [u, v] of layout.edges) {
    if (isClashEdge(u, v)) {
      clashingVertices.add(u);
      clashingVertices.add(v);
    }
  }

  return (
    <svg
      viewBox={`0 0 ${VIEWBOX} ${VIEWBOX}`}
      className="h-[28rem] w-[28rem] rounded-[var(--radius-md)] border border-[color:var(--color-border)] bg-[color:var(--color-surface)]"
      role="img"
      aria-label="graph coloring"
    >
      {/* Edges first so they sit under the vertices. A clashing edge strokes in the conflict color
          (the conflict second signal); every other edge is a hairline border line. */}
      {layout.edges.map(([u, v], i) => {
        const a = layout.vertices[u];
        const b = layout.vertices[v];
        if (!a || !b) return null;
        const clash = isClashEdge(u, v);
        return (
          <line
            key={`e${i}`}
            x1={a.x}
            y1={a.y}
            x2={b.x}
            y2={b.y}
            stroke={clash ? "var(--color-state-conflict)" : "var(--color-border)"}
            strokeWidth={clash ? 2.5 : 1}
            style={{ transition: "stroke var(--duration-conflict-flash) var(--ease-standard)" }}
          />
        );
      })}

      {/* Vertices: fixed (x,y) from the layout, fill from the categorical ramp, a color-id label
          inside every colored vertex. An endpoint of a clash strokes in the conflict color. A solved
          vertex settles to a solved border without overriding the categorical fill + label. A
          freshly decided vertex carries an accent ring (the decided second signal, VIZ-08) so the
          just-assigned vertex reads as a decision, not only as a new fill hue. */}
      {layout.vertices.map((vert) => {
        const color = colorOf(vert.id);
        const status = statusOf(vert.id);
        const clash = clashingVertices.has(vert.id);
        const decided = !clash && status === "decided";
        const fill = color !== null ? categoricalFill(color) : "var(--color-surface-2)";
        const stroke = clash
          ? "var(--color-state-conflict)"
          : status === "solved"
            ? "var(--color-state-solved)"
            : decided
              ? "var(--color-accent)"
              : "var(--color-border)";
        const strokeWidth = clash || status === "solved" || decided ? 2.5 : 1;
        return (
          <g key={`v${vert.id}`}>
            {decided && (
              // the accent ring: the decided second signal (the matrix's "ring/border pulse"), a
              // distinct shape cue around the just-assigned vertex rather than a fill hue alone.
              <circle
                cx={vert.x}
                cy={vert.y}
                r={22}
                fill="none"
                stroke="var(--color-accent)"
                strokeWidth={1.5}
              />
            )}
            <circle
              cx={vert.x}
              cy={vert.y}
              r={18}
              fill={fill}
              stroke={stroke}
              strokeWidth={strokeWidth}
              style={{
                transition:
                  "fill var(--duration-color-set) var(--ease-standard), stroke var(--duration-conflict-flash) var(--ease-standard)",
              }}
            />
            {color !== null && (
              <text
                x={vert.x}
                y={vert.y}
                textAnchor="middle"
                dominantBaseline="central"
                className="tabular"
                style={{ fontSize: 14, fill: labelColor(color), fontWeight: 500 }}
              >
                {color}
              </text>
            )}
          </g>
        );
      })}
    </svg>
  );
}
