{- | Backtracking search. Propagate to a fixpoint, then either read off the solution (every variable
a singleton), fail the branch (a conflict emptied a domain), or make a decision and try its values.
Backtracking is implicit and free: 'assign' builds a fresh domain map, so the map at the decision
point is untouched and serves as the undo log.

Phase 2 fills the ordering slots (ORDER-01/02/03): the production search selects the
most-constrained variable (smallest domain, MRV) with a degree tie-break, and tries values in
least-constraining order (LCV). Ordering changes how much the search explores, never which answers
are valid. 'searchStats' exposes a decision count and a strategy knob so a test can show MRV cuts
decisions on hard-17 versus the old naive in-order selection.
-}
module Lattice.CP.Search (
  search,
  Strategy (..),
  searchStats,
) where

import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.List (minimumBy, sortOn)
import Data.Ord (comparing)
import Lattice.CP.Propagator (constraintVars)
import Lattice.CP.Queue (propagate)
import Lattice.Core.Domain (assign, domainOf, singletonValue, unassignedVars)
import Lattice.Core.Types (Assignment, Constraint, Domain (..), Domains, Value, Var)

{- | Variable- and value-ordering strategy. 'Naive' is the original first-unassigned + natural-order
selection; 'Mrv' is MRV with a degree tie-break and least-constraining-value ordering.
-}
data Strategy = Naive | Mrv
  deriving (Eq, Show)

-- | Production search: MRV/degree variable selection and LCV value ordering.
search :: [Constraint] -> Domains -> Maybe Assignment
search cs ds = fst (searchStats Mrv cs ds)

{- | Search returning the solution (if any) and the number of decisions taken — each value branch
entered, counting backtracks. The decision count is what makes "MRV reduces search" measurable.
-}
searchStats :: Strategy -> [Constraint] -> Domains -> (Maybe Assignment, Int)
searchStats strat cs ds0 = go ds0 0
 where
  degree = degreeMap cs
  neighbors = neighborMap cs

  go ds !n =
    case propagate cs ds of
      Left _ -> (Nothing, n)
      Right ds' -> case unassignedVars ds' of
        [] -> (Just (readAssignment ds'), n)
        us@(u0 : _) ->
          let x = case strat of
                Naive -> u0
                Mrv -> minimumBy (comparing (mrvKey ds')) us
              vs = case strat of
                Naive -> candidates x ds'
                Mrv -> sortOn (lcvCost ds' x) (candidates x ds')
           in tryValues ds' x vs n

  -- Most-constrained variable: smallest domain, breaking ties toward the highest static degree.
  mrvKey ds' v = (domainSize v ds', negate (IntMap.findWithDefault 0 v degree))

  -- Least-constraining value: how many of x's neighbours still hold v (fewer is preferred).
  lcvCost ds' x v =
    length [u | u <- IntSet.toList (IntMap.findWithDefault IntSet.empty x neighbors), holds v u ds']
  holds v u ds' = case domainOf u ds' of Domain s -> v `IntSet.member` s

  tryValues _ _ [] n = (Nothing, n)
  tryValues ds' x (v : rest) n =
    case go (assign x v ds') (n + 1) of
      (Just a, n') -> (Just a, n')
      (Nothing, n') -> tryValues ds' x rest n'

-- | Read a fully decided map (every domain a singleton) off as an assignment.
readAssignment :: Domains -> Assignment
readAssignment = IntMap.mapMaybe singletonValue

-- | The values still open for a variable.
candidates :: Var -> Domains -> [Value]
candidates x ds = case domainOf x ds of
  Domain s -> IntSet.toList s

-- | The number of values left in a variable's domain.
domainSize :: Var -> Domains -> Int
domainSize x ds = case domainOf x ds of
  Domain s -> IntSet.size s

-- | Variable to the number of constraints that mention it (the degree, for the MRV tie-break).
degreeMap :: [Constraint] -> IntMap.IntMap Int
degreeMap cs = IntMap.fromListWith (+) [(v, 1) | c <- cs, v <- constraintVars c]

-- | Variable to the set of variables sharing a constraint with it (for least-constraining-value).
neighborMap :: [Constraint] -> IntMap.IntMap IntSet.IntSet
neighborMap cs =
  IntMap.fromListWith
    IntSet.union
    [(v, IntSet.fromList (filter (/= v) vars)) | c <- cs, let vars = constraintVars c, v <- vars]
