-- | Top-level entry point for the solver library. As engine modules land
-- (see lattice.cabal for the target module map) re-export the stable public
-- surface from here so callers import @Lattice@ rather than internal modules.
module Lattice
  ( version,
  )
where

-- | Library version, surfaced by the CLI and (later) the server banner.
version :: String
version = "0.1.0.0"
