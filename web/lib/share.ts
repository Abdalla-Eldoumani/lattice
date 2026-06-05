// Shareable permalinks: encode the viewer's current instance (puzzle kind, engine, raw definition)
// into a URL so opening that URL reproduces exactly what they were looking at, with no server or
// database. The link is fully self-contained.
//
// Why the hash, not a query string: this app has no server route that reads a request — it renders a
// client component and talks to the engine over a WebSocket. A hash (`#share=...`) is read entirely
// client-side after mount, never reaches the (static) server, and so adds no round-trip and leaks
// nothing into server logs. We read it in an effect, after hydration, to avoid an SSR mismatch.
//
// Why base64url of a compact JSON: the definition is one of three very different string shapes — a
// Sudoku grid with newlines, a JSON graph/nonogram blob with braces and quotes, or raw DIMACS text.
// Wrapping `{ k, e, d }` in JSON and base64url-encoding it keeps every shape intact and URL-safe in
// one path (no per-kind escaping), and base64url (`-`/`_`, no `=` padding) survives a bare hash.

import type { Engine, PuzzleKind } from "./protocol";

// The hash key the permalink lives under (`#share=<payload>`). Namespaced so the app could add other
// hash params later without colliding.
export const SHARE_HASH_KEY = "share";

// A hard cap on the encoded payload so a hand-edited or hostile hash can never feed the decoder an
// unbounded string to parse. The largest real definition (the hard graph JSON) is well under 2 KB;
// 16 KB of base64 is generous headroom for any fixture while still bounding the work. An oversized
// hash is treated as malformed and ignored.
const MAX_PAYLOAD_LENGTH = 16_384;

// The decoded selection a permalink carries. The same three fields `solver.start` needs.
export interface SharedSelection {
  kind: PuzzleKind;
  engine: Engine;
  definition: string;
}

// The compact on-wire shape: short keys to keep the base64 short. `k` kind, `e` engine, `d` definition.
interface SharePayload {
  k: string;
  e: string;
  d: string;
}

// The valid kinds/engines, mirrored from protocol.ts. A decoded value outside these sets is rejected
// (the caller falls back to a default) so the picker and the server never see a kind/engine they would
// not route. Kept as runtime sets because TypeScript's union types do not exist at runtime.
const KINDS: ReadonlySet<string> = new Set<PuzzleKind>([
  "sudoku",
  "graph",
  "queens",
  "nonogram",
  "dimacs",
]);
const ENGINES: ReadonlySet<string> = new Set<Engine>(["cp", "sat", "race"]);

// base64 -> base64url: `+`->`-`, `/`->`_`, drop `=` padding (the padding is redundant for decode and
// `=` is awkward in a bare URL hash).
function toBase64Url(b64: string): string {
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// base64url -> base64: reverse the swaps and restore padding to a multiple of 4 so atob accepts it.
function fromBase64Url(b64url: string): string {
  const b64 = b64url.replace(/-/g, "+").replace(/_/g, "/");
  const pad = b64.length % 4;
  return pad === 0 ? b64 : b64 + "=".repeat(4 - pad);
}

// UTF-8-safe base64: btoa is Latin1-only, and a definition can carry non-ASCII (it is arbitrary text),
// so round-trip through TextEncoder/TextDecoder. Runs only in the browser (encode is called from a
// click handler, decode from a mount effect), where btoa/atob and Text{En,De}coder always exist.
function utf8ToBase64(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function base64ToUtf8(b64: string): string {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder().decode(bytes);
}

// Encode a selection into the base64url payload that goes after `#share=`. Total, deterministic, and
// never throws for the values the picker produces.
export function encodeShare(selection: SharedSelection): string {
  const payload: SharePayload = {
    k: selection.kind,
    e: selection.engine,
    d: selection.definition,
  };
  return toBase64Url(utf8ToBase64(JSON.stringify(payload)));
}

// Build the full permalink for a selection against the current page origin+path, putting the payload
// in the hash. Keeps any existing search string; replaces the hash.
export function buildShareUrl(selection: SharedSelection, base: URL): string {
  const url = new URL(base.toString());
  url.hash = `${SHARE_HASH_KEY}=${encodeShare(selection)}`;
  return url.toString();
}

// Decode a `#share=...` payload back into a validated selection, or null if it is missing, malformed,
// oversized, or carries an invalid kind/engine. Totally defensive: every failure mode (no hash, wrong
// key, bad base64, non-JSON, wrong shape, unknown kind/engine) returns null so the caller falls back to
// a safe default rather than crashing the page or sending the server garbage. The definition itself is
// passed through opaquely — the server parses and validates it, and a bad definition there fails the
// same way a hand-typed one would, never crashing the client.
export function decodeShare(hash: string): SharedSelection | null {
  // A hash may arrive with or without a leading "#". Strip it, then read only our namespaced key.
  const raw = hash.startsWith("#") ? hash.slice(1) : hash;
  if (!raw) return null;
  const params = new URLSearchParams(raw);
  const payload = params.get(SHARE_HASH_KEY);
  if (!payload) return null;
  if (payload.length > MAX_PAYLOAD_LENGTH) return null;

  let json: string;
  try {
    json = base64ToUtf8(fromBase64Url(payload));
  } catch {
    return null; // not valid base64
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    return null; // not valid JSON
  }

  if (typeof parsed !== "object" || parsed === null) return null;
  const { k, e, d } = parsed as Record<string, unknown>;
  if (typeof k !== "string" || typeof e !== "string" || typeof d !== "string") return null;
  if (!KINDS.has(k) || !ENGINES.has(e)) return null;

  return { kind: k as PuzzleKind, engine: e as Engine, definition: d };
}
