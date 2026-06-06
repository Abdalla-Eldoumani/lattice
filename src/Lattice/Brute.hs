{- | The brute-force reference solver: a plain backtracking enumerator used only by the tests. It
imports no CP engine module on purpose — its independence from the propagator, queue, and search is
exactly what makes the differential test meaningful. The only concession to tractability is
most-constrained-variable ordering (pick the unassigned cell with the fewest still-consistent values
next). That is ordering ONLY: it enumerates the identical set of solutions, shares no inference with
the CP engine, and keeps the consistency check trivially correct — so the oracle stays "too simple to
be wrong" while still finishing a 9x9 and N=8 queens quickly.
-}
module Lattice.Brute (
  solveFirst,
  solveAll,
) where

import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.List (minimumBy)
import Data.Maybe (mapMaybe)
import Data.Ord (comparing)
import Lattice.Core.Types (Assignment, Constraint (..), Domain (..), Model (..), Value, Var)

{- | The first satisfying assignment, or 'Nothing' if the model is unsatisfiable. Lazy: it forces
only the head of 'solveAll', so a satisfiable instance stops at the first solution.
-}
solveFirst :: Model -> Maybe Assignment
solveFirst model = case solveAll model of
  (a : _) -> Just a
  [] -> Nothing

{- | Every satisfying assignment, by exhaustive backtracking enumeration over the model's domains.
At each step it branches on the most-constrained unassigned variable and tries only values
consistent with the partial assignment, so dead branches die immediately.
-}
solveAll :: Model -> [Assignment]
solveAll model = go (IntMap.keys doms) IntMap.empty
 where
  doms = modelDomains model
  cons = modelConstraints model

  go :: [Var] -> Assignment -> [Assignment]
  go [] asn = [asn]
  go unassigned asn =
    let v = minimumBy (comparing (length . candidates asn)) unassigned
        rest = filter (/= v) unassigned
     in concatMap (\x -> go rest (IntMap.insert v x asn)) (candidates asn v)

  -- \| Values for @v@ that do not violate any constraint given the current assignment.
  candidates :: Assignment -> Var -> [Value]
  candidates asn v = filter (\x -> consistent (IntMap.insert v x asn)) (valuesOf v)

  valuesOf v = case IntMap.lookup v doms of
    Just (Domain s) -> IntSet.toList s
    Nothing -> []

  consistent asn = all (satisfied asn) cons

  satisfied asn (NotEqual a b) =
    case (IntMap.lookup a asn, IntMap.lookup b asn) of
      (Just va, Just vb) -> va /= vb
      _ -> True
  satisfied asn (AllDifferent vars) =
    let assigned = mapMaybe (`IntMap.lookup` asn) vars
     in distinct assigned
  satisfied asn (AllDiffOffset pairs) =
    let assigned = mapMaybe (\(v, off) -> (+ off) <$> IntMap.lookup v asn) pairs
     in distinct assigned
  satisfied asn (LessEq a b) =
    case (IntMap.lookup a asn, IntMap.lookup b asn) of
      (Just va, Just vb) -> va <= vb
      _ -> True
  satisfied asn (SumEq vars c) =
    let assigned = mapMaybe (`IntMap.lookup` asn) vars
     in length assigned < length vars || sum assigned == c

-- | Are all of these (already-assigned) values pairwise distinct?
distinct :: [Value] -> Bool
distinct xs = IntSet.size (IntSet.fromList xs) == length xs
