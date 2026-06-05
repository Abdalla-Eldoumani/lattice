"use client";

// The guided tour (VIZ extras). An on-demand, accessible stepper that walks a first-time viewer
// through the key regions of the main page with short, honest captions. It is launched from a "tour"
// button in the header and is self-contained: it owns no solver state and never drives the engine, so
// it cannot regress the solve, the scrubber, the race, or the help overlay.
//
// Accessibility: a role="dialog" + aria-modal panel with a labelled step heading, next/prev/close
// controls, ESC to exit, and a focus trap. Focus moves into the panel on open and returns to the
// trigger on close (the HelpOverlay contract). While it is open the page's window key handler is
// suppressed by the same `tourOpen` gate `helpOpen` uses, so the dialog owns the keyboard.
//
// It highlights the region each step names with an accent OUTLINE drawn around the live element (a
// 1px-token ring, never a drop shadow), found by a data-tour-id attribute on the page. The outline is
// the only visual cue; the STEP TEXT carries the meaning, so the tour stays fully legible under
// prefers-reduced-motion and for anyone the outline does not reach (no essential motion, no color-only
// signal). If a step's region is not on the page in the current layout (the race hides the scrubber,
// for instance), the outline is simply skipped and the caption still reads.

import { useCallback, useEffect, useRef, useState } from "react";

const FOCUS_RING =
  "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[color:var(--color-border-strong)]";

// The tour steps, in reading order down the page. `target` matches a `data-tour-id` on the live region
// the step describes; an absent target (no match in the current layout) just skips the outline. Each
// caption states only what the region honestly does — no invented mechanism, no marketing.
interface Step {
  target: string | null;
  title: string;
  body: string;
}

const STEPS: Step[] = [
  {
    target: null,
    title: "watch a solver think",
    body: "lattice runs a real constraint solver and streams its actual steps to this page. Nothing here is a scripted animation — every move you see is the engine working. This short tour points out where each part of the reasoning shows up.",
  },
  {
    target: "controls",
    title: "pick a puzzle and an engine",
    body: "Choose a puzzle and the engine that solves it: cp is the constraint-propagation solver, sat is the CDCL SAT solver, and cp vs sat runs both on the same instance side by side. Press start to begin. The hard presets are chosen to make the search visibly backtrack rather than solve at once.",
  },
  {
    target: "puzzle",
    title: "the board",
    body: "The board is where the work lands. As constraints rule values out, candidate numerals fade from each cell; when the engine commits to a value, that cell pulses in the accent colour; a dead end flashes red; settled cells finish in green. A SAT instance shows its assignment trail instead of a grid.",
  },
  {
    target: "controls",
    title: "drive the solve",
    body: "step advances one event at a time; play runs at the speed the slider sets; pause and restart do what they say. Working through it one step at a time is the honest way to follow the reasoning.",
  },
  {
    target: "scrubber",
    title: "rewind the reasoning",
    body: "The timeline lets you move backward and forward through the steps already received and rebuild the whole view at any earlier point. It replays the recorded events; it does not re-run the engine. (It is hidden during a cp vs sat race, which stays live.)",
  },
  {
    target: "thinking",
    title: "the thinking panel",
    body: "This panel names the current decision and the last step in words, and counts decisions, propagations, backtracks, and conflicts as they happen. When the view sits on a dead end, an explain button opens an honest account of that conflict.",
  },
  {
    target: "minimap",
    title: "the search tree",
    body: "Each decision adds a dot to this small tree. The current path is drawn in the accent colour with a ring on the current node; dead ends and the solution path are marked too. It collapses older nodes into a count so a long search stays a glance.",
  },
  {
    target: null,
    title: "that is the tour",
    body: "Press start and step through a hard puzzle, or open the keyboard shortcuts with the ? button. For an honest account of how the engine actually reasons, the how it works page is linked in the header.",
  },
];

// The accent outline placed around the live region a step names. It is a fixed-position box sized to the
// target's bounding rect, drawn with a 1px accent border and a small offset — depth from a border, never
// a shadow. Recomputed on step change, scroll, and resize so it tracks the element. Returns null when the
// step has no target or the target is not in the current layout (the outline is then simply skipped).
function useHighlightRect(target: string | null, open: boolean): DOMRect | null {
  const [rect, setRect] = useState<DOMRect | null>(null);
  useEffect(() => {
    if (!open || !target) {
      setRect(null);
      return;
    }
    const measure = () => {
      const el = document.querySelector<HTMLElement>(`[data-tour-id="${target}"]`);
      setRect(el ? el.getBoundingClientRect() : null);
    };
    measure();
    // Bring the region into view first, then track it through scroll/resize. scrollIntoView honors
    // the user's reduced-motion setting natively (smooth only when motion is allowed).
    const el = document.querySelector<HTMLElement>(`[data-tour-id="${target}"]`);
    el?.scrollIntoView({ block: "nearest", behavior: "smooth" });
    window.addEventListener("scroll", measure, true);
    window.addEventListener("resize", measure);
    return () => {
      window.removeEventListener("scroll", measure, true);
      window.removeEventListener("resize", measure);
    };
  }, [target, open]);
  return rect;
}

export function Tour({
  open,
  onClose,
  returnFocusRef,
}: {
  open: boolean;
  onClose: () => void;
  // The element focus returns to when the tour closes (the "tour" trigger), so a keyboard user lands
  // back where they were rather than at the top of the document.
  returnFocusRef: React.RefObject<HTMLElement | null>;
}) {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const headingRef = useRef<HTMLHeadingElement | null>(null);
  const [index, setIndex] = useState(0);
  const step = STEPS[index];
  const rect = useHighlightRect(step.target, open);

  // Reset to the first step every time the tour opens, so re-launching always starts at the top.
  useEffect(() => {
    if (open) setIndex(0);
  }, [open]);

  // Move focus into the dialog on open (the heading, so a screen reader reads the step) and return it
  // to the trigger on close. Reading the trigger ref inside the cleanup is intentional — it is the
  // element that opened the tour.
  useEffect(() => {
    if (!open) return;
    const trigger = returnFocusRef.current;
    headingRef.current?.focus();
    return () => {
      trigger?.focus();
    };
  }, [open, returnFocusRef]);

  const atFirst = index === 0;
  const atLast = index === STEPS.length - 1;
  const next = useCallback(() => setIndex((i) => Math.min(i + 1, STEPS.length - 1)), []);
  const prev = useCallback(() => setIndex((i) => Math.max(i - 1, 0)), []);

  // ESC closes; ←/→ step the tour; Tab/Shift+Tab is trapped to the panel so focus never escapes to the
  // page behind the dialog (the focus-trap contract, mirroring HelpOverlay). The handler is on the
  // panel, so it only runs while the tour is mounted and open.
  const onKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        onClose();
        return;
      }
      if (e.key === "ArrowRight") {
        e.preventDefault();
        next();
        return;
      }
      if (e.key === "ArrowLeft") {
        e.preventDefault();
        prev();
        return;
      }
      if (e.key !== "Tab") return;
      const panel = panelRef.current;
      if (!panel) return;
      const focusable = panel.querySelectorAll<HTMLElement>(
        'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
      );
      if (focusable.length === 0) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement;
      if (e.shiftKey && active === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && active === last) {
        e.preventDefault();
        first.focus();
      }
    },
    [onClose, next, prev],
  );

  if (!open) return null;

  return (
    // The scrim: a dimmed backdrop a click dismisses. The dialog stops the click so a click inside does
    // not close it. The scrim is presentational; the dialog carries the semantics.
    <div
      className="fixed inset-0 z-50 bg-[color:rgba(14,14,15,0.7)]"
      onClick={onClose}
    >
      {/* The region outline: an accent ring around the live element the step names. Pointer-events are
          off so it never blocks a click, and it is aria-hidden because the step text already names the
          region. Skipped (not rendered) when the step has no target or the target is off the layout. */}
      {rect && (
        <div
          aria-hidden="true"
          className="pointer-events-none fixed rounded-[var(--radius-md)] border border-[color:var(--color-accent)]"
          style={{
            top: rect.top - 4,
            left: rect.left - 4,
            width: rect.width + 8,
            height: rect.height + 8,
          }}
        />
      )}

      {/* The stepper panel, pinned to the bottom on small screens and bottom-right on wide ones so it
          does not cover the region it is describing. A surface card, depth from a 1px border, no drop
          shadow. */}
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="tour-title"
        onKeyDown={onKeyDown}
        onClick={(e) => e.stopPropagation()}
        className="fixed inset-x-4 bottom-4 z-10 mx-auto flex max-w-sm flex-col gap-4 rounded-[var(--radius-lg)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface)] p-6 sm:inset-x-auto sm:right-6"
      >
        <div className="flex items-baseline justify-between gap-4">
          <h2
            id="tour-title"
            ref={headingRef}
            tabIndex={-1}
            className={`font-[family-name:var(--font-display)] text-lg ${FOCUS_RING}`}
          >
            {step.title}
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="close tour"
            className={`shrink-0 rounded-[var(--radius-sm)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] px-2 py-1 text-sm text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] ${FOCUS_RING}`}
          >
            close
          </button>
        </div>

        {/* The caption: announced as it changes so a screen reader hears each step. The text carries the
            meaning, so the tour reads fully without the outline or any motion (the reduced-motion rule). */}
        <p aria-live="polite" className="text-sm text-[color:var(--color-ink-dim)]">
          {step.body}
        </p>

        <div className="flex items-center justify-between gap-4 border-t border-[color:var(--color-border)] pt-4">
          <span className="tabular text-xs text-[color:var(--color-ink-mute)]">
            step {index + 1} of {STEPS.length}
          </span>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={prev}
              disabled={atFirst}
              aria-label="previous step"
              className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] px-3 py-1 text-sm text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] disabled:opacity-40 ${FOCUS_RING}`}
            >
              prev
            </button>
            {atLast ? (
              <button
                type="button"
                onClick={onClose}
                aria-label="finish tour"
                className={`rounded-[var(--radius-sm)] border border-[color:var(--color-accent)] bg-[color:var(--color-accent)] px-3 py-1 text-sm text-[#16161a] transition-colors hover:bg-[color:var(--color-accent-dim)] ${FOCUS_RING}`}
              >
                done
              </button>
            ) : (
              <button
                type="button"
                onClick={next}
                aria-label="next step"
                className={`rounded-[var(--radius-sm)] border border-[color:var(--color-accent)] bg-[color:var(--color-accent)] px-3 py-1 text-sm text-[#16161a] transition-colors hover:bg-[color:var(--color-accent-dim)] ${FOCUS_RING}`}
              >
                next
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
