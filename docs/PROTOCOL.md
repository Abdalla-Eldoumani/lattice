# The event and control protocol

This is the wire protocol between the engine and the web client: the contract that lets the browser
animate a solve it is not running. The engine (in trace mode) emits a stream of **events** describing
each step of its reasoning; the client sends **control** messages to start a solve and drive its
playback. Both directions are JSON, and both sides of the contract are maintained by hand in lockstep:
the Haskell definitions in `src/Lattice/Event.hs` and `src/Lattice/Protocol.hs`, and the TypeScript
mirror in `web/lib/protocol.ts`. A change on one side is a change on both, in the same commit.

For where the events come from, see [CP-ENGINE.md](CP-ENGINE.md) and [SAT-ENGINE.md](SAT-ENGINE.md).
For how the browser consumes them, see [VISUALIZER.md](VISUALIZER.md). For how the streaming server
runs underneath, see [ARCHITECTURE.md](ARCHITECTURE.md).

## The shape: versioned and tagged

Every message is one JSON object carrying two fields:

- `v` — the protocol version, a fixed integer (currently `1`).
- `t` — a string tag naming the message kind (`"decision"`, `"propagate"`, `"start"`, and so on).

The remaining fields depend on the tag. The version is checked on receipt: the client's `parseEvent`
returns `null` for a message whose `v` does not match `PROTOCOL_VERSION`, so a protocol bump fails
loudly rather than rendering garbage.

### Puzzle coordinates, never solver ids

The single most important convention: **payloads speak puzzle coordinates, not internal solver ids.**
An event names a Sudoku cell index, a graph vertex id, a board variable — the thing the renderer can
draw — never the engine's internal variable encoding. For the CP puzzles the cell index *is* the
variable index, so the mapping is the identity; for SAT the cell is the SAT variable. The one place
this is non-trivial is a learned clause, whose literals are emitted as signed 1-based variable ids
(the DIMACS convention), never the internal `2*var+sign` literal code. The engine does the translation
at the emit boundary so a client never needs to know how the solver represents anything internally.

## Server to client: events

The events are the `Event` ADT in `src/Lattice/Event.hs`, with `ToJSON`/`FromJSON` instances, mirrored
by the discriminated union in `web/lib/protocol.ts`. The CP engine emits the first five plus `stats`;
`learn` and `restart` are SAT-specific.

| Tag | Fields | Meaning |
|---|---|---|
| `decision` | `cell`, `value`, `level` | the search assigned `value` to `cell` at the given decision level |
| `propagate` | `cell`, `removed` | `removed` was eliminated from `cell`'s domain (for SAT, a forced literal) |
| `conflict` | `cell` | a domain emptied at `cell` (for SAT, a falsified clause's variable) |
| `backtrack` | `level` | the search undid the decision at `level` (for SAT, the backjump target) |
| `learn` | `clause` | a SAT 1UIP learned clause, its literals as signed variable ids |
| `restart` | — | a SAT restart fired: the trail unwound to level 0, clauses and activities kept |
| `solution` | `assignment` | a full solution as `cell`/`value` pairs |
| `unsat` | — | a sound proof that no solution exists |
| `stats` | `decisions`, `propagations`, `backtracks`, `conflicts` | the running counters |

A few notes on the field choices, grounded in the Haskell encoders:

- `decision` carries `cell`, `value`, `level`; `propagate` carries `cell` and `removed` (the value
  taken away). The Haskell `Propagate Var Value` encodes `Value` under the key `removed`, because a
  propagation removes a value rather than assigning one.
- `solution`'s `assignment` is a list of `[cell, value]` pairs.
- `stats` keeps exactly four counters. The SAT-specific `learnedClauses` and `restarts` totals are
  *not* added to it; the client derives them by tallying the `learn` and `restart` events instead.
  This keeps `stats` at its original arity so the round-trip stays stable rather than positionally
  widening.

### The per-event engine tag

Every event optionally carries an `engine` field — `"cp"` or `"sat"` — that the server stamps on. It
exists so a CP-vs-SAT race, whose two interleaved streams arrive over one socket, can be split into
two panels by routing each event by its tag. On a single-engine stream the field is absent. It is
additive: a client that ignores it sees a correct single stream, and the protocol stays at version 1.
In the TypeScript mirror it appears as `engine?: Engine` on every event interface.

## Client to server: control

The control messages are the `Control` ADT in `src/Lattice/Protocol.hs`, mirrored by the
`SolverControl` union in `web/lib/protocol.ts`. They share the same versioned, tagged shape.

| Tag | Fields | Meaning |
|---|---|---|
| `start` | `kind`, `puzzle`, `mode`, `engine` | begin a solve of the given puzzle definition |
| `step` | — | advance the trace one event |
| `play` | `speed` | play the trace at `speed` events per second |
| `pause` | — | pause playback |
| `restart` | — | restart the current solve |

`start` is the rich one. Its fields:

- `kind` — which encoder the server routes the definition to: `"sudoku"`, `"graph"`, `"queens"`,
  `"nonogram"`, or `"dimacs"`. (`dimacs` carries raw CNF text for the SAT engine.)
- `puzzle` — the raw puzzle definition text the server parses (a Sudoku grid, a graph or nonogram JSON
  blob, raw DIMACS).
- `mode` — `"trace"` (stream events, can single-step) or `"fast"`.
- `engine` — which solver runs: `"cp"`, `"sat"`, or `"race"` (run CP and SAT side by side on a
  dual-encodable instance).

## Kept in lockstep, versioned additively

The Haskell `Event`/`Control` types and the TypeScript types in `web/lib/protocol.ts` are the same
contract written twice, and they must change together in one commit. The rule for evolving the
protocol is **additive versioning**: the version stays `1`, and new fields and event kinds are added
without breaking old consumers.

Two mechanisms make this hold:

- **Defaulted optional fields.** On the Haskell side, `start`'s `kind` and `engine` fields are decoded
  with `.:? ... .!= default` (`"sudoku"` and `"cp"` respectively), so a message sent before those
  fields existed still decodes. On the TypeScript side the same fields are optional.
- **Tallied rather than widened.** Rather than add `learnedClauses`/`restarts` counters to `stats`
  (which would change its positional arity and break the round-trip), the SAT counters are derived
  client-side from the `learn`/`restart` events.

The `learn` and `restart` events and the `engine` start field are exactly this kind of additive
extension: they were added for the SAT engine without bumping `protocolVersion`, which is still `1`.
Round-trip property tests on the Haskell side cover the encode/decode of every constructor, including
the additions.

## How SAT reuses the event shape

The SAT engine does not invent a new event vocabulary. It reuses the existing `cell`/`value`/`level`
shape by convention:

- `cell` is the SAT **variable** id;
- `value` is the **polarity** (0 or 1);
- `level` is the decision level.

So a SAT decision is a `decision` event whose `cell` is the branched variable and whose `value` is the
chosen polarity. A forced literal — both a unit-propagation consequence and the asserting literal the
solver enqueues after a backjump — is a `propagate` event with the variable as `cell` and its polarity
as the removed `value`. A conflict names the conflict variable; a backtrack names the
non-chronological backjump level. The two genuinely new events are `learn` (the 1UIP clause, as signed
variable ids) and `restart` (nullary). Reusing the shape is why the same renderers and replay logic
handle both engines with only small SAT-specific additions; the details of how the trail view reads
these are in [VISUALIZER.md](VISUALIZER.md).
