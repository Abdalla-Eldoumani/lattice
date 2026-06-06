// Milestone-3 placeholder. This becomes the visualizer: the puzzle renderers (Sudoku grid,
// graph, nonogram, N-queens board), the animation layer that consumes the event stream, the
// controls (step/slow/play/restart, puzzle and engine pickers, the hard-instance button), the
// thinking panel, and the search-tree minimap. For now it just confirms the tokens load.
// Build this only after milestone 1 (CP core + CLI + tests) is green. See ../lib/protocol.ts
// for the event contract this UI will consume.

export default function Home() {
  return (
    <main className="mx-auto flex min-h-screen max-w-3xl flex-col justify-center gap-4 px-6 py-16">
      <h1 className="font-[family-name:var(--font-display)] text-5xl font-normal tracking-tight">
        lattice
      </h1>
      <p className="text-[color:var(--color-ink-dim)]">
        Watch a constraint solver think. The visualizer lands in milestone 3.
      </p>
      <p className="tabular text-sm text-[color:var(--color-ink-mute)]">
        decisions 0 &middot; propagations 0 &middot; backtracks 0
      </p>
    </main>
  );
}
