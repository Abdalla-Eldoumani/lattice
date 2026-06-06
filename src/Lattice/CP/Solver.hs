{- | The CP entry point (CORE-05), fast mode only — no events in M1. It propagates the seeded
givens to a fixpoint and searches; a contradictory givens set fails that initial fixpoint and
yields 'NoSolution' rather than a crash. The shape is deliberate: Phase 3 threads an @Emit m@ over
@PrimMonad m@ through 'search' without changing this caller.
-}
module Lattice.CP.Solver (
  solve,
) where

import Lattice.CP.Search (search)
import Lattice.Core.Types (Result (..))
import Lattice.Encode.Sudoku (Model (..))

-- | Solve a model: 'Solved' with an assignment, or a sound 'NoSolution'.
solve :: Model -> Result
solve model = maybe NoSolution Solved (search (modelConstraints model) (modelDomains model))
