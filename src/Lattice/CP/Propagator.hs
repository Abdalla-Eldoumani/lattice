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
propagateConstraint (LineClue vars clue) ds =
  -- Placement-enumeration value elimination: enumerate every 0/1 layout of the line that has
  -- exactly the clued runs in order, keep those consistent with the already-decided cells, then
  -- force a cell to 1 (remove 0) when every surviving layout inks it, and to 0 (remove 1) when
  -- none does. Sound but weak (it is value elimination, not the strongest line consistency).
  -- >>> LINE-AC UPGRADE SLOT <<<
  -- (A DFA/automaton propagator over the run-length regular language would replace enumeration
  -- here with layered-graph reasoning; the enumeration below is the slot it supersedes. The
  -- layout count is C(free + runs, runs), cheap for lines <= ~15 cells, which is why fixtures
  -- keep lines narrow — a wide line with many runs is the one cost cliff.)
  case filter (agrees domsInLine) (placements (length vars) clue) of
    [] -> Conflict (firstVar vars)
    surviving ->
      let forced = [(i, decide i surviving) | i <- [0 .. length vars - 1]]
          (ds', shrunk) = foldl' force (ds, []) forced
       in finalize vars ds' shrunk
 where
  domsInLine = [domainOf v ds | v <- vars]
  firstVar (v : _) = v
  firstVar [] = 0
  -- A layout agrees with a cell whose domain is a singleton {0} or {1}; an undecided {0,1} cell
  -- accepts either bit.
  agrees doms layout = and (zipWith ok doms layout)
   where
    ok dom bit = case singletonValue dom of
      Just fixed -> fixed == bit
      Nothing -> True
  -- Just 1 if every surviving layout inks index i, Just 0 if none does, Nothing if they disagree.
  decide i surviving =
    let bits = [layout !! i | layout <- surviving]
     in if all (== 1) bits
          then Just 1
          else if all (== 0) bits then Just 0 else Nothing
  force acc (_, Nothing) = acc
  force (curDs, sh) (i, Just bit) =
    let v = vars !! i
        next = removeValue (1 - bit) v curDs
     in if domainOf v next /= domainOf v curDs then (next, v : sh) else (curDs, sh)

{- | Classify the pass: any emptied domain is a 'Conflict'; otherwise report real shrinks (with
duplicates removed) as 'Changed', or 'Unchanged' when nothing moved.
-}
finalize :: [Var] -> Domains -> [Var] -> PropResult
finalize vars ds' shrunk = case filter (\y -> isEmpty (domainOf y ds')) vars of
  (y : _) -> Conflict y
  []
    | null shrunk -> Unchanged
    | otherwise -> Changed (IntSet.toList (IntSet.fromList shrunk)) ds'

{- | Every 0/1 layout of a line of the given length whose maximal runs of 1s are exactly the clue,
in order. Built by recursion on the run list: each run needs a gap of at least one blank after it
unless it is the last, and leading/trailing blanks are free. The count is @C(free + runs, runs)@,
so a line of <= ~15 cells with a few runs is cheap to enumerate (see the LINE-AC upgrade note).
-}
placements :: Int -> [Int] -> [[Value]]
placements len [] = [replicate len 0]
placements len (r : rs)
  | r > len = []
  | otherwise =
      -- Leading blanks (0..), then the run of @r@ ones, then a separating blank if more runs
      -- follow, then recurse on the remaining length.
      [ replicate lead 0 ++ replicate r 1 ++ sep ++ rest
      | lead <- [0 .. len - r - minTail]
      , rest <- placements (len - lead - r - length sep) rs
      ]
 where
  -- A separating blank after this run, present only when more runs follow.
  sep = [0 | not (null rs)]
  -- The minimum cells the remaining runs (plus their separators) still need after this run.
  minTail = if null rs then 0 else sum rs + length rs

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
constraintVars (LineClue vs _) = vs
