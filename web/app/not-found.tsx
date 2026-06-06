import Link from "next/link";

// The custom 404. It stays on the editorial-dark design tokens, names the state in text (not just
// color), and offers a clear way back. Rendered by the App Router for any unmatched route.

const FOCUS_RING =
  "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[color:var(--color-border-strong)]";

export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-screen max-w-2xl flex-col items-start justify-center gap-5 px-6 py-12">
      <p className="tabular text-sm text-[color:var(--color-ink-mute)]">error 404</p>
      <h1 className="font-[family-name:var(--font-display)] text-5xl font-normal tracking-tight">
        this page does not exist
      </h1>
      <p className="max-w-prose text-[color:var(--color-ink-dim)]">
        The address you followed points nowhere in this project. It may be mistyped, or the page may
        have moved. The solver and its puzzles are all on the main view.
      </p>
      <nav className="mt-2 flex flex-wrap items-center gap-5 text-sm">
        <Link
          href="/"
          aria-label="back to the visualizer"
          className={`rounded-[var(--radius-sm)] text-[color:var(--color-accent)] transition-colors hover:text-[color:var(--color-accent-dim)] ${FOCUS_RING}`}
        >
          &larr; back to the visualizer
        </Link>
        <Link
          href="/about"
          aria-label="read how it works"
          className={`rounded-[var(--radius-sm)] text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] ${FOCUS_RING}`}
        >
          how it works
        </Link>
      </nav>
    </main>
  );
}
