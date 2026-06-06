{-# LANGUAGE TupleSections #-}

{- | The pruning core. CORE-02 ships the value-elimination all-different and the binary not-equal;
CORE-06 adds the sum and comparison (bounds) propagators; Phase 2 also adds offset-all-different for
the three-line N-queens encoding. A propagator runs one pass over the domains and reports which
variables shrank (so the queue re-enqueues exactly their watchers) and whether any domain emptied (a
conflict). Soundness lives here: every removal is justified by the constraint, so no value belonging
to a real solution is ever removed — the sound-propagation property test mechanizes this for each.
-}
module Lattice.CP.Propagator (
  PropResult (..),
  propagateConstraint,
  constraintVars,
) where

import Data.IntSet qualified as IntSet
import Data.Maybe (mapMaybe)
import Lattice.Core.Domain (domainOf, isEmpty, removeValue, singletonValue)
import Lattice.Core.Types (Constraint (..), Domain (..), Domains, Value, Var)

{- | The outcome of one constraint's propagation pass. 'Changed' reports the variables whose
domains actually shrank plus the updated map; 'Conflict' means some domain became empty.
-}
data PropResult
  = Changed [Var] Domains
  | Unchanged
  | Conflict Var
  deriving (Eq, Show)

-- | Run one constraint over the current domains, reporting the real shrinks and any conflict.
propagateConstraint :: Constraint -> Domains -> PropResult
propagateConstraint (AllDifferent vars) ds =
  -- Value elimination: each variable pinned to {v} removes v from its peers. Sound but weak
  -- (not even arc-consistent), which is the right starting point.
  -- >>> REGIN UPGRADE SLOT <<<
  -- (A matching-based all-different propagator would replace this elimination with Hall-set
  -- reasoning for full arc-consistency; the elimination below is the slot it supersedes.)
  let pins = mapMaybe (\x -> (,) x <$> singletonValue (domainOf x ds)) vars
      (ds', shrunk) = foldl' applyPin (ds, []) pins
   in finalize vars ds' shrunk
 where
  applyPin acc (x, v) = foldl' (removeOther x v) acc vars
  removeOther x v (curDs, sh) y
    | y == x = (curDs, sh)
    | domainOf y next /= domainOf y curDs = (next, y : sh)
    | otherwise = (curDs, sh)
   where
    next = removeValue v y curDs
propagateConstraint (NotEqual a b) ds =
  let dsA = maybe ds (\v -> removeValue v b ds) (singletonValue (domainOf a ds))
      dsB = maybe dsA (\w -> removeValue w a dsA) (singletonValue (domainOf b dsA))
      shrunk = [y | y <- [a, b], domainOf y dsB /= domainOf y ds]
   in finalize [a, b] dsB shrunk
propagateConstraint (AllDiffOffset pairs) ds =
  -- Generalised value elimination over offsets: each pinned (v, off) forbids the value v+off, so a
  -- peer (u, off') must not take v + off - off'. With offsets 0/i/-i this is N-queens columns and
  -- both diagonals in three constraints.
  let pins = mapMaybe (\(v, off) -> (v,off,) <$> singletonValue (domainOf v ds)) pairs
      (ds', shrunk) = foldl' applyPin (ds, []) pins
   in finalize (map fst pairs) ds' shrunk
 where
  applyPin acc (vi, offi, x) = foldl' (removeFor vi offi x) acc pairs
  removeFor vi offi x (curDs, sh) (vj, offj)
    | vj == vi = (curDs, sh)
    | domainOf vj next /= domainOf vj curDs = (next, vj : sh)
    | otherwise = (curDs, sh)
   where
    next = removeValue (x + offi - offj) vj curDs
propagateConstraint (SumEq vars c) ds =
  case filter (\v -> isEmpty (domainOf v ds)) vars of
    (v : _) -> Conflict v
    [] ->
      let (ds', shrunk) = foldl' tighten (ds, []) vars
       in finalize vars ds' shrunk
 where
  -- A variable's value is pinned between c minus the most and c minus the least the others can be.
  lo v = c - sum [domMax (domainOf u ds) | u <- vars, u /= v]
  hi v = c - sum [domMin (domainOf u ds) | u <- vars, u /= v]
  tighten (curDs, sh) v =
    let Domain s = domainOf v curDs
        bad = IntSet.filter (\x -> x < lo v || x > hi v) s
     in if IntSet.null bad
          then (curDs, sh)
          else (IntSet.foldr (`removeValue` v) curDs bad, v : sh)
propagateConstraint (LessEq a b) ds
  | isEmpty (domainOf a ds) = Conflict a
  | isEmpty (domainOf b ds) = Conflict b
  | otherwise =
      let Domain sa = domainOf a ds
          Domain sb = domainOf b ds
          badA = IntSet.filter (> domMax (domainOf b ds)) sa
          badB = IntSet.filter (< domMin (domainOf a ds)) sb
          ds1 = IntSet.foldr (`removeValue` a) ds badA
          ds2 = IntSet.foldr (`removeValue` b) ds1 badB
          shrunk = [a | not (IntSet.null badA)] ++ [b | not (IntSet.null badB)]
       in finalize [a, b] ds2 shrunk

{- | Classify the pass: any emptied domain is a 'Conflict'; otherwise report real shrinks (with
duplicates removed) as 'Changed', or 'Unchanged' when nothing moved.
-}
finalize :: [Var] -> Domains -> [Var] -> PropResult
finalize vars ds' shrunk = case filter (\y -> isEmpty (domainOf y ds')) vars of
  (y : _) -> Conflict y
  []
    | null shrunk -> Unchanged
    | otherwise -> Changed (IntSet.toList (IntSet.fromList shrunk)) ds'

-- | The least value in a non-empty domain (callers guard emptiness first).
domMin :: Domain -> Value
domMin (Domain s) = IntSet.findMin s

-- | The greatest value in a non-empty domain (callers guard emptiness first).
domMax :: Domain -> Value
domMax (Domain s) = IntSet.findMax s

{- | The variables a constraint mentions — the single source of truth for the watch map and the
search heuristics, so adding a constraint kind updates both at once.
-}
constraintVars :: Constraint -> [Var]
constraintVars (AllDifferent vs) = vs
constraintVars (NotEqual a b) = [a, b]
constraintVars (AllDiffOffset pairs) = map fst pairs
constraintVars (SumEq vs _) = vs
constraintVars (LessEq a b) = [a, b]
