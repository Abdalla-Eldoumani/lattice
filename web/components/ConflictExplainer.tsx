"use client";

// The conflict explainer panel: a faithful, honest re-presentation of one conflict, built from the
// buffered events by the pure reconstructor in lib/explain.ts. It states ONLY what the event stream
// genuinely conveys (see the honesty contract there) — never a fabricated "value X removed BECAUSE Y"
// causal chain, which the protocol does not carry. CP shows the conflict cell, the values eliminated
// from it, the active decisions / level, and the backtrack that followed. SAT additionally shows the
// engine's own 1UIP learned clause (its genuine deduction) via formatClause.
//
// The conflict is named in text (legible without color); the conflict-red is a secondary cue on the
// heading, never the only signal (VIZ-08). The panel is an aria-live region so a screen reader hears
// the explanation when it opens or changes. Styled with locked tokens only (no new @theme token, no
// drop shadow); the global reduced-motion block already collapses any transition.

import { type ConflictExplanation } from "../lib/explain";
import { formatClause } from "../lib/replay";

const FOCUS_RING =
  "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[color:var(--color-border-strong)]";

export function ConflictExplainer({
  explanation,
  onClose,
}: {
  explanation: ConflictExplanation;
  onClose: () => void;
}) {
  const { engine, cell, eliminated, path, level, backtrackTo, learnedClause } = explanation;
  // The conflict noun the heading and prose use, so the panel reads in the engine's own vocabulary: a
  // CP conflict is an emptied cell domain; a SAT conflict is a falsified clause at a variable.
  const subject = engine === "sat" ? `variable ${cell}` : `cell ${cell}`;
  return (
    <section
      aria-live="polite"
      aria-label="conflict explanation"
      className="flex flex-col gap-3 rounded-[var(--radius-md)] border border-[color:var(--color-state-conflict)] bg-[color:var(--color-surface-2)] p-4"
    >
      <div className="flex items-baseline justify-between gap-2">
        {/* The heading names the conflict in words first; the conflict-red border + the ⊥ glyph are the
            secondary, non-color-only cues (VIZ-08). */}
        <h3 className="flex items-baseline gap-2 text-sm text-[color:var(--color-state-conflict)]">
          <span aria-hidden="true">⊥</span>
          <span>conflict at {subject}</span>
        </h3>
        <button
          type="button"
          onClick={onClose}
          aria-label="close conflict explanation"
          className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface)] px-2 py-0.5 text-xs text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] ${FOCUS_RING}`}
        >
          close
        </button>
      </div>

      {/* The observed facts, as plain statements. The lead line frames it honestly: this is what the
          events show happened, not a proof of why. */}
      <div className="flex flex-col gap-2.5 text-sm text-[color:var(--color-ink-dim)]">
        <p className="text-[color:var(--color-ink-mute)]">
          what the event stream shows, with no assumed cause:
        </p>

        {engine === "cp" ? (
          <CpFacts cell={cell} eliminated={eliminated} path={path} level={level} backtrackTo={backtrackTo} />
        ) : (
          <SatFacts
            cell={cell}
            path={path}
            level={level}
            backtrackTo={backtrackTo}
            learnedClause={learnedClause}
          />
        )}
      </div>
    </section>
  );
}

// The CP presentation: the emptied cell, the values eliminated from it (listed plainly, no cause), the
// active decisions on the path and the level, and the backtrack that followed. Every clause is gated on
// its data being present, so an absent fact is silently omitted rather than rendered as a hole.
function CpFacts({
  cell,
  eliminated,
  path,
  level,
  backtrackTo,
}: {
  cell: number;
  eliminated: number[];
  path: ConflictExplanation["path"];
  level: number | null;
  backtrackTo: number | null;
}) {
  return (
    <ul className="flex flex-col gap-2">
      <Fact>
        cell {cell}&rsquo;s domain emptied &mdash; no value can satisfy its constraints.
      </Fact>
      {eliminated.length > 0 && (
        <Fact>
          values{" "}
          <span className="tabular text-[color:var(--color-ink)]">{eliminated.join(", ")}</span>{" "}
          had been eliminated from cell {cell} since the last decision.
        </Fact>
      )}
      <DecisionFacts path={path} level={level} />
      <BacktrackFact backtrackTo={backtrackTo} verb="the search backtracks" />
    </ul>
  );
}

// The SAT presentation: the conflict variable, the active decisions / level, the engine's OWN 1UIP
// learned clause (its genuine deduction, rendered via formatClause with an honest note on what it is),
// and the non-chronological backjump level. The learned clause is the honest centerpiece — it is the
// only causal statement we make, because the engine itself derived and emitted it.
function SatFacts({
  cell,
  path,
  level,
  backtrackTo,
  learnedClause,
}: {
  cell: number;
  path: ConflictExplanation["path"];
  level: number | null;
  backtrackTo: number | null;
  learnedClause: number[] | null;
}) {
  return (
    <ul className="flex flex-col gap-2">
      <Fact>
        a clause at variable {cell} was falsified by the current assignment.
      </Fact>
      <DecisionFacts path={path} level={level} />
      {learnedClause !== null && (
        <Fact>
          the engine&rsquo;s 1UIP analysis learned the clause{" "}
          <span className="tabular text-[color:var(--color-accent)]">
            ({formatClause(learnedClause)})
          </span>
          . this is the engine&rsquo;s own deduction; adding it prevents repeating this conflict.
        </Fact>
      )}
      <BacktrackFact backtrackTo={backtrackTo} verb="the search backjumps" />
    </ul>
  );
}

// The decision/level facts, shared by both engines: the active decisions on the path (observed
// assignments in force, not a cause) and the level the conflict occurred at. Omitted entirely when no
// decision was active (a conflict at the root by pure propagation), since there is nothing to state.
function DecisionFacts({
  path,
  level,
}: {
  path: ConflictExplanation["path"];
  level: number | null;
}) {
  if (path.length === 0) {
    return (
      <Fact>
        no decision was active &mdash; the conflict arose by propagation at the root.
      </Fact>
    );
  }
  return (
    <>
      <Fact>
        this happened at level{" "}
        <span className="tabular text-[color:var(--color-ink)]">{level}</span> on a path of decisions:
      </Fact>
      <li className="ml-4 flex flex-col gap-0.5">
        {path.map((d) => (
          <span key={d.level} className="tabular text-xs text-[color:var(--color-ink-dim)]">
            level {d.level}: cell {d.cell} = {d.value}
          </span>
        ))}
      </li>
    </>
  );
}

// The resolving backtrack/backjump fact, present only when the buffer already holds the backtrack that
// followed the conflict (it may not yet, if the conflict is the live edge). `verb` reads "backtracks"
// for CP and "backjumps" for SAT.
function BacktrackFact({ backtrackTo, verb }: { backtrackTo: number | null; verb: string }) {
  if (backtrackTo === null) return null;
  return (
    <Fact>
      to recover, {verb} to level{" "}
      <span className="tabular text-[color:var(--color-ink)]">{backtrackTo}</span>.
    </Fact>
  );
}

// One bullet fact. The marker is a 1px-border square (the editorial idiom, no glyph color carrying
// meaning), so the list reads as discrete observed statements.
function Fact({ children }: { children: React.ReactNode }) {
  return (
    <li className="flex gap-2">
      <span
        aria-hidden="true"
        className="mt-1.5 h-1 w-1 shrink-0 border border-[color:var(--color-ink-mute)]"
      />
      <span>{children}</span>
    </li>
  );
}
