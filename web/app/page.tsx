"use client";

// The Sudoku visualizer (VIZ-01/02/03): a 9x9 grid that animates the engine's event stream, the
// step/play/pause/restart controls that drive it, and the thinking panel with the live counters.

import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { type RaceSide, useSolver } from "../lib/useSolver";
import { type Engine, type PuzzleKind } from "../lib/protocol";
import { PuzzleView } from "../components/PuzzleView";
import { Minimap } from "../components/Minimap";
import { HelpOverlay } from "../components/HelpOverlay";
import { ConflictExplainer } from "../components/ConflictExplainer";
import { conflictIndexAtCursor, explainConflict } from "../lib/explain";
import { DEFAULT_PUZZLE_KEY, findPresetKey, type PuzzleDef, PUZZLES } from "../lib/puzzles";
import { buildShareUrl, decodeShare } from "../lib/share";

// Which engines a given instance can run. A dimacs (raw CNF) instance is SAT-only. A dual-encodable
// instance (graph, which the server builds as both a CP model and a CNF) offers cp, sat, and the
// cp-vs-sat race. Every other CP puzzle is CP-only (no CNF encoding exists for it). The picker offers
// exactly these, so the user can never pick an engine that would not route on the server.
function engineOptionsFor(puzzle: PuzzleDef): { value: Engine; label: string }[] {
  if (puzzle.kind === "dimacs") return [{ value: "sat", label: "sat" }];
  if (puzzle.dualEncodable) {
    return [
      { value: "cp", label: "cp" },
      { value: "sat", label: "sat" },
      { value: "race", label: "cp vs sat" },
    ];
  }
  return [{ value: "cp", label: "cp" }];
}

// the shared focus ring: a visible 2px --color-border-strong outline on every control, so a keyboard
// user always sees where focus is (the accessibility contract, VIZ-08). focus-visible (not focus)
// keeps it keyboard-only, never a mouse-click halo.
const FOCUS_RING =
  "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[color:var(--color-border-strong)]";

// The synthetic picker key/label a shared permalink uses when its definition matches no preset (a
// hand-edited or otherwise unknown instance). A shared link that DOES match a preset restores that
// preset instead (findPresetKey), so this entry appears only for a genuinely off-preset instance, and
// only while one is loaded. It carries the decoded kind so the renderer and the engine picker behave
// exactly as they would for a real preset of that kind.
const SHARED_PUZZLE_KEY = "shared";

// How long the "link copied" confirmation stays up after a successful copy, in ms. Long enough to read,
// short enough that the control bar returns to its resting label without a manual dismiss.
const COPIED_FEEDBACK_MS = 2000;

// The play-speed band the slider spans, in events/sec. It sits well inside the server's [0.1, 1000]
// clamp (delayOf in app/server/Main.hs) so any value the slider can produce is honored verbatim, never
// coerced. The default matches the speed the play control used before this control existed.
const SPEED_MIN = 1;
const SPEED_MAX = 60;
const SPEED_DEFAULT = 12;

export default function Home() {
  const solver = useSolver();
  const [puzzleKey, setPuzzleKey] = useState(DEFAULT_PUZZLE_KEY);
  const [engine, setEngine] = useState<Engine>("cp");
  const [playing, setPlaying] = useState(false);
  const [speed, setSpeed] = useState(SPEED_DEFAULT);
  const [helpOpen, setHelpOpen] = useState(false);
  // A shared off-preset instance restored from a permalink (lib/share.ts), or null. Holds the decoded
  // { kind, definition } the synthetic "from link" picker entry renders. A shared link that matches a
  // preset never lands here — it just selects that preset — so this is set only for an unknown instance.
  const [sharedPuzzle, setSharedPuzzle] = useState<PuzzleDef | null>(null);
  // The "?" trigger, so the dialog returns focus here when it closes (the focus-return contract).
  const helpButtonRef = useRef<HTMLButtonElement | null>(null);

  // Restore shared state from the URL hash on mount (VIZ permalinks). Read in an effect, after
  // hydration, so the server and the first client render agree (no hash on the server) and there is no
  // SSR mismatch — the same client-only pattern usePrefersReducedMotion uses. A malformed, oversized, or
  // invalid hash decodes to null and is ignored, leaving the default instance; the engine is then
  // re-validated by the engineValid path below, so an engine the kind cannot run is snapped to a legal
  // one rather than sent to the server. Runs once; later in-app picker changes do not touch the hash.
  useEffect(() => {
    const decoded = decodeShare(window.location.hash);
    if (!decoded) return;
    const presetKey = findPresetKey(decoded.kind, decoded.definition);
    if (presetKey) {
      // A known fixture: select the real preset (its label, its dualEncodable flag) and drop the hash so
      // the URL reads clean and a later in-app share rebuilds from the live selection.
      setPuzzleKey(presetKey);
      setSharedPuzzle(null);
    } else {
      // An off-preset instance: build a synthetic "from link" entry the picker and renderer treat like a
      // real preset of that kind. dualEncodable is inferred from the kind (graph is the only one), so the
      // engine picker offers the same options it would for that kind.
      setSharedPuzzle({
        kind: decoded.kind,
        label: "from link",
        definition: decoded.definition,
        dualEncodable: decoded.kind === "graph",
      });
      setPuzzleKey(SHARED_PUZZLE_KEY);
    }
    setEngine(decoded.engine);
    // Clear the hash without a reload so back/forward and a manual refresh do not re-trigger the restore
    // and the address bar is not stuck on a long payload. The selection is already in React state.
    window.history.replaceState(null, "", window.location.pathname + window.location.search);
  }, []);

  const n = solver.size;
  const box = Math.round(Math.sqrt(n));
  // The selected puzzle: a real preset by key, or the synthetic shared entry when the picker is on it.
  // Falls back to the default preset if puzzleKey is somehow neither (it never is in practice).
  const selected: PuzzleDef =
    (puzzleKey === SHARED_PUZZLE_KEY ? sharedPuzzle : PUZZLES[puzzleKey]) ??
    PUZZLES[DEFAULT_PUZZLE_KEY];
  const engineOptions = useMemo(() => engineOptionsFor(selected), [selected]);
  // Keep the engine valid for the selected puzzle: when the puzzle changes, snap the engine to the
  // first option it offers if the current choice is no longer available (e.g. switching to a dimacs
  // instance forces sat; switching back to a CP-only puzzle forces cp).
  const engineValid = engineOptions.some((o) => o.value === engine);
  const effectiveEngine: Engine = engineValid ? engine : engineOptions[0].value;
  useEffect(() => {
    if (!engineValid) setEngine(engineOptions[0].value);
  }, [engineValid, engineOptions]);
  // SAT counters (learned clauses / restarts) are meaningful only for a SAT-running engine.
  const showSatCounters = effectiveEngine === "sat" || effectiveEngine === "race";
  // The race renders two panels only once useSolver has seeded both models for a race start. Until
  // then (a fresh page, or before pressing start) the single-panel layout shows the CP-side seed.
  const racing = effectiveEngine === "race" && solver.race !== null;

  const onPlayPause = useCallback(() => {
    if (playing) {
      solver.pause();
      setPlaying(false);
    } else {
      solver.play(speed);
      setPlaying(true);
    }
  }, [playing, solver, speed]);

  // Changing the speed mid-play re-sends play(newSpeed) so the new cadence takes effect immediately
  // (the server's check-and-set Play supersedes the running loop rather than stacking a second one).
  // While paused it only records the value, which the next play picks up. Works in both single-engine
  // and race modes — play/pause drives the one control bar over the same socket in either.
  const onSpeedChange = useCallback(
    (next: number) => {
      setSpeed(next);
      if (playing) solver.play(next);
    },
    [playing, solver],
  );

  // Share state: a short-lived "link copied" confirmation announced via an aria-live region (non-color
  // feedback, VIZ-08), and a fallback URL shown when navigator.clipboard is unavailable so the user can
  // still select and copy the link by hand. Both are cleared as the next share resets them.
  const [shareStatus, setShareStatus] = useState("");
  const [shareFallbackUrl, setShareFallbackUrl] = useState("");

  // Build the permalink for the current selection (its kind + raw definition + effective engine — the
  // engine actually validated for this kind, never a stale picker value) and copy it to the clipboard.
  // navigator.clipboard is async and can reject (denied permission, insecure context); on any failure
  // fall back to showing the URL in a read-only field the user can select. Encoding is total, so the
  // build itself never throws. The confirmation auto-clears after COPIED_FEEDBACK_MS.
  const onShare = useCallback(async () => {
    const url = buildShareUrl(
      { kind: selected.kind, engine: effectiveEngine, definition: selected.definition },
      new URL(window.location.href),
    );
    setShareFallbackUrl("");
    try {
      if (!navigator.clipboard) throw new Error("clipboard unavailable");
      await navigator.clipboard.writeText(url);
      setShareStatus("link copied");
      window.setTimeout(() => setShareStatus(""), COPIED_FEEDBACK_MS);
    } catch {
      // No clipboard (older browser, insecure origin, or denied): surface the URL so the user can copy
      // it manually. The status line points them at it; it stays until the next share.
      setShareStatus("copy the link below");
      setShareFallbackUrl(url);
    }
  }, [selected.kind, selected.definition, effectiveEngine]);

  // keyboard control (VIZ-08): space single-steps the live solver, arrows scrub the history, p toggles
  // play/pause, ? or h opens the shortcut help. The keys drive the SAME actions the buttons do (gate the
  // animation, never the state). Keys are ignored while focus is in the picker or any text field so the
  // native select/range keyboard still works, and space's/arrows' default page scroll is prevented. The
  // help key and the history-nav arrows work regardless of connection (they are documentation / pure
  // client-side replay, not a solver action); the live solver keys require an open socket. While the
  // help dialog is open every page key is suppressed so its ESC/Tab handling (focus trap) owns the board.
  //
  // The Right-arrow has a dual role: when scrubbed back into history it steps the view FORWARD through
  // the received events (pure replay); at the live edge it sends a solver `step` (the live behavior, so
  // following the edge keeps advancing the real solve). Left-arrow always steps the view backward.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      const el = e.target as HTMLElement | null;
      const tag = el?.tagName;
      if (tag === "SELECT" || tag === "INPUT" || tag === "TEXTAREA" || el?.isContentEditable) return;
      // The help toggle: `?` (Shift+/ on most layouts reports key "?") or `h`. It is the one key that
      // works while the dialog is closed without a live solver. Once the dialog is open the overlay traps
      // its own keys, so this window path never reopens it.
      if (!helpOpen && (e.key === "?" || e.key === "h" || e.key === "H")) {
        e.preventDefault();
        setHelpOpen(true);
        return;
      }
      if (helpOpen) return; // the dialog owns the keyboard while open
      // History navigation: pure client-side replay over already-received events, so it works without a
      // live socket. Left always steps back; Right steps forward only while scrubbed back (at the live
      // edge it falls through to the live `step` below). No-ops at the ends / in race mode are absorbed
      // by the hook's clamp, so these are always safe to fire.
      if (e.key === "ArrowLeft") {
        e.preventDefault(); // arrows would otherwise scroll the page
        solver.stepBack();
        return;
      }
      if (e.key === "ArrowRight" && !solver.following) {
        e.preventDefault();
        solver.stepForward();
        return;
      }
      // The live solver keys: only when the socket is open. Right-arrow reaches here at the live edge,
      // where it must drive the real solve forward exactly as before (do not break the live step).
      if (solver.conn !== "open") return;
      if (e.key === " " || e.key === "ArrowRight") {
        e.preventDefault(); // space would otherwise scroll the page
        solver.step();
      } else if (e.key === "p" || e.key === "P") {
        e.preventDefault();
        onPlayPause();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [solver, onPlayPause, helpOpen]);

  return (
    <main className="mx-auto flex min-h-screen max-w-5xl flex-col gap-8 px-6 py-12">
      <header className="flex items-baseline justify-between border-b border-[color:var(--color-border)] pb-4">
        <h1 className="font-[family-name:var(--font-display)] text-4xl font-normal tracking-tight">
          lattice
        </h1>
        <div className="flex items-baseline gap-4">
          <span className="tabular text-xs text-[color:var(--color-ink-mute)]">
            {connLabel(solver.conn)}
          </span>
          {/* The help trigger: opens the shortcut dialog. aria-haspopup="dialog" + aria-expanded so a
              screen reader announces it opens a modal and its current state. The `?` glyph is the label
              (aria-label carries the readable name) — the same affordance the `?`/`h` key invokes. */}
          <button
            ref={helpButtonRef}
            type="button"
            onClick={() => setHelpOpen(true)}
            aria-label="keyboard shortcuts"
            aria-haspopup="dialog"
            aria-expanded={helpOpen}
            className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] px-2 py-0.5 text-sm text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] ${FOCUS_RING}`}
          >
            ?
          </button>
        </div>
      </header>

      {racing && solver.race ? (
        // Race mode (SAT-06): two side-by-side panels on one dual-encodable instance, each its own
        // renderer + counters, with the one control bar spanning the top above both. The panels sit
        // side by side at desktop (lg:grid-cols-2 gap-8) and stack single-column (CP above SAT) at
        // tablet/mobile — the panels shrink, the renderers do not.
        <div className="flex flex-col gap-8">
          <div className="flex justify-center">
            <Controls
              puzzleKey={puzzleKey}
              setPuzzleKey={setPuzzleKey}
              sharedPuzzle={sharedPuzzle}
              engine={effectiveEngine}
              setEngine={setEngine}
              engineOptions={engineOptions}
              playing={playing}
              speed={speed}
              onSpeedChange={onSpeedChange}
              disabled={solver.conn !== "open"}
              onShare={onShare}
              shareStatus={shareStatus}
              shareFallbackUrl={shareFallbackUrl}
              onStart={() => {
                setPlaying(false);
                solver.start(selected.definition, selected.kind, effectiveEngine);
              }}
              onStep={solver.step}
              onPlayPause={onPlayPause}
              onRestart={() => {
                setPlaying(false);
                solver.restart();
              }}
            />
          </div>
          <div className="grid gap-8 lg:grid-cols-2">
            <RacePanel engine="cp" side={solver.race.cp} definition={selected.definition} />
            <RacePanel engine="sat" side={solver.race.sat} definition={selected.definition} />
          </div>
        </div>
      ) : (
        <div className="grid gap-8 lg:grid-cols-[auto_1fr]">
          <section className="flex flex-col items-center gap-5">
            <PuzzleView
              kind={selected.kind}
              grid={solver.grid}
              n={n}
              box={box}
              definition={selected.definition}
              learnedClause={solver.learnedClause}
            />
            <Controls
              puzzleKey={puzzleKey}
              setPuzzleKey={setPuzzleKey}
              sharedPuzzle={sharedPuzzle}
              engine={effectiveEngine}
              setEngine={setEngine}
              engineOptions={engineOptions}
              playing={playing}
              speed={speed}
              onSpeedChange={onSpeedChange}
              disabled={solver.conn !== "open"}
              onShare={onShare}
              shareStatus={shareStatus}
              shareFallbackUrl={shareFallbackUrl}
              onStart={() => {
                setPlaying(false);
                solver.start(selected.definition, selected.kind, effectiveEngine);
              }}
              onStep={solver.step}
              onPlayPause={onPlayPause}
              onRestart={() => {
                setPlaying(false);
                solver.restart();
              }}
            />
            {/* The event scrubber: replay/step-back through the events already received. Single-engine
                only (the race is play-only — see docs/VISUALIZER.md), so it never renders in the race layout
                above. Disabled until the buffer has events. */}
            <Scrubber
              count={solver.eventCount}
              cursor={solver.cursor}
              following={solver.following}
              onSeek={solver.seek}
              onStepBack={solver.stepBack}
              onStepForward={solver.stepForward}
              onJumpToLive={solver.jumpToLive}
            />
          </section>

          <ThinkingPanel solver={solver} showSatCounters={showSatCounters} />
        </div>
      )}

      <HelpOverlay
        open={helpOpen}
        onClose={() => setHelpOpen(false)}
        returnFocusRef={helpButtonRef}
      />
    </main>
  );
}

// One race panel: a surface card with a caption engine subtitle, its own renderer (the CP panel shows
// the puzzle's native renderer, e.g. GraphView; the SAT panel shows the TrailView of the CNF encoding),
// and its own counter block. Each panel is an accessible region (aria-label "cp engine" / "sat engine")
// so a screen reader distinguishes the two engines (VIZ-08, threat T-05-23). The renderer is the hero;
// the counters sit beneath it (the single-engine hierarchy at panel scale). The SAT panel additionally
// shows the learned-clauses / restarts counters; the CP panel does NOT (they would read 0 and mislead).
function RacePanel({
  engine,
  side,
  definition,
}: {
  engine: "cp" | "sat";
  side: RaceSide;
  definition: string;
}) {
  const n = side.size;
  const box = Math.round(Math.sqrt(n));
  const d = side.currentDecision;
  return (
    <section
      aria-label={`${engine} engine`}
      className="flex flex-col items-center gap-4 rounded-[var(--radius-lg)] border border-[color:var(--color-border)] bg-[color:var(--color-surface)] p-6"
    >
      <div className="flex w-full items-baseline justify-between">
        <span className="font-[family-name:var(--font-display)] text-lg">
          {engine === "cp" ? "cp" : "sat"}
        </span>
        <span className="text-xs text-[color:var(--color-ink-dim)]">
          {engine === "cp" ? "constraint propagation" : "cdcl"}
        </span>
      </div>

      <PuzzleView
        kind={side.kind as PuzzleKind}
        grid={side.grid}
        n={n}
        box={box}
        definition={definition}
        learnedClause={side.learnedClause}
      />

      {/* The per-panel live region: each engine's current decision / last step is read out on its
          own so a screen reader follows the two engines independently (the race-mode aria contract). */}
      <div aria-live="polite" className="flex w-full flex-col gap-1 text-sm">
        <span className="text-[color:var(--color-ink-mute)]">current decision</span>
        <span className="tabular text-[color:var(--color-accent)]">
          {d ? `cell ${d.cell} = ${d.value} @ level ${d.level}` : "--"}
        </span>
      </div>

      <div className="flex w-full flex-col gap-1.5 border-t border-[color:var(--color-border)] pt-4">
        <Counter label="decisions" value={side.counters.decisions} />
        <Counter label="propagations" value={side.counters.propagations} />
        <Counter label="backtracks" value={side.counters.backtracks} />
        <Counter label="conflicts" value={side.counters.conflicts} />
        {/* The SAT-only counters live on the SAT panel only; the CP panel never shows them. */}
        {engine === "sat" && (
          <>
            <Counter label="learned clauses" value={side.counters.learnedClauses} />
            <Counter label="restarts" value={side.counters.restarts} />
          </>
        )}
      </div>

      {side.solved && (
        <p className="tabular w-full text-sm text-[color:var(--color-state-solved)]">
          {engine === "sat" ? "sat" : "solved"}
        </p>
      )}
      {/* Each race panel reflects its OWN engine's result. The unsat line mirrors the solved line:
          conflict-red with a leading ⊥ glyph (the non-color cue, VIZ-08) and role=status so the
          panel's outcome is announced even though the two engines resolve independently. */}
      {side.unsat && (
        <p
          role="status"
          className="tabular w-full text-sm text-[color:var(--color-state-conflict)]"
        >
          <span aria-hidden="true">⊥ </span>
          {engine === "sat" ? "unsat" : "unsat — no solution"}
        </p>
      )}
    </section>
  );
}

function connLabel(conn: string): string {
  if (conn === "open") return "engine connected";
  if (conn === "connecting") return "connecting to engine...";
  return "engine offline - start the lattice-server on :8080";
}

function Controls({
  puzzleKey,
  setPuzzleKey,
  sharedPuzzle,
  engine,
  setEngine,
  engineOptions,
  playing,
  speed,
  onSpeedChange,
  disabled,
  onShare,
  shareStatus,
  shareFallbackUrl,
  onStart,
  onStep,
  onPlayPause,
  onRestart,
}: {
  puzzleKey: string;
  setPuzzleKey: (k: string) => void;
  sharedPuzzle: PuzzleDef | null;
  engine: Engine;
  setEngine: (e: Engine) => void;
  engineOptions: { value: Engine; label: string }[];
  playing: boolean;
  speed: number;
  onSpeedChange: (speed: number) => void;
  disabled: boolean;
  onShare: () => void;
  shareStatus: string;
  shareFallbackUrl: string;
  onStart: () => void;
  onStep: () => void;
  onPlayPause: () => void;
  onRestart: () => void;
}) {
  // The second caption appears only when a non-cp engine is reachable (a dual-encodable or dimacs
  // instance), so the race hint never shows on a CP-only puzzle.
  const raceReachable = engineOptions.some((o) => o.value === "race");
  return (
    <div className="flex flex-col items-center gap-1.5">
      <div className="flex flex-wrap items-center justify-center gap-2">
        <select
          value={puzzleKey}
          onChange={(e) => setPuzzleKey(e.target.value)}
          aria-label="puzzle"
          className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border)] bg-[color:var(--color-surface-2)] px-2 py-1.5 text-sm text-[color:var(--color-ink)] ${FOCUS_RING}`}
        >
          {/* The "from link" entry exists only while a shared off-preset instance is loaded, so the
              picker reflects the restored selection (VIZ permalinks). Selecting a real preset replaces
              the page's selected puzzle; switching away from this entry leaves it visible (the shared
              instance is still loadable) until a refresh, which is the intended sticky behavior. */}
          {sharedPuzzle && (
            <option value={SHARED_PUZZLE_KEY}>{sharedPuzzle.label}</option>
          )}
          {Object.entries(PUZZLES).map(([k, p]) => (
            <option key={k} value={k}>
              {p.label}
            </option>
          ))}
        </select>
        {/* The engine picker: same affordance as the puzzle picker (FOCUS_RING, styling). It drives
            the engine field on start; it offers only the engines the selected instance can run. */}
        <select
          value={engine}
          onChange={(e) => setEngine(e.target.value as Engine)}
          aria-label="engine"
          disabled={engineOptions.length <= 1}
          className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border)] bg-[color:var(--color-surface-2)] px-2 py-1.5 text-sm text-[color:var(--color-ink)] disabled:opacity-40 ${FOCUS_RING}`}
        >
          {engineOptions.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
        <Btn primary disabled={disabled} onClick={onStart}>
          start
        </Btn>
        <Btn disabled={disabled} onClick={onStep}>
          step
        </Btn>
        <Btn disabled={disabled} onClick={onPlayPause}>
          {playing ? "pause" : "play"}
        </Btn>
        <Btn disabled={disabled} onClick={onRestart}>
          restart
        </Btn>
        {/* Share: copies a permalink that reproduces the current instance (kind + engine + raw
            definition, lib/share.ts). Styled like the secondary controls (FOCUS_RING, same border/
            surface), with its own aria-label. It is NOT gated on the socket — a link describes the
            selection, not the live solve, so it works offline. Its feedback is the aria-live line
            below, never color alone. */}
        <button
          type="button"
          onClick={onShare}
          aria-label="copy a shareable link to this instance"
          className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] px-3 py-1.5 text-sm text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] ${FOCUS_RING}`}
        >
          share
        </button>
      </div>
      {/* The share confirmation: an aria-live region so a screen reader announces "link copied" (or the
          fallback prompt) without relying on color — the text itself is the signal (VIZ-08). When the
          clipboard is unavailable the URL is rendered in a read-only, full-width field the user can
          select and copy by hand. The field auto-focuses+selects so a keyboard user can copy at once. */}
      {(shareStatus || shareFallbackUrl) && (
        <div aria-live="polite" className="flex w-full flex-col items-center gap-1.5">
          {shareStatus && (
            <span className="tabular text-xs text-[color:var(--color-ink-dim)]">
              {shareStatus}
            </span>
          )}
          {shareFallbackUrl && (
            <input
              type="text"
              readOnly
              value={shareFallbackUrl}
              aria-label="shareable link"
              onFocus={(e) => e.currentTarget.select()}
              autoFocus
              className={`tabular w-full max-w-md rounded-[var(--radius-sm)] border border-[color:var(--color-border)] bg-[color:var(--color-surface-2)] px-2 py-1 text-xs text-[color:var(--color-ink)] ${FOCUS_RING}`}
            />
          )}
        </div>
      )}
      {/* Play-speed control (VIZ): a real range input so it is keyboard-accessible (arrows step it),
          carrying its own focus ring and aria-label. The value is announced beside it in tabular mono
          (digits do not shift the layout) and is the non-color signal — the slider position is never
          the only cue. accent-* tints the native thumb/track with the one theme accent. The band sits
          inside the server's [0.1, 1000] clamp, so any value here is honored. */}
      <div className="flex items-center gap-2">
        <label
          htmlFor="play-speed"
          className="text-xs text-[color:var(--color-ink-mute)]"
        >
          speed
        </label>
        <input
          id="play-speed"
          type="range"
          min={SPEED_MIN}
          max={SPEED_MAX}
          step={1}
          value={speed}
          disabled={disabled}
          onChange={(e) => onSpeedChange(Number(e.target.value))}
          aria-label="play speed (events per second)"
          aria-valuetext={`${speed} events per second`}
          className={`h-1 w-32 cursor-pointer accent-[color:var(--color-accent)] disabled:opacity-40 ${FOCUS_RING}`}
        />
        <span className="tabular w-16 text-xs text-[color:var(--color-ink-dim)]">
          {speed} ev/s
        </span>
      </div>
      <span className="text-xs text-[color:var(--color-ink-mute)]">
        hard presets make the search visibly backtrack
      </span>
      {raceReachable && (
        <span className="text-xs text-[color:var(--color-ink-mute)]">
          cp vs sat races both engines on one instance
        </span>
      )}
    </div>
  );
}

// The event scrubber / step-back timeline (VIZ extras). It lets the viewer move backward and forward
// through the events ALREADY received and re-derive the view from the pure reducer over a prefix — the
// "watch it think" replay. A real range input over [0, count] (keyboard-accessible: arrows step it, the
// same as the page's Left/Right shortcuts) carries its own FOCUS_RING, aria-label, and an aria-valuetext
// reading "event N of M". The position is also rendered as tabular text so it is legible without the
// slider thumb (the reduced-motion requirement: no essential motion in the scrubber). A non-color
// "viewing history" indicator plus a "jump to live" button appear only when scrubbed back. Before any
// event (count 0) every control is disabled — there is nothing to replay yet.
function Scrubber({
  count,
  cursor,
  following,
  onSeek,
  onStepBack,
  onStepForward,
  onJumpToLive,
}: {
  count: number;
  cursor: number;
  following: boolean;
  onSeek: (index: number) => void;
  onStepBack: () => void;
  onStepForward: () => void;
  onJumpToLive: () => void;
}) {
  const empty = count === 0;
  const valueText = empty
    ? "no events yet"
    : `event ${cursor} of ${count}`;
  return (
    <div className="flex w-full max-w-md flex-col items-center gap-1.5">
      <div className="flex w-full items-center gap-2">
        <button
          type="button"
          onClick={onStepBack}
          disabled={empty || cursor === 0}
          aria-label="step back one event"
          className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] px-2 py-1 text-sm text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] disabled:opacity-40 ${FOCUS_RING}`}
        >
          <span aria-hidden="true">{"←"}</span>
        </button>
        <input
          type="range"
          min={0}
          max={Math.max(count, 0)}
          step={1}
          value={cursor}
          disabled={empty}
          onChange={(e) => onSeek(Number(e.target.value))}
          aria-label="event timeline"
          aria-valuetext={valueText}
          className={`h-1 flex-1 cursor-pointer accent-[color:var(--color-accent)] disabled:opacity-40 ${FOCUS_RING}`}
        />
        <button
          type="button"
          onClick={onStepForward}
          disabled={empty || cursor >= count}
          aria-label="step forward one event"
          className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] px-2 py-1 text-sm text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] disabled:opacity-40 ${FOCUS_RING}`}
        >
          <span aria-hidden="true">{"→"}</span>
        </button>
      </div>
      {/* The position read-out, always present as text so the moment is legible without the slider
          thumb (no essential motion). When scrubbed back it carries the explicit "viewing history"
          state plus a "jump to live" button; at the live edge it reads "live". role=status so a screen
          reader hears the position change. */}
      <div
        role="status"
        className="flex w-full items-center justify-between gap-2 text-xs"
      >
        <span className="tabular text-[color:var(--color-ink-dim)]">
          {empty ? "no events yet" : following ? `live - ${count} events` : `viewing history - ${cursor} of ${count}`}
        </span>
        {!following && !empty && (
          <button
            type="button"
            onClick={onJumpToLive}
            aria-label="jump to the latest event"
            className={`rounded-[var(--radius-sm)] border border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] px-2 py-0.5 text-[color:var(--color-ink-dim)] transition-colors hover:text-[color:var(--color-ink)] ${FOCUS_RING}`}
          >
            jump to live
          </button>
        )}
      </div>
    </div>
  );
}

function Btn({
  children,
  onClick,
  primary,
  disabled,
}: {
  children: ReactNode;
  onClick: () => void;
  primary?: boolean;
  disabled?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`rounded-[var(--radius-sm)] border px-3 py-1.5 text-sm transition-colors disabled:opacity-40 ${FOCUS_RING} ${
        primary
          ? "border-[color:var(--color-accent)] bg-[color:var(--color-accent)] text-[#16161a] hover:bg-[color:var(--color-accent-dim)]"
          : "border-[color:var(--color-border-strong)] bg-[color:var(--color-surface-2)] text-[color:var(--color-ink-dim)] hover:text-[color:var(--color-ink)]"
      }`}
    >
      {children}
    </button>
  );
}

function ThinkingPanel({
  solver,
  showSatCounters,
}: {
  solver: ReturnType<typeof useSolver>;
  showSatCounters: boolean;
}) {
  const d = solver.currentDecision;
  // The conflict the viewer can inspect: the conflict event at (or most recently before) the current
  // cursor, reconstructed by the pure analyzer from the buffered events. Recomputed whenever the cursor
  // or the buffer grows, so scrubbing onto a conflict and inspecting it shows THAT conflict (and a live
  // solve sitting on a fresh conflict offers it too). Null when no conflict precedes the cursor.
  const conflictIndex = useMemo(
    () => conflictIndexAtCursor(solver.events, solver.cursor),
    [solver.events, solver.cursor, solver.eventCount],
  );
  const explanation = useMemo(
    () => (conflictIndex >= 0 ? explainConflict(solver.events, conflictIndex) : null),
    [solver.events, conflictIndex, solver.eventCount],
  );
  // Whether the explainer panel is open. It auto-closes when the inspectable conflict changes (the
  // viewer scrubbed to a different conflict / past all conflicts), so the open panel never describes a
  // stale event — they re-open it for the new one. Tracked by the conflict's index so a same-index
  // recompute (e.g. the buffer grew) keeps it open.
  const [openIndex, setOpenIndex] = useState<number | null>(null);
  useEffect(() => {
    // Close the panel if the conflict it described is no longer the inspectable one.
    if (openIndex !== null && openIndex !== conflictIndex) setOpenIndex(null);
  }, [conflictIndex, openIndex]);
  const explainerOpen = openIndex !== null && openIndex === conflictIndex && explanation !== null;

  return (
    <aside className="flex flex-col gap-5 rounded-[var(--radius-md)] border border-[color:var(--color-border)] bg-[color:var(--color-surface)] p-5">
      <h2 className="font-[family-name:var(--font-display)] text-lg">thinking</h2>

      {/* the reasoning, announced as an aria-live region (VIZ-08): the current decision and the last
          step (which carries the propagation/conflict text) are read out as they change, so a screen
          reader user follows the solve without watching the grid. polite: announce after the current
          utterance, never interrupting. */}
      <div aria-live="polite" className="flex flex-col gap-5">
        <div className="flex flex-col gap-1 text-sm">
          <span className="text-[color:var(--color-ink-mute)]">current decision</span>
          <span className="tabular text-[color:var(--color-accent)]">
            {d ? `cell ${d.cell} = ${d.value} @ level ${d.level}` : "--"}
          </span>
        </div>

        <div className="flex flex-col gap-1 text-sm">
          <span className="text-[color:var(--color-ink-mute)]">last step</span>
          <span className="tabular text-[color:var(--color-ink-dim)]">
            {solver.lastReason || "--"}
          </span>
        </div>
      </div>

      {/* The conflict-inspect affordance + panel. When the cursor sits on (or just past) a conflict, a
          real focusable "explain" button appears; pressing it opens the ConflictExplainer with that
          conflict's faithful explanation. Reachable on a live solve and when scrubbed onto a conflict
          via the scrubber (both feed the cursor). When no conflict precedes the cursor, neither the
          button nor the panel renders. */}
      {explanation !== null && (
        <div className="flex flex-col gap-3">
          {!explainerOpen && (
            <button
              type="button"
              onClick={() => setOpenIndex(conflictIndex)}
              aria-label={`explain the conflict at ${
                explanation.engine === "sat" ? "variable" : "cell"
              } ${explanation.cell}`}
              className={`self-start rounded-[var(--radius-sm)] border border-[color:var(--color-state-conflict)] bg-[color:var(--color-surface-2)] px-3 py-1 text-sm text-[color:var(--color-state-conflict)] transition-colors hover:bg-[color:var(--color-surface)] ${FOCUS_RING}`}
            >
              explain conflict
            </button>
          )}
          {explainerOpen && (
            <ConflictExplainer explanation={explanation} onClose={() => setOpenIndex(null)} />
          )}
        </div>
      )}

      <div className="flex flex-col gap-1.5 border-t border-[color:var(--color-border)] pt-4">
        <Counter label="decisions" value={solver.counters.decisions} />
        <Counter label="propagations" value={solver.counters.propagations} />
        <Counter label="backtracks" value={solver.counters.backtracks} />
        <Counter label="conflicts" value={solver.counters.conflicts} />
        {/* The two SAT-only counters, shown only for a SAT-running engine (they would read 0 and
            mislead on a CP solve). Tallied UI-side from the learn/restart events. */}
        {showSatCounters && (
          <>
            <Counter label="learned clauses" value={solver.counters.learnedClauses} />
            <Counter label="restarts" value={solver.counters.restarts} />
          </>
        )}
      </div>

      <div className="border-t border-[color:var(--color-border)] pt-4">
        <Minimap minimap={solver.minimap} />
      </div>

      {solver.solved && (
        <p className="tabular text-sm text-[color:var(--color-state-solved)]">solved</p>
      )}
      {/* The UNSAT result line (the dead-end peer of `solved`): conflict-red with a leading ⊥ glyph
          so the result reads without relying on color alone (VIZ-08), and role=status so a screen
          reader announces it. The "no solution" last-step text in the aria-live region above carries
          the same fact in prose; this is the at-a-glance result the frozen trail otherwise hides. */}
      {solver.unsat && (
        <p role="status" className="tabular text-sm text-[color:var(--color-state-conflict)]">
          <span aria-hidden="true">⊥ </span>unsat — no solution
        </p>
      )}
    </aside>
  );
}

function Counter({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex items-baseline justify-between">
      <span className="text-sm text-[color:var(--color-ink-mute)]">{label}</span>
      <span className="tabular text-base text-[color:var(--color-ink)]">{value}</span>
    </div>
  );
}
