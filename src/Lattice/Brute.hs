{- | The brute-force reference solver: a plain backtracking enumerator used only by the tests. It
imports no CP or SAT engine module on purpose — its independence from the propagator, queue, search,
and the CDCL loop is exactly what makes the differential tests meaningful. The only concession to
tractability is most-constrained-variable ordering (pick the unassigned cell with the fewest
still-consistent values next). That is ordering ONLY: it enumerates the identical set of solutions,
shares no inference with the CP engine, and keeps the consistency check trivially correct — so the
oracle stays "too simple to be wrong" while still finishing a 9x9 and N=8 queens quickly.

The CNF oracle ('satisfiableCNF' / 'solveAllCNF') is the same posture for SAT: a plain @2^n@
truth-table enumerator over the variable count, checking every clause directly. It imports only the
pure 'Lattice.SAT.Types' data type — no SAT engine module — so it shares no inference with the CDCL
solver and is a sound independent reference for the three-way differential.
-}
module Lattice.Brute (
  solveFirst,
  solveAll,
  satisfiableCNF,
  solveAllCNF,
) where

import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.List (group, minimumBy)
import Data.Maybe (mapMaybe)
import Data.Ord (comparing)
import Lattice.Core.Types (Assignment, Constraint (..), Domain (..), Model (..), Value, Var)
import Lattice.SAT.Types (CNF (..), litPos, litVar)

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
  satisfied asn (LineClue vars clue) =
    case traverse (`IntMap.lookup` asn) vars of
      -- Partial-assignment convention (like SumEq): a not-fully-assigned line passes.
      Nothing -> True
      Just bits -> runs bits == clue

-- | Are all of these (already-assigned) values pairwise distinct?
distinct :: [Value] -> Bool
distinct xs = IntSet.size (IntSet.fromList xs) == length xs

{- | The run lengths of the maximal blocks of 1s in a 0/1 line, in order. Derived directly from the
assignment, independent of the propagator, so the differential check stays meaningful.
-}
runs :: [Value] -> [Int]
runs line = [length g | g@(b : _) <- group line, b == 1]

{- | Is the CNF satisfiable? The exhaustive @2^n@ oracle: enumerate every truth assignment over the
declared variables and return 'True' iff some assignment satisfies every clause. Too simple to be
wrong, and independent of the SAT engine, which is the whole point.
-}
satisfiableCNF :: CNF -> Bool
satisfiableCNF cnf = not (null (solveAllCNF cnf))

{- | Every satisfying truth assignment of the CNF, each a list of polarities indexed by variable
(@0 .. cnfVars - 1@). Enumerates all @2^n@ assignments and keeps those where every clause has at
least one true literal. Tiny instances only — that is what the oracle is for.
-}
solveAllCNF :: CNF -> [[Bool]]
solveAllCNF cnf = filter sat (allAssignments (cnfVars cnf))
 where
  sat asn = all (clauseSat asn) (cnfClauses cnf)
  -- A clause holds when some literal agrees with the assignment: a positive literal on a true var,
  -- or a negative literal on a false var.
  clauseSat asn = any (\lit -> (asn !! litVar lit) == litPos lit)

-- | Every boolean assignment over @n@ variables (@2^n@ of them), as polarity lists indexed by var.
allAssignments :: Int -> [[Bool]]
allAssignments n
  | n <= 0 = [[]]
  | otherwise = [b : rest | b <- [False, True], rest <- allAssignments (n - 1)]
