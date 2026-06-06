{- | Backtracking search, in two modes (EVENT-01). 'searchCore' is the loop generic over the monad:
it propagates (through 'propagateM', so propagation events flow too), makes a decision on the
most-constrained variable, and emits a 'Decision' as it branches, a 'Backtrack' when a branch fails,
and a 'Solution' when every variable is a singleton. 'search' and 'searchStats' are the pure
fast-mode instantiations — @Identity@ with 'noEmit' — which the compiler reduces to the original
allocation-free loop. Ordering changes how much is explored, never which answers are valid.
-}
module Lattice.CP.Search (
  search,
  Strategy (..),
  searchStats,
  searchCore,
) where

import Data.Functor.Identity (runIdentity)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.List (minimumBy, sortOn)
import Data.Ord (comparing)
import Lattice.CP.Propagator (constraintVars)
import Lattice.CP.Queue (propagateM)
import Lattice.Core.Domain (assign, domainOf, singletonValue, unassignedVars)
import Lattice.Core.Types (Assignment, Constraint, Domain (..), Domains, Value, Var)
import Lattice.Event qualified as Ev

{- | Variable- and value-ordering strategy. 'Naive' is first-unassigned + natural order; 'Mrv' is
MRV with a degree tie-break and least-constraining-value ordering.
-}
data Strategy = Naive | Mrv
  deriving (Eq, Show)

-- | Production search: MRV/degree variable selection and LCV value ordering, fast mode.
search :: [Constraint] -> Domains -> Maybe Assignment
search cs ds = fst (runIdentity (searchCore Ev.noEmit Mrv cs ds))
{-# INLINE search #-}

{- | Search returning the solution (if any) and the decision count, fast mode. Used to measure that
MRV reduces decisions versus naive ordering.
-}
searchStats :: Strategy -> [Constraint] -> Domains -> (Maybe Assignment, Int)
searchStats strat cs ds = runIdentity (searchCore Ev.noEmit strat cs ds)

{- | The search loop generic over the monad. Returns the solution (if any) and the decision count,
and emits the decision/propagate/conflict/backtrack/solution stream as it runs.
-}
searchCore
  :: (Monad m) => Ev.Emit m -> Strategy -> [Constraint] -> Domains -> m (Maybe Assignment, Int)
searchCore emit strat cs ds0 = go ds0 0 0
 where
  degree = degreeMap cs
  neighbors = neighborMap cs

  go ds level n = do
    r <- propagateM emit cs ds
    case r of
      Left _ -> pure (Nothing, n)
      Right ds' -> case unassignedVars ds' of
        [] ->
          let asn = readAssignment ds'
           in emit (Ev.Solution (IntMap.toList asn)) >> pure (Just asn, n)
        us@(u0 : _) ->
          let x = case strat of
                Naive -> u0
                Mrv -> minimumBy (comparing (mrvKey ds')) us
              vs = case strat of
                Naive -> candidates x ds'
                Mrv -> sortOn (lcvCost ds' x) (candidates x ds')
           in tryValues ds' level x vs n

  mrvKey ds' v = (domainSize v ds', negate (IntMap.findWithDefault 0 v degree))

  lcvCost ds' x v =
    length [u | u <- IntSet.toList (IntMap.findWithDefault IntSet.empty x neighbors), holds v u ds']
  holds v u ds' = case domainOf u ds' of Domain s -> v `IntSet.member` s

  tryValues _ _ _ [] n = pure (Nothing, n)
  tryValues ds' level x (v : rest) n = do
    emit (Ev.Decision x v level)
    (res, n') <- go (assign x v ds') (level + 1) (n + 1)
    case res of
      Just a -> pure (Just a, n')
      Nothing -> emit (Ev.Backtrack level) >> tryValues ds' level x rest n'
{-# INLINEABLE searchCore #-}

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
