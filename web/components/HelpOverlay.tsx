"use client";

// The keyboard-shortcut help overlay (VIZ-08). A modal dialog listing every shortcut the page binds,
// opened by the "?" button or the `?`/`h` key and dismissed by ESC or the close button. It is an
// accessible dialog: role="dialog" + aria-modal, an aria-label, focus moves into the panel on open and
// returns to the trigger on close, focus is trapped while open, and ESC closes. Styled with the locked
// tokens only — a surface panel behind a dimmed scrim, depth from a 1px border, no drop shadow. No
// essential motion, so it stays legible under prefers-reduced-motion (the global reduced-motion block in
// globals.css already collapses the one fade).

import { useCallback, useEffect, useRef } from "react";

const FOCUS_RING =
  "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[color:var(--color-border-strong)]";

// The shortcuts the page binds, the single source the overlay renders. Keep this in lockstep with the
// keyboard handler in page.tsx: a key added there is a row added here, in the same change.
const SHORTCUTS: { keys: string[]; action: string }[] = [
  { keys: ["Space"], action: "single-step the solve" },
  { keys: ["←"], action: "step back through history" },
  { keys: ["→"], action: "step forward (live-step at the latest)" },
  { keys: ["P"], action: "play / pause" },
  { keys: ["?", "H"], action: "open this help" },
  { keys: ["Esc"], action: "close this help" },
];

export function HelpOverlay({
  open,
  onClose,
  returnFocusRef,
}: {
  open: boolean;
  onClose: () => void;
  // The element focus returns to when the dialog closes (the "?" trigger), so a keyboard user lands back
  // where they were rather than at the top of the document.
  returnFocusRef: React.RefObject<HTMLElement | null>;
}) {
  const panelRef = useRef<HTMLDivElement | null>(null);
  const closeBtnRef = useRef<HTMLButtonElement | null>(null);

  // Move focus into the dialog on open and return it to the trigger on close. Reading the trigger ref at
  // close time (inside the cleanup) is intentional: it is the element that opened the dialog.
  useEffect(() => {
    if (!open) return;
    const trigger = returnFocusRef.current;
    closeBtnRef.current?.focus();
    return () => {
      trigger?.focus();
    };
  }, [open, returnFocusRef]);

  // ESC closes; Tab/Shift+Tab is trapped to the dialog's focusable elements so focus never escapes to the
  // page behind the modal (the focus-trap contract). The handler is on the panel, not the window, so it
  // only runs while the dialog is mounted and open.
  const onKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        onClose();
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
    [onClose],
  );

  if (!open) return null;

  return (
    // The scrim: a dimmed backdrop a click on dismisses. The dialog itself stops the click so a click
    // inside the panel does not close it. The scrim is presentational; the dialog carries the semantics.
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-[color:rgba(14,14,15,0.7)] p-6"
      onClick={onClose}
    >
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="help-title"
        onKeyDown={onKeyDown}
        onClick={(e) => e.stopPropagation()}
        className="flex w-full max-w-sm flex-col gap-5 rounded-[var(--radius-lg)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface)] p-6"
      >
        <div className="flex items-baseline justify-between">
          <h2
            id="help-title"
            className="font-[family-name:var(--font-display)] text-lg"
          >
            keyboard shortcuts
          </h2>
          <button
            ref={closeBtnRef}
            type="button"
            onClick={onClose}
            aria-label="close help"
            className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] px-2 py-1 text-sm text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] ${FOCUS_RING}`}
          >
            close
          </button>
        </div>

        <dl className="flex flex-col gap-3">
          {SHORTCUTS.map((s) => (
            <div key={s.action} className="flex items-baseline justify-between gap-4">
              <dt className="flex gap-1.5">
                {s.keys.map((k) => (
                  <kbd
                    key={k}
                    className="tabular rounded-[var(--radius-sm)] border border-[color:var(--color-border)] bg-[color:var(--color-surface-2)] px-1.5 py-0.5 text-xs text-[color:var(--color-ink)]"
                  >
                    {k}
                  </kbd>
                ))}
              </dt>
              <dd className="text-sm text-[color:var(--color-ink-dim)]">{s.action}</dd>
            </div>
          ))}
        </dl>
      </div>
    </div>
  );
}
