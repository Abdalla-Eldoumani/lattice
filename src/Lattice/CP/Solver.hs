{- | The CP entry point in both modes (CORE-05, EVENT-01). 'solve' is fast mode: propagate the
seeded givens to a fixpoint and search, with no events. 'solveTrace' is the same engine threaded
with an 'Emit' callback, so a caller (the trace server) receives the decision/propagate/conflict/
backtrack/solution stream. A contradictory givens set fails the initial fixpoint and yields
'NoSolution' in both modes.
-}
module Lattice.CP.Solver (
  solve,
  solveTrace,
) where

import Lattice.CP.Search (Strategy (Mrv), search, searchCore)
import Lattice.Core.Types (Model (..), Result (..))
import Lattice.Event (Emit)

-- | Solve a model in fast mode: 'Solved' with an assignment, or a sound 'NoSolution'.
solve :: Model -> Result
solve model = maybe NoSolution Solved (search (modelConstraints model) (modelDomains model))

{- | Solve a model in trace mode, emitting events as the engine reasons. The result is the same as
'solve'; the difference is the stream the emit callback receives.
-}
solveTrace :: (Monad m) => Emit m -> Model -> m Result
solveTrace emit model = do
  (res, _) <- searchCore emit Mrv (modelConstraints model) (modelDomains model)
  pure (maybe NoSolution Solved res)
