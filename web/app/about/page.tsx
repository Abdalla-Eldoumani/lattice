// The "how it works" explainer (VIZ extras). A static, server-rendered route that describes, in plain
// language, what lattice actually is and how to read the visualizer. The prose is grounded in the real
// engine (src/Lattice/CP and src/Lattice/SAT) and the real renderers (web/components) — it states only
// what the code does, never an invented or overstated mechanism, because the project's whole premise is
// that the reasoning shown is genuine. No interactivity, so it stays a server component; the styling is
// the same locked tokens the rest of the app uses (editorial-dark, one ochre accent, Fraunces display,
// depth from 1px borders and spacing, no drop shadow).

import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "how lattice works",
  description:
    "What lattice is, how its constraint and SAT engines reason, and how to read the visualizer.",
};

const FOCUS_RING =
  "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[color:var(--color-border-strong)]";

export default function About() {
  return (
    <main className="mx-auto flex min-h-screen max-w-2xl flex-col gap-12 px-6 py-12">
      <header className="flex flex-col gap-6 border-b border-[color:var(--color-border)] pb-8">
        <Link
          href="/"
          aria-label="back to the visualizer"
          className={`w-fit rounded-[var(--radius-sm)] text-sm text-[color:var(--color-accent)] transition-colors hover:text-[color:var(--color-accent-dim)] ${FOCUS_RING}`}
        >
          &larr; back to the visualizer
        </Link>
        <div className="flex flex-col gap-4">
          <p className="text-xs uppercase tracking-[0.18em] text-[color:var(--color-ink-mute)]">
            how it works
          </p>
          <h1 className="font-[family-name:var(--font-display)] text-4xl font-normal leading-[1.05] tracking-tight">
            Watching a solver actually think
          </h1>
          <p className="text-lg leading-relaxed text-[color:var(--color-ink-dim)]">
            lattice is a constraint solver and a SAT solver, written from scratch, that streams its real
            reasoning to this page. The board you watch is not a recorded animation. Every value ruled
            out, every guess, every dead end, and every backtrack is the engine doing the work, sent to
            the browser one step at a time.
          </p>
        </div>
      </header>

      <Section title="The honest version first">
        <P>
          It would be easy to fake this. A scripted animation of a Sudoku &ldquo;solving itself&rdquo;
          would look much the same. lattice does not do that. The page connects to a running solver, and
          what you see is the event stream that solver emits as it searches.
        </P>
        <P>
          The reason to trust that is the test suite. The constraint engine, the SAT engine, and a plain
          brute-force reference solver are all run on the same small instances and required to agree: the
          same answer where one exists, and the same verdict of &ldquo;no solution&rdquo; where none does.
          A solver that cut a corner would disagree with the brute-force oracle and the tests would fail.
          Correctness is checked against an exhaustive reference, not by watching an easy puzzle look right.
        </P>
      </Section>

      <Section title="The constraint engine">
        <P>
          A puzzle becomes a set of <Term>variables</Term>, each with a <Term>domain</Term> &mdash; the
          values it is still allowed to take. An empty Sudoku cell is a variable whose domain starts as
          all of 1 through 9. The rules of the puzzle become <Term>constraints</Term>: the nine cells in a
          row must all differ, two adjacent regions must not share a colour, and so on.
        </P>
        <P>
          <Term>Propagation</Term> is the engine ruling values out. When a cell is pinned to a single
          value, that value is removed from every other cell that shares a constraint with it. Removing a
          value can pin another cell, which removes more values, and so on. The engine keeps a worklist of
          constraints to re-check and drains it until nothing more can be removed &mdash; a{" "}
          <Term>fixpoint</Term>. On the board this is the candidate numerals fading out of cells. Each
          removal is justified by a constraint, so a value that belongs to a real solution is never
          removed; that property is itself tested against the brute-force solver.
        </P>
        <P>
          When propagation stalls and the puzzle is not yet solved, the engine makes a guess: it picks a
          variable and commits to one of its remaining values &mdash; a <Term>decision</Term>. Then it
          propagates again. If a domain ever empties, no value can satisfy that cell: a{" "}
          <Term>conflict</Term>. The engine undoes its most recent guess and tries the next value. This
          undo-and-retry is <Term>backtracking search</Term>. Because the constraint domains are stored in
          a way that remembers each earlier state, undoing a guess is just restoring the previous state.
        </P>
        <P>
          The order of guesses does not change which answers are valid, but it changes how much searching
          it takes to find one. lattice picks the variable with the <Term>fewest remaining values</Term>{" "}
          first &mdash; the most-constrained cell, where a wrong guess is caught soonest &mdash; breaking
          ties by <Term>degree</Term>, the cell tangled in the most constraints. For the value, it tries
          the <Term>least-constraining</Term> one first: the value that rules out the fewest options for
          neighbouring cells, leaving the most room to succeed. These are standard orderings, and they are
          why the hard presets still finish in a watchable number of steps.
        </P>
      </Section>

      <Section title="The SAT engine">
        <P>
          The second engine works in pure boolean logic. A problem is given as <Term>clauses</Term> &mdash;
          each clause an &ldquo;or&rdquo; of variables that may be true or false &mdash; and the engine
          looks for an assignment that makes every clause true. This is the CDCL method (conflict-driven
          clause learning), the design behind modern SAT solvers, built here from scratch.
        </P>
        <P>
          Assignments are recorded on a <Term>trail</Term>, a running list of what has been set true or
          false and why. The engine finds forced moves with <Term>unit propagation</Term>: if every
          literal in a clause is false except one unassigned literal, that last one must be true. To do
          this without re-scanning every clause on every step, each clause <Term>watches</Term> just two of
          its literals and is only re-examined when one of those two is falsified &mdash; the watched-literal
          scheme, which is what keeps propagation fast.
        </P>
        <P>
          When a clause is falsified, that is a conflict, and this is where CDCL earns its name. The engine
          traces the conflict back through the trail to the choices that forced it, and from that derives a
          brand-new clause &mdash; a <Term>learned clause</Term> &mdash; that records the dead end so it is
          never repeated. (The analysis stops at the &ldquo;first unique implication point&rdquo;, which is
          the precise rule that decides which clause to learn.) It
          then jumps straight back to the decision level that learned clause points to, rather than undoing
          one level at a time &mdash; <Term>non-chronological backjumping</Term> &mdash; and carries on.
          The learned clause shown in the panel is the engine&rsquo;s own deduction; that is the one
          genuinely causal thing the visualizer states.
        </P>
        <P>
          To decide which variable to branch on next, the engine keeps an <Term>activity</Term> score per
          variable and prefers the ones involved in recent conflicts &mdash; the VSIDS heuristic. When it
          sets a variable, it reuses the polarity that variable last held (<Term>phase saving</Term>), which
          tends to stay near a workable assignment. Periodically it throws away the current guesses and
          starts the search over while keeping everything it has learned, on the <Term>Luby</Term> schedule
          &mdash; a fixed sequence of restart intervals. Restarts let it escape a bad early guess without
          losing the learned clauses.
        </P>
      </Section>

      <Section title="Reading the visualizer">
        <P>
          Every state on the board has a colour and a second, non-colour cue, so the solve is legible
          without relying on colour and stays readable if you turn animation off.
        </P>
        <Legend>
          <LegendRow
            term="candidate"
            cue="dim numerals in a cell"
            desc="values a cell may still take; they fade out as propagation rules them out"
          />
          <LegendRow
            term="decided"
            cue="accent colour, a brief pulse"
            desc="the value the engine just committed to as a guess"
          />
          <LegendRow
            term="propagated"
            cue="a plain border in the SAT trail, no ring"
            desc="a value forced by the rules rather than chosen; the missing ring is the cue that it was forced"
          />
          <LegendRow
            term="conflict"
            cue="red, a brief flash, a struck-through id"
            desc="a dead end: a cell with no values left, or a clause that cannot be satisfied"
          />
          <LegendRow
            term="solved"
            cue="green border"
            desc="a cell or clause that is settled and correct"
          />
        </Legend>
        <P>
          The <Term>thinking panel</Term> names the current decision and the last step in words, and counts
          decisions, propagations, backtracks, and conflicts as they tick by. On a SAT run it also counts
          learned clauses and restarts. When the view is sitting on a conflict, an explain button opens an
          account of that dead end &mdash; and it is careful to state only what the event stream actually
          carries, never a guessed cause.
        </P>
        <P>
          The <Term>search-tree minimap</Term> adds a dot for each decision. The current path is drawn in
          the accent colour with a ring on the current node; dead ends and the solution path are marked.
          A long search collapses its older nodes into a count so the tree stays a glance.
        </P>
        <P>
          For a SAT instance there is no grid, so the board becomes a <Term>trail view</Term>: one square
          per variable, showing a <Mono>T</Mono> or <Mono>F</Mono> glyph for its value, grouped into bands
          by decision level (each band labelled <Mono>L0</Mono>, <Mono>L1</Mono>, and so on). A chosen
          variable takes an accent ring; a forced one has only a plain border. The most recent learned
          clause appears as a chip below the trail.
        </P>
        <P>
          The <Term>controls</Term> let you pick a puzzle and an engine, then drive the solve: step through
          it one event at a time, play it at a speed the slider sets, pause, or restart. The engine picker
          offers cp, sat, and &mdash; where one instance can be expressed both ways &mdash; a{" "}
          <Term>cp vs sat race</Term> that runs both engines on the same problem side by side, so you can
          watch two genuinely different methods reach the same answer. The <Term>scrubber</Term> below the
          board lets you rewind and replay through the steps already received; it replays the recorded
          events and does not re-run the engine.
        </P>
      </Section>

      <Section title="Why this is genuine">
        <P>
          The single guard behind all of it is the three-way differential test. On small instances the
          constraint engine, the SAT engine, and an exhaustive brute-force solver must all agree &mdash;
          on the answer and on whether one exists at all. They are independent implementations of the same
          question, so an agreement between all three is strong evidence each is correct, and a wrong move
          in any of them would surface as a disagreement and fail the build. What you watch is the same
          engine that test exercises, running on your puzzle.
        </P>
      </Section>

      <footer className="border-t border-[color:var(--color-border)] pt-8">
        <Link
          href="/"
          aria-label="back to the visualizer"
          className={`rounded-[var(--radius-sm)] text-sm text-[color:var(--color-accent)] transition-colors hover:text-[color:var(--color-accent-dim)] ${FOCUS_RING}`}
        >
          &larr; back to the visualizer
        </Link>
      </footer>
    </main>
  );
}

// A titled section: a Fraunces heading over a column of editorial prose, with generous spacing between
// sections for the printed feel. The heading sits on a hairline rule.
function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="flex flex-col gap-4">
      <h2 className="font-[family-name:var(--font-display)] text-2xl font-normal tracking-tight">
        {title}
      </h2>
      <div className="flex flex-col gap-4">{children}</div>
    </section>
  );
}

// A body paragraph at the editorial measure.
function P({ children }: { children: React.ReactNode }) {
  return <p className="leading-relaxed text-[color:var(--color-ink-dim)]">{children}</p>;
}

// A first-use term: ink-coloured and a touch heavier so the vocabulary stands out from the prose
// without a second accent colour.
function Term({ children }: { children: React.ReactNode }) {
  return <span className="font-medium text-[color:var(--color-ink)]">{children}</span>;
}

// An inline mono token (a glyph or a level label), so code-like text reads as code.
function Mono({ children }: { children: React.ReactNode }) {
  return <span className="tabular text-[color:var(--color-ink)]">{children}</span>;
}

// The legend: a definition-style table of the cell states, each with its colour-independent cue, framed
// by a hairline border. Depth from the border, not a shadow.
function Legend({ children }: { children: React.ReactNode }) {
  return (
    <dl className="flex flex-col divide-y divide-[color:var(--color-border)] rounded-[var(--radius-md)] border border-[color:var(--color-border)]">
      {children}
    </dl>
  );
}

function LegendRow({ term, cue, desc }: { term: string; cue: string; desc: string }) {
  return (
    <div className="flex flex-col gap-1 p-4 sm:flex-row sm:items-baseline sm:gap-4">
      <dt className="flex w-40 shrink-0 flex-col gap-0.5">
        <span className="tabular text-sm text-[color:var(--color-ink)]">{term}</span>
        <span className="text-xs text-[color:var(--color-ink-mute)]">{cue}</span>
      </dt>
      <dd className="text-sm leading-relaxed text-[color:var(--color-ink-dim)]">{desc}</dd>
    </div>
  );
}
