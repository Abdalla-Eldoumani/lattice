# The design system

The visualizer is editorial-dark: a near-black page, ivory text, one warm ochre accent, a serif
display face over a sans body, and a small set of semantic state colors that each mean a specific
solver state and are used for nothing else. Depth comes from 1px hairline borders and spacing, never
from drop shadows. There is no purple, teal, or cyan.

Every value here is a token in the `@theme` block of
[`web/app/globals.css`](../web/app/globals.css), which is the single source of truth the components
consume. Tailwind v4 is CSS-first, so there is no `tailwind.config.js`; you add or change a token by
editing `@theme`. This document describes those tokens; for how the renderers use them see
[VISUALIZER.md](VISUALIZER.md).

## Color

### Surfaces and ink

The page is a near-black canvas with two slightly lifted surface levels for cards and controls, and
three ink levels for text emphasis. The borders are ivory at low opacity, so a hairline reads as
depth without a shadow.

| Token | Value | Use |
|---|---|---|
| `--color-bg` | `#0e0e0f` | The page canvas. |
| `--color-surface` | `#16161a` | Cards, panels, the grid background. |
| `--color-surface-2` | `#1e1e24` | Controls, the lifted surface inside a card. |
| `--color-border` | `rgba(243, 238, 227, 0.1)` | The hairline border (ivory at 10%). |
| `--color-border-strong` | `rgba(243, 238, 227, 0.18)` | A stronger hairline, and the keyboard focus ring (ivory at 18%). |
| `--color-ink` | `#f3eee3` | Primary text. |
| `--color-ink-dim` | `#b9b2a4` | Secondary text. |
| `--color-ink-mute` | `#7c766b` | Labels and muted detail. |

### The accent

One warm ochre, used for links, active states, and the current decision. It has a dimmed variant for
hover.

| Token | Value | Use |
|---|---|---|
| `--color-accent` | `#e08d3c` | Links, active states, the just-decided cell, the current path in the minimap. |
| `--color-accent-dim` | `#b5712e` | The hover state of an accent control. |

### The semantic state colors

These three colors are semantic, not decorative. Each names one solver state and is used only for
that state — a conflict color never reads as "selected," and a categorical fill never reads as a
state. They are deliberately distinct from the accent. Critically, none of them is ever the only
signal for a state; each pairs with a non-color cue (a glyph, a ring, a strike-through, a band label),
so the solve is legible without color and stays readable with animation off.

| Token | Value | Meaning | Paired non-color cue |
|---|---|---|---|
| `--color-state-conflict` | `#c2553d` | A dead end: an empty domain, a violated clause. | A red flash, a `⊥` glyph, a struck-through variable id, a clashing-edge stroke. |
| `--color-state-solved` | `#5e9e72` | A cell or clause that is settled and correct. | A solved border, a check mark on a queen, the word "solved". |
| `--color-state-propagate` | `#7c766b` | A value being removed by propagation (it fades to this). | A faint × where a nonogram cell can no longer be ink. |

### The graph categorical ramp

The graph view paints each color class a distinct fill from a four-step ramp drawn from the same
palette spirit — warm neutrals and the ochre, no neon. These are categorical fills, not state colors:
a class-red vertex is not "in conflict," so the ramp deliberately avoids the conflict and solved
colors. Color alone never identifies a class either — every colored vertex also carries its numeral
id, and that numeral is the real signal. Each fill holds at least 3:1 contrast against the background;
the numeral reads at 4.5:1 on its fill via a per-fill label color (a dark label on the light fills, the
ivory ink on the dark ones).

| Token | Value | Class |
|---|---|---|
| `--color-graph-1` | `#e08d3c` | Class 1: the accent ochre. |
| `--color-graph-2` | `#b9b2a4` | Class 2: warm grey. |
| `--color-graph-3` | `#8a5a24` | Class 3: a darker ochre. |
| `--color-graph-4` | `#6e6456` | Class 4: a warm taupe. |

The SAT trail view reuses this ramp at low opacity as a per-decision-level band tint. There too the
hue only groups; the `L0` / `L1` band label is what identifies the level.

## Typography

Three families, each loaded through `next/font` in [`web/app/layout.tsx`](../web/app/layout.tsx) and
bound to a CSS variable. A serif display for the wordmark and headings, a geometric sans for the UI,
and a mono for every numeric and code surface (cell candidates, counters, DIMACS, learned clauses).

| Token | Family | Role |
|---|---|---|
| `--font-display` | Fraunces (weights 400, 600), falling back to Georgia, serif | The wordmark, headings, the puzzle digits. |
| `--font-sans` | Inter (weights 400, 500, 600), falling back to system-ui, sans-serif | Body and UI text. |
| `--font-mono` | IBM Plex Mono (weights 400, 500), falling back to ui-monospace, monospace | Numeric and code surfaces. |

The `.tabular` utility class applies the mono family with `font-variant-numeric: tabular-nums`, so
counters and coordinates do not shift the layout as their digits change. Numbers that update live (the
counters, the speed readout, the event position) all use it.

## Spacing and radii

The spacing scale has a 4px base; Tailwind exposes the numeric scale and `@theme` adds two named
aliases for the larger structural steps. Radii are small — the grid is the star, so most surfaces are
nearly square.

| Token | Value |
|---|---|
| `--spacing-section` | `48px` |
| `--spacing-page` | `64px` |
| `--radius-sm` | `2px` |
| `--radius-md` | `4px` |
| `--radius-lg` | `8px` |

## Motion

Durations and easing curves are tokens, so the whole visualizer shares one tunable animation
language. The vocabulary is small: a candidate fades when propagation rules it out, the just-decided
cell pulses, a domain that empties flashes, undone work fades back slower so the eye can follow it.

| Token | Value | Use |
|---|---|---|
| `--ease-standard` | `cubic-bezier(0.2, 0, 0, 1)` | The default ease. |
| `--ease-undo` | `cubic-bezier(0.4, 0, 0.2, 1)` | Work being undone. |
| `--duration-candidate-fade` | `180ms` | A candidate value disappearing from a cell. |
| `--duration-decision-pulse` | `160ms` | The cell a decision just assigned. |
| `--duration-conflict-flash` | `120ms` | The flash when a domain empties. |
| `--duration-backtrack-undo` | `220ms` | Work being undone, slower so the eye follows it. |
| `--duration-color-set` | `180ms` | A graph node taking a color. |

The decision pulse and conflict flash are CSS keyframes keyed to these duration tokens; the candidate
fade is a CSS opacity transition. The only JavaScript-driven animation in the app is the minimap's
node-add tween, which is gated separately (see [VISUALIZER.md](VISUALIZER.md)).

### Reduced motion

A global `@media (prefers-reduced-motion: reduce)` block in `globals.css` collapses every CSS
animation and transition to near-instant. The minimap's one JS tween is gated by a separate matchMedia
hook. Under reduced motion, state still updates on every event; only the in-between movement is
skipped. The solve stays fully legible stepwise — the glyphs, rings, strike-throughs, band labels, and
text read-outs carry the meaning without any motion at all.

## The accessibility contract

Three rules hold across the whole interface, and the headless walkthrough in
[`web/scripts/walkthrough.mjs`](../web/scripts/walkthrough.mjs) checks them.

1. **Color is never the only signal.** Every solver state pairs its color with a non-color cue, as the
   state-color and graph-ramp tables above spell out. The same rule covers color-vision deficiency and
   reduced motion at once.
2. **The solve is legible without animation.** Every animated state has a static, readable form, so a
   user with motion off — or one reading the static screenshots — follows the reasoning step by step.
3. **WCAG AA contrast.** Body and label text meet AA against their surfaces, and each graph fill meets
   at least 3:1 against the background with its numeral at 4.5:1 on the fill. Every interactive control
   carries a visible 2px focus ring (`--color-border-strong`) on keyboard focus, and the modal dialogs
   move focus in on open, trap Tab, and return focus to their trigger on close.
