# Deployment

How to deploy the visualizer and run the engine behind it. For building and running both locally,
see [DEVELOPMENT.md](DEVELOPMENT.md); for how the pieces fit together, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## The split: a hostable front end, a separate engine

lattice has two deployable parts with different shapes, and the difference is the whole story of
deploying it:

- **The visualizer** (`web/`) is a Next.js app — a static and server-rendered front end. It holds no
  solver state; it connects to an engine over a WebSocket and animates whatever events arrive. It
  hosts cleanly on a platform like Vercel.
- **The engine** is the Haskell `lattice-server`. It is a stateful, long-running WebSocket server: it
  holds the solve thread, the step gate, and the per-connection session state, and it streams events
  as a solve progresses. It is **not serverless** and cannot be deployed as a serverless function. It
  runs as its own process — locally, or on a host you control.

So the front end deploys like any Next.js app, and the engine runs separately. The deployed page
connects to the engine over a WebSocket; the two are joined only by that connection.

## The connection

The front end reads the engine's address from `web/lib/protocol.ts`:

```ts
export const SOLVER_WS_URL =
  process.env.NEXT_PUBLIC_SOLVER_WS ?? "ws://127.0.0.1:8080/ws";
```

The default, `ws://127.0.0.1:8080/ws`, is the local engine. For a hosted front end, set
`NEXT_PUBLIC_SOLVER_WS` to your engine's address. (It is a `NEXT_PUBLIC_` variable because the
browser, not the server, opens the socket, so the value is baked into the client bundle at build
time.)

### The local-engine model

There is a convenient deployment that needs no hosted engine at all. Browsers treat
`ws://127.0.0.1` and `ws://localhost` as a secure-context exception — a page served over HTTPS is
normally blocked from opening a plaintext `ws://` connection, but loopback is exempt. So a viewer who
runs `lattice-server` on their own machine can point a hosted HTTPS front end at their local engine:
the deployed page talks to the viewer's own loopback server. With the default
`NEXT_PUBLIC_SOLVER_WS`, a hosted build already does this — anyone running the engine locally can use
the hosted page.

### A fully hosted demo

For a demo that needs no local engine, run `lattice-server` on a host reachable over a secure
WebSocket (`wss://`) and set `NEXT_PUBLIC_SOLVER_WS` to that address (for example
`wss://engine.example.com/ws`). A hosted HTTPS page cannot open a plaintext `ws://` connection to a
non-loopback host, so a remote engine must be reached over `wss://` — see the reverse-proxy note
below.

## Hosting the front end on Vercel

The front end is a standard Next.js app and Vercel auto-detects it. Two things to know:

- **Root Directory.** The application lives in the `web/` subdirectory, not the repository root. Set
  the Vercel project's Root Directory to `web` so it builds the app and not the repository root.
- **Build and output.** These are the Next.js defaults; there is nothing to override. The build
  command and output directory are detected automatically.

`web/vercel.json` carries the security headers and asset-caching rules for the deployed app. It is
applied automatically on deploy; you do not configure it in the Vercel dashboard.

The one thing to configure is the engine address: set `NEXT_PUBLIC_SOLVER_WS` in the Vercel project's
environment variables. Leave it unset to ship the local-engine default (the hosted page talks to each
viewer's own loopback engine); set it to a `wss://` address to point at a hosted engine.

## Running the engine for a demo

Locally, the engine is one command (run it in WSL, as the engine builds there):

```bash
cabal run lattice-server          # binds 127.0.0.1:8080
```

It binds the loopback interface on port 8080. WSL2 forwards localhost, so a browser on the Windows
host reaches it at `127.0.0.1:8080` with no extra setup.

For a remote engine that a hosted front end can reach, do not expose the plaintext server to the
public internet. Put `lattice-server` behind a TLS-terminating reverse proxy (for example nginx or
Caddy) that accepts `wss://` from the browser and forwards the upgraded WebSocket to the engine's
local `127.0.0.1:8080`. Then point `NEXT_PUBLIC_SOLVER_WS` at the proxy's `wss://` address. The
engine itself stays bound to loopback; the proxy owns TLS and the public address.

## Summary

- The front end is hostable (Vercel, Root Directory `web`); the engine is a separate long-running
  process, not serverless.
- The front end finds the engine through `NEXT_PUBLIC_SOLVER_WS`, defaulting to the local engine at
  `ws://127.0.0.1:8080/ws`.
- A hosted HTTPS page can talk to a viewer's local engine over loopback (the secure-context
  exception) or to a remote engine over `wss://` behind a TLS-terminating reverse proxy.
