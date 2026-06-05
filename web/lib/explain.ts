// The pure conflict-explanation reconstructor. Given the buffered event stream and a cursor index, it
// finds the conflict at (or most recently before) that cursor and reports ONLY facts the stream
// genuinely conveys. Kept free of React (like replay.ts / minimap.ts) so it is unit-testable and the
// panel is a thin consumer.
//
// HONESTY CONTRACT. lattice's premise is that the reasoning shown is genuine. The event protocol does
// NOT carry propagation antecedents — no event says which constraint or clause caused a value to be
// removed. So this module never fabricates a causal chain ("value 3 was removed BECAUSE cell 2 = 4").
// It states only what the buffered events literally contain:
//   - CP: the conflict cell; the values `propagate` events removed from that cell since the last
//     decision (listed plainly, with NO claimed cause); the decisions still active on the path and the
//     current level; the level the following `backtrack` returns to.
//   - SAT: the conflict variable; the actual 1UIP `learn` clause the engine derived (the engine's OWN
//     genuine explanation, rendered via formatClause); the non-chronological backjump level.
// When a fact is not present in the events, it is omitted, never guessed.

import type { SolverEvent } from "./protocol";

// A single active decision on the path that led to the conflict: the cell/value the search chose at a
// level. These are the literal `decision` events still in force (not popped by a backtrack) when the
// conflict fired — observed facts, not a derived cause of the conflict.
export interface PathDecision {
  cell: number;
  value: number;
  level: number;
}

// The reconstructed explanation of one conflict. Every field is derived only from the buffered events
// up to (and just past, for the resolving backtrack/learn) the conflict; absent data is left null/empty
// rather than invented. `engine` distinguishes the CP and SAT presentations the panel renders.
export interface ConflictExplanation {
  // The index in the event buffer of the conflict event this explanation describes.
  index: number;
  engine: "cp" | "sat";
  // The conflict cell (CP: the cell whose domain emptied; SAT: the variable of the falsified clause).
  cell: number;
  // CP only: the values `propagate` events removed from the conflict cell since the last decision, in
  // the order the events arrived. Each is a literal `removed` value from a `propagate {cell, removed}`
  // event targeting this cell. NOT a causal claim — only "these were eliminated". Empty for SAT, and
  // empty for a CP conflict with no such propagations in the current level's window.
  eliminated: number[];
  // The decisions still active on the search path when the conflict fired (a `decision` not yet undone
  // by a `backtrack`), shallowest level first. Observed assignments that were in force, not a proof.
  path: PathDecision[];
  // The deepest active decision level at the conflict (the level the conflict occurred at), or null if
  // no decision was active (a conflict at the root, by pure propagation).
  level: number | null;
  // The level the next `backtrack`/backjump returned to, if such an event follows the conflict before
  // the next decision/conflict. Null when no resolving backtrack is in the buffer yet (e.g. the conflict
  // is the live edge). CP calls this a backtrack; SAT a non-chronological backjump.
  backtrackTo: number | null;
  // SAT only: the 1UIP learned clause the engine derived from this conflict, as the signed 1-based
  // literal list the `learn` event carried (render via formatClause). Null for CP (no learn events) and
  // for a SAT conflict whose learn event is not in the buffer.
  learnedClause: number[] | null;
}

// The engine tag a single-engine stream omits. Treat an absent tag as the stream's sole engine, which
// the caller knows; default to "cp" so a CP single-engine stream (no tag) reads as CP.
function engineOf(ev: SolverEvent): "cp" | "sat" {
  return ev.engine === "sat" ? "sat" : "cp";
}

// Is the event at `i` a conflict? A thin guard so the scan and the caller agree on what is inspectable.
export function isConflictAt(events: SolverEvent[], i: number): boolean {
  return i >= 0 && i < events.length && events[i].t === "conflict";
}

// The index of the conflict at exactly `cursor-1` (the event the cursor just advanced past) if it is a
// conflict, else the most recent conflict strictly before the cursor, else -1. The cursor is the count
// of applied events, so the latest applied event is at `cursor-1`. This lets the panel explain "the
// conflict you are looking at" whether the viewer scrubbed onto a conflict or just past one. Totally
// bounds-safe: an out-of-range or zero cursor returns -1.
export function conflictIndexAtCursor(events: SolverEvent[], cursor: number): number {
  const start = Math.min(cursor, events.length) - 1;
  for (let i = start; i >= 0; i--) {
    if (events[i].t === "conflict") return i;
  }
  return -1;
}

// Reconstruct the explanation for the conflict at `index`. Returns null if `index` is out of range or
// not a conflict event, so the caller never renders a fabricated panel. Total and side-effect free: it
// only reads the buffer.
export function explainConflict(
  events: SolverEvent[],
  index: number,
): ConflictExplanation | null {
  if (!isConflictAt(events, index)) return null;
  const conflict = events[index];
  // The conflict event is narrowed to ConflictEvent by isConflictAt; read its cell and engine.
  if (conflict.t !== "conflict") return null; // unreachable, but keeps the union narrowing honest
  const engine = engineOf(conflict);
  const cell = conflict.cell;

  // Walk the events BEFORE the conflict to recover the decision stack in force at the conflict. A
  // `decision {level}` records (or overwrites) the active decision at that level and drops anything
  // deeper that a missing backtrack left stale (a re-decision at a shallower level supersedes the old
  // frontier); a `backtrack {level}` pops every decision deeper than `level`. The result is the set of
  // decisions still active when the conflict fired — observed assignments, not a derived cause.
  const active = new Map<number, PathDecision>();
  // The index of the last decision event before the conflict, so the eliminated-values scan is bounded
  // to "since the last decision" (the propagations that happened under the current frontier).
  let lastDecisionIndex = -1;
  for (let i = 0; i < index; i++) {
    const ev = events[i];
    // In a single-engine buffer every event shares the one engine; this scan is over that one stream,
    // so no per-engine routing is needed (the buffer is never populated in race mode).
    if (ev.t === "decision") {
      // Drop any active decision at this level or deeper (a re-decision supersedes the old branch).
      for (const lvl of [...active.keys()]) if (lvl >= ev.level) active.delete(lvl);
      active.set(ev.level, { cell: ev.cell, value: ev.value, level: ev.level });
      lastDecisionIndex = i;
    } else if (ev.t === "backtrack") {
      for (const lvl of [...active.keys()]) if (lvl > ev.level) active.delete(lvl);
    } else if (ev.t === "restart") {
      // A SAT restart unwinds the whole trail to level 0; no decision survives it.
      active.clear();
      lastDecisionIndex = -1;
    }
  }
  const path = [...active.values()].sort((a, b) => a.level - b.level);
  const level = path.length > 0 ? path[path.length - 1].level : null;

  // The values eliminated from the conflict cell since the last decision (CP only). Each is a literal
  // `removed` from a `propagate {cell, removed}` event targeting this cell, in arrival order. These are
  // the eliminations the stream reports happened under the current frontier — stated plainly, with NO
  // claim about which constraint caused each one (the protocol does not carry that, so neither do we).
  const eliminated: number[] = [];
  if (engine === "cp") {
    for (let i = lastDecisionIndex + 1; i < index; i++) {
      const ev = events[i];
      if (ev.t === "propagate" && ev.cell === cell && engineOf(ev) === "cp") {
        eliminated.push(ev.removed);
      }
    }
  }

  // Scan FORWARD from just after the conflict for the resolving events: the backtrack/backjump the
  // search performed, and (SAT) the 1UIP clause it learned. Stop at the next decision or conflict, so a
  // later, unrelated conflict's backtrack is never attributed to this one. Either may be absent if the
  // conflict is at the live edge (the buffer has not received them yet); then the field stays null.
  let backtrackTo: number | null = null;
  let learnedClause: number[] | null = null;
  for (let i = index + 1; i < events.length; i++) {
    const ev = events[i];
    if (ev.t === "decision" || ev.t === "conflict") break;
    if (ev.t === "learn" && learnedClause === null) learnedClause = ev.clause;
    if (ev.t === "backtrack" && backtrackTo === null) {
      backtrackTo = ev.level;
      break; // the backtrack closes this conflict's resolution; later events belong to the next step
    }
  }

  return {
    index,
    engine,
    cell,
    eliminated,
    path,
    level,
    backtrackTo,
    learnedClause: engine === "sat" ? learnedClause : null,
  };
}
