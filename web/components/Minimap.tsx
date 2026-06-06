"use client";

// The search-tree minimap (VIZ-05): a compact SVG panel that draws the bounded node set the
// minimap reducer produces. One dot per decision, laid out by depth (x) and visible order (y);
// colored by node state (current/path accent, dead end conflict-red, solution path green); a ring
// on the current node is the non-color second signal (VIZ-08). Older/deeper nodes collapse into a
// "+N nodes" count so a hard solve with thousands of nodes stays a glance, not a diagram.
//
// The one JS-driven animation in the app lives here: a freshly added node grows its radius from 0.
// It is gated behind usePrefersReducedMotion — under reduced motion the node appears at full size
// instantly (the state still updates; only the growth tween is skipped). Every other animation is
// CSS and already collapsed by the global reduced-motion block in globals.css.

import { useEffect, useRef, useState } from "react";
import { visibleNodes, type MinimapNode, type MinimapState } from "../lib/minimap";
import { usePrefersReducedMotion } from "../lib/useReducedMotion";

// layout constants (px in the SVG user space). Dots are 5px diameter (within the 4-6px UI-SPEC band).
const NODE_R = 2.5;
const RING_R = 4.5;
const COL = 14; // horizontal spacing per depth level
const ROW = 11; // vertical spacing per visible-node slot
const PAD = 8;
const GROW_MS = 160; // matches --duration-decision-pulse; the node-add growth tween length

interface Placed {
  node: MinimapNode;
  x: number;
  y: number;
}

// Lay the visible nodes out: x by depth, y by order within the visible set (stable, no overlap). A
// glance layout, not a faithful tree embedding — siblings stack vertically near their depth column.
function layout(nodes: MinimapNode[]): { placed: Placed[]; width: number; height: number } {
  const perDepthCount = new Map<number, number>();
  const placed: Placed[] = nodes.map((node) => {
    const slot = perDepthCount.get(node.depth) ?? 0;
    perDepthCount.set(node.depth, slot + 1);
    return { node, x: PAD + node.depth * COL + RING_R, y: PAD + slot * ROW + RING_R };
  });
  const maxDepth = nodes.reduce((m, n) => Math.max(m, n.depth), 0);
  const maxSlot = [...perDepthCount.values()].reduce((m, c) => Math.max(m, c), 1);
  return {
    placed,
    width: PAD * 2 + maxDepth * COL + RING_R * 2,
    height: PAD * 2 + (maxSlot - 1) * ROW + RING_R * 2,
  };
}

function colorFor(state: MinimapNode["state"]): string {
  switch (state) {
    case "current":
    case "path":
      return "var(--color-accent)";
    case "deadEnd":
      return "var(--color-state-conflict)";
    case "solved":
      return "var(--color-state-solved)";
    default:
      return "var(--color-ink-mute)";
  }
}

export function Minimap({ minimap }: { minimap: MinimapState }) {
  const reduced = usePrefersReducedMotion();
  const { nodes, collapsedCount } = visibleNodes(minimap);
  const { placed, width, height } = layout(nodes);

  // the JS node-add tween: track which node ids have already been drawn at full size. A node not yet
  // seen grows from 0; once it has appeared it stays full. Under reduced motion every node is full
  // immediately (the set of "grown" ids is irrelevant — `scale` returns 1).
  const grown = useRef<Set<number>>(new Set());
  // the eased growth progress (0..1) of the nodes currently animating, held in state so render is a
  // pure function of state — the clock is sampled only inside the rAF tick, never during render
  // (a render triggered by an unrelated cause must not resample the clock and show a half-grown dot).
  const [progress, setProgress] = useState(1);
  const rafRef = useRef<number | null>(null);
  const animatingRef = useRef<boolean>(false);

  const pendingIds = placed.filter((p) => !grown.current.has(p.node.id)).map((p) => p.node.id);

  useEffect(() => {
    if (reduced) {
      // no tween: mark everything grown so nodes render full size with no animation.
      for (const p of placed) grown.current.add(p.node.id);
      return;
    }
    if (pendingIds.length === 0 || animatingRef.current) return;
    animatingRef.current = true;
    const start = performance.now();
    setProgress(0);
    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / GROW_MS);
      // smoothstep, the --ease-standard feel without a CSS transition. Stored in state so `scale`
      // reads a value, not the clock.
      setProgress(t * t * (3 - 2 * t));
      if (t < 1) {
        rafRef.current = requestAnimationFrame(tick);
      } else {
        for (const id of pendingIds) grown.current.add(id);
        animatingRef.current = false;
      }
    };
    rafRef.current = requestAnimationFrame(tick);
    return () => {
      if (rafRef.current !== null) cancelAnimationFrame(rafRef.current);
      animatingRef.current = false;
    };
    // pendingIds is derived from `placed`; depend on its join so a new node restarts the tween.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reduced, pendingIds.join(",")]);

  // the growth factor for a node: 1 once grown or under reduced motion, else the eased progress the
  // rAF tick last stored in state. A pure read of props/state, deterministic across re-renders.
  const scale = (id: number): number => {
    if (reduced || grown.current.has(id)) return 1;
    return progress;
  };

  return (
    <div className="flex flex-col gap-2 rounded-[var(--radius-lg)] border border-[color:var(--color-border)] bg-[color:var(--color-surface-2)] p-3">
      <span className="text-[color:var(--color-ink-mute)] text-xs">search tree</span>
      {placed.length === 0 ? (
        <span className="text-[color:var(--color-ink-mute)] text-xs">no decisions yet</span>
      ) : (
        <svg
          width={width}
          height={height}
          viewBox={`0 0 ${width} ${height}`}
          className="max-w-full"
          role="img"
          aria-label={`search tree, ${minimap.total} nodes`}
        >
          {placed.map((p) => {
            const isCurrent = p.node.state === "current";
            const r = NODE_R * scale(p.node.id);
            return (
              <g key={p.node.id}>
                {isCurrent && (
                  // the ring on the current node: the non-color second signal (VIZ-08).
                  <circle
                    cx={p.x}
                    cy={p.y}
                    r={RING_R}
                    fill="none"
                    stroke="var(--color-accent)"
                    strokeWidth={1}
                  />
                )}
                <circle cx={p.x} cy={p.y} r={r} fill={colorFor(p.node.state)} />
              </g>
            );
          })}
        </svg>
      )}
      {collapsedCount > 0 && (
        <span className="tabular text-[color:var(--color-ink-mute)] text-xs">
          +{collapsedCount} nodes
        </span>
      )}
    </div>
  );
}
