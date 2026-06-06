{- | The propagation worklist and fixpoint loop (CORE-03). A watch map, built once at model time
from 'constraintVars', records which constraints mention each variable. 'propagate' drains a
worklist of constraint indices: running a constraint that shrinks variables re-enqueues exactly the
watchers of those variables, and an emptied domain ends the drain as a conflict. The fixpoint is a
drained queue with no empty domain. Queue ORDER changes which constraint runs first but never the
final fixpoint — propagation is confluent because domains only ever shrink.
-}
module Lattice.CP.Queue (
  Conflict (..),
  propagate,
) where

import Data.IntMap.Strict qualified as IntMap
import Lattice.CP.Propagator (PropResult (..), constraintVars, propagateConstraint)
import Lattice.Core.Types (Constraint, Domains, Var)

{- | A propagation conflict: some variable's domain was emptied. It carries no payload in M1; the
Phase 3 visualizer will attach the offending variable and reason. The constructor is named
'EmptyDomain' to avoid colliding with 'PropResult'\''s @Conflict@ constructor.
-}
data Conflict = EmptyDomain
  deriving (Eq, Show)

-- | Variable to the indices of the constraints that mention it, built once per model.
type WatchMap = IntMap.IntMap [Int]

{- | Propagate every constraint to a fixpoint. 'Left' is a conflict (an emptied domain); 'Right' is
the stable domain map. The worklist is seeded with all constraints so a contradictory givens set
surfaces here, as a conflict, before any search decision.
-}
propagate :: [Constraint] -> Domains -> Either Conflict Domains
propagate cs = drain [0 .. length cs - 1]
 where
  consMap = IntMap.fromList (zip [0 ..] cs)
  watch = buildWatch cs

  -- LIFO worklist: pop the front, push wakeups on the front (never an append at the end).
  drain :: [Int] -> Domains -> Either Conflict Domains
  drain [] ds = Right ds
  drain (i : rest) ds =
    case IntMap.lookup i consMap of
      Nothing -> drain rest ds
      Just c -> case propagateConstraint c ds of
        Conflict -> Left EmptyDomain
        Unchanged -> drain rest ds
        Changed vs ds' -> drain (concatMap watchersOf vs ++ rest) ds'

  watchersOf :: Var -> [Int]
  watchersOf v = IntMap.findWithDefault [] v watch

-- | Map each variable to the indices of the constraints that watch it.
buildWatch :: [Constraint] -> WatchMap
buildWatch cs =
  IntMap.fromListWith (++) [(v, [i]) | (i, c) <- zip [0 ..] cs, v <- constraintVars c]
