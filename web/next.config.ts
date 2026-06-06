import type { NextConfig } from "next";

// The visualizer talks to the Haskell server over a WebSocket. In development the server runs
// separately (cabal run lattice-server in WSL, bound to 127.0.0.1) and the browser connects to
// it directly via the URL in web/lib/protocol.ts. WSL2 forwards localhost to the host, so no
// proxy is needed for local dev. Add rewrites here only if you later serve the front end and
// the API from different origins in production.
const nextConfig: NextConfig = {
  reactStrictMode: true,
};

export default nextConfig;
