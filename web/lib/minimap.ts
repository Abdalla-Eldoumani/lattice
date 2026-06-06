// The pure search-tree reducer (VIZ-05). It turns the engine's decision/backtrack/solution stream
// into a compact tree the minimap draws: one node per decision at its level, the current search path
// marked, the abandoned subtree dimmed on backtrack, the path marked solved on solution. Kept free of
// React (like replay.ts) so it is unit-testable and the SVG panel is a thin consumer. The reducer is
// total and side-effect free; the same level-keyed bookkeeping idea replay.ts uses for the snapshot
// stack drives the path pop here.

import type { SolverEvent } from "./protocol";

// A node's lifecycle state, which the panel maps to a color + the current-node ring (VIZ-08). `open`
// is a node that was on the path but is neither current nor yet resolved as a dead end or solved.
export type MinimapNodeState = "current" | "path" | "deadEnd" | "solved" | "open";

export interface MinimapNode {
  id: number;
  // depth === the decision level the node was created at; a level-L decision sits at depth L. The
  // synthetic root is depth -1 so a level-0 decision is its child.
  depth: number;
  state: MinimapNodeState;
  // children ids in creation order (siblings share a parent at depth-1).
  children: number[];
}

export interface MinimapState {
  // a flat id -> node map (mirrors replay.ts's flat grid: cheap to update, no deep tree walks).
  nodes: Map<number, MinimapNode>;
  // the synthetic root id (depth -1); every level-0 decision is a child of it.
  rootId: number;
  // the current search path as a stack of node ids, root first. Its length - 1 is the deepest level.
  path: number[];
  // every node ever created (the headline figure; the cap collapses the older ones into a count).
  total: number;
  // how many created nodes are hidden by the cap (the panel renders "+N nodes" when this is > 0).
  collapsedCount: number;
  // monotonic id source so a node id is stable for the life of a solve.
  nextId: number;
}

// The render window: the current path plus this many most-recent nodes stay visible; the rest collapse
// into collapsedCount. A tunable constant per RESEARCH Open Question 3 (the "current path + last ~20-30
// nodes" policy) — small enough that a hard solve with thousands of nodes renders a bounded SVG, large
// enough that recent siblings around the current frontier stay legible. Bump it if the panel grows.
export const RECENT_WINDOW = 24;

export function initialMinimap(): MinimapState {
  const root: MinimapNode = { id: 0, depth: -1, state: "open", children: [] };
  return {
    nodes: new Map([[0, root]]),
    rootId: 0,
    path: [0],
    total: 0,
    collapsedCount: 0,
    nextId: 1,
  };
}

// Apply one event, returning the next state. Only decision/backtrack/solution shape the tree; the
// other events (propagate/conflict/stats/unsat) leave it unchanged — the minimap is a search-tree
// view, not a propagation view.
export function applyMinimapEvent(state: MinimapState, ev: SolverEvent): MinimapState {
  switch (ev.t) {
    case "decision":
      return applyDecision(state, ev.level);
    case "backtrack":
      return applyBacktrack(state, ev.level);
    case "solution":
      return applySolution(state);
    default:
      return state;
  }
}

// A level-L decision creates a child of the path node at depth L-1 (the synthetic root for L=0). The
// new node becomes `current`; the rest of the path that survives below it (the ancestors) is marked
// `path`. The path stack is truncated to the parent, then the new node is pushed, so a decision at a
// level shallower than the current frontier (the search jumped back up before a clean backtrack event)
// still attaches as a sibling at the right depth rather than dangling.
function applyDecision(state: MinimapState, level: number): MinimapState {
  const nodes = cloneNodes(state.nodes);
  // the parent is the node currently on the path at depth level-1; path[0] is the root (depth -1),
  // so depth d sits at path index d+1. A malformed level past the frontier clamps to the deepest.
  const parentIndex = Math.min(level, state.path.length - 1);
  const parentId = state.path[parentIndex];
  const id = state.nextId;
  const child: MinimapNode = { id, depth: level, state: "current", children: [] };
  nodes.set(id, child);
  const parent = nodes.get(parentId);
  if (parent) parent.children = [...parent.children, id];

  // the new path is the ancestors up to and including the parent, then the new current node.
  const path = [...state.path.slice(0, parentIndex + 1), id];
  // a decision at or above the current tip (no intervening backtrack event) slices the old deeper
  // nodes out of the path. Demote those abandoned siblings to deadEnd the same way applyBacktrack
  // does, so no node sliced off the path keeps a stale `current`/`path` state and reads as a second
  // frontier in the panel.
  for (const nid of state.path.slice(parentIndex + 1)) {
    const n = nodes.get(nid);
    if (n && n.depth >= 0 && n.state !== "solved") n.state = "deadEnd";
  }
  // mark the surviving ancestors `path` (not current), leaving any resolved state on off-path nodes.
  for (const nid of path.slice(0, -1)) {
    const n = nodes.get(nid);
    if (n && n.depth >= 0 && n.state !== "solved" && n.state !== "deadEnd") n.state = "path";
  }
  return {
    ...state,
    nodes,
    path,
    total: state.total + 1,
    nextId: state.nextId + 1,
    collapsedCount: collapsedFor(state.total + 1, path.length),
  };
}

// A backtrack to level L keeps the node at depth L and pops everything deeper, marking the popped
// nodes dead ends (the abandoned subtree the panel dims/colors conflict-red). The next decision at
// level L+1 then attaches as a sibling of the popped node. The node now at the top of the path becomes
// `current` again so the ring follows the frontier. Depth d sits at path index d+1, so keeping through
// depth L means a slice length of L+2 (the synthetic root + depths 0..L).
function applyBacktrack(state: MinimapState, level: number): MinimapState {
  const nodes = cloneNodes(state.nodes);
  const keep = Math.max(1, Math.min(level + 2, state.path.length));
  const popped = state.path.slice(keep);
  for (const nid of popped) {
    const n = nodes.get(nid);
    if (n && n.state !== "solved") n.state = "deadEnd";
  }
  const path = state.path.slice(0, keep);
  const tipId = path[path.length - 1];
  const tip = nodes.get(tipId);
  // the tip is current again unless it is the synthetic root (nothing decided) or already resolved.
  if (tip && tip.depth >= 0 && tip.state !== "solved" && tip.state !== "deadEnd") {
    tip.state = "current";
  }
  return {
    ...state,
    nodes,
    path,
    collapsedCount: collapsedFor(state.total, path.length),
  };
}

// A solution marks every real node on the current path `solved` (the green path to the answer).
function applySolution(state: MinimapState): MinimapState {
  const nodes = cloneNodes(state.nodes);
  for (const nid of state.path) {
    const n = nodes.get(nid);
    if (n && n.depth >= 0) n.state = "solved";
  }
  return { ...state, nodes };
}

// The cap: the current path always renders; beyond it, the most-recent RECENT_WINDOW nodes render and
// the rest collapse into a count. `total` is the real node count; `pathLen` includes the synthetic
// root, so the real on-path nodes are pathLen-1. Nodes hidden = total - (visible recent + on-path not
// already counted in the window). We approximate conservatively: anything past the path + window.
function collapsedFor(total: number, pathLen: number): number {
  const onPath = Math.max(0, pathLen - 1);
  const visible = onPath + RECENT_WINDOW;
  return Math.max(0, total - visible);
}

// The render set: the current path (root excluded — it is synthetic) plus the most-recently-created
// nodes up to RECENT_WINDOW, de-duplicated, with the collapsedCount for everything older. The panel
// draws exactly these, so a tree of thousands of nodes is a bounded SVG. Returned in creation order.
export function visibleNodes(state: MinimapState): {
  nodes: MinimapNode[];
  collapsedCount: number;
} {
  const ids = new Set<number>();
  // the current path (skip the synthetic root).
  for (const nid of state.path) {
    const n = state.nodes.get(nid);
    if (n && n.depth >= 0) ids.add(nid);
  }
  // the most-recent nodes by id (ids are monotonic, so the highest ids are the newest).
  const recent = [...state.nodes.values()]
    .filter((n) => n.depth >= 0)
    .sort((a, b) => b.id - a.id)
    .slice(0, RECENT_WINDOW);
  for (const n of recent) ids.add(n.id);

  const nodes = [...ids]
    .map((id) => state.nodes.get(id)!)
    .filter(Boolean)
    .sort((a, b) => a.id - b.id);
  const collapsedCount = Math.max(0, state.total - nodes.length);
  return { nodes, collapsedCount };
}

// A shallow clone of the node map plus a fresh node object for each entry, so a reducer step never
// mutates the prior state's nodes (the snapshot-restore discipline replay.ts follows). Cheap: the
// node count is small (bounded interest is the visible window; the map is at most `total` entries,
// and a long solve is dominated by deadEnd leaves we rarely revisit).
function cloneNodes(src: Map<number, MinimapNode>): Map<number, MinimapNode> {
  const out = new Map<number, MinimapNode>();
  for (const [id, n] of src) out.set(id, { ...n, children: [...n.children] });
  return out;
}
