{- | The pruning core (CORE-02): the value-elimination all-different propagator and the binary
not-equal propagator. A propagator runs one pass over the domains and reports which variables
shrank (so the queue can re-enqueue exactly their watchers) and whether any domain emptied (a
conflict). Soundness lives here: a value is removed from a peer only because another peer is
already pinned to it, and two all-different peers cannot both hold the same value — so no value
belonging to a real solution is ever removed. The sound-propagation property test mechanizes this.
-}
module Lattice.CP.Propagator (
  PropResult (..),
  propagateConstraint,
) where

import Data.IntSet qualified as IntSet
import Data.Maybe (mapMaybe)
import Lattice.Core.Domain (domainOf, isEmpty, removeValue, singletonValue)
import Lattice.Core.Types (Constraint (..), Domains, Var)

{- | The outcome of one constraint's propagation pass. 'Changed' reports the variables whose
domains actually shrank plus the updated map; 'Conflict' means some domain became empty.
-}
data PropResult
  = Changed [Var] Domains
  | Unchanged
  | Conflict
  deriving (Eq, Show)

{- | Run one constraint over the current domains. Singleton-pinned variables forbid their value
in their peers; the result reports the real shrinks (for re-enqueueing) and any conflict.
-}
propagateConstraint :: Constraint -> Domains -> PropResult
propagateConstraint (AllDifferent vars) ds =
  -- Value elimination: each variable pinned to {v} removes v from its peers. Sound but weak
  -- (not even arc-consistent), which is the right starting point for M1.
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

{- | Classify the pass: any emptied domain is a 'Conflict'; otherwise report real shrinks (with
duplicates removed) as 'Changed', or 'Unchanged' when nothing moved.
-}
finalize :: [Var] -> Domains -> [Var] -> PropResult
finalize vars ds' shrunk
  | any (\y -> isEmpty (domainOf y ds')) vars = Conflict
  | null shrunk = Unchanged
  | otherwise = Changed (IntSet.toList (IntSet.fromList shrunk)) ds'
