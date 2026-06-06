{- | Top-level entry point for the solver library. Callers import @Lattice@ and get the stable
public surface — the solver, the result type, and the Sudoku encoder — rather than reaching into
internal modules. As later milestones land (the event stream, more encoders, the SAT engine) their
public pieces are re-exported here.
-}
module Lattice (
  version,
  solve,
  Result (..),
  parseGrid,
  toModel,
  decode,
  ParseError (..),
) where

import Lattice.CP.Solver (solve)
import Lattice.Core.Types (Result (..))
import Lattice.Encode.Sudoku (ParseError (..), decode, parseGrid, toModel)

-- | Library version, surfaced by the CLI and (later) the server banner.
version :: String
version = "0.1.0.0"
