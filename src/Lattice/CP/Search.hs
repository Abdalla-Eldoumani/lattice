{- | Backtracking search (CORE-04). Propagate to a fixpoint, then either read off the solution
(every variable a singleton), fail the branch (a conflict emptied a domain), or make a decision on
the first unassigned variable and try its values in turn. Backtracking is implicit and free:
'assign' builds a fresh domain map, so the map at the decision point is untouched and serves as the
undo log. M1 selects variables and values in the simplest order; the slots where MRV/degree and LCV
land in Phase 2 are marked.
-}
module Lattice.CP.Search (
  search,
) where

import Data.Foldable (asum)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Lattice.CP.Queue (propagate)
import Lattice.Core.Domain (assign, domainOf, singletonValue, unassignedVars)
import Lattice.Core.Types (Assignment, Constraint, Domain (..), Domains, Value, Var)

-- | Solve from a partial domain map, or 'Nothing' if this branch has no solution.
search :: [Constraint] -> Domains -> Maybe Assignment
search cs ds =
  case propagate cs ds of
    Left _ -> Nothing
    Right ds' -> case unassignedVars ds' of
      [] -> Just (readAssignment ds')
      -- selectVar slot: first unassigned variable in index order (MRV/degree is Phase 2).
      (x : _) ->
        -- candidates slot: domain values in natural order (LCV is Phase 2).
        asum [search cs (assign x v ds') | v <- candidates x ds']

-- | Read a fully decided map (every domain a singleton) off as an assignment.
readAssignment :: Domains -> Assignment
readAssignment = IntMap.mapMaybe singletonValue

-- | The values still open for a variable, in ascending (natural) order.
candidates :: Var -> Domains -> [Value]
candidates x ds = case domainOf x ds of
  Domain s -> IntSet.toList s
