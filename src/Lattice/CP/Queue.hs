{- | The propagation worklist and fixpoint loop (CORE-03), in two modes (EVENT-01). 'propagateM' is
the loop generic over the monad: it drains a worklist of constraint indices, re-enqueueing exactly
the watchers of shrunk variables, and emits a 'Propagate' event for each value removed plus a
'Conflict' event at the emptied cell. 'propagate' is the pure, fast-mode instantiation — @Identity@
with 'noEmit', which the compiler reduces back to the original allocation-free loop. Queue ORDER
changes which constraint runs first but never the final fixpoint, since domains only ever shrink.
-}
module Lattice.CP.Queue (
  Conflict (..),
  propagate,
  propagateM,
) where

import Data.Functor.Identity (runIdentity)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Lattice.CP.Propagator (PropResult (..), constraintVars, propagateConstraint)
import Lattice.Core.Domain (domainOf)
import Lattice.Core.Types (Constraint, Domain (..), Domains, Var)
import Lattice.Event qualified as Ev

{- | A propagation conflict: some variable's domain was emptied. No payload in the pure result; the
emitted 'Ev.Conflict' carries the offending cell for the visualizer.
-}
data Conflict = EmptyDomain
  deriving (Eq, Show)

-- | Variable to the indices of the constraints that mention it, built once per model.
type WatchMap = IntMap.IntMap [Int]

-- | Pure propagation to a fixpoint: the fast-mode instantiation of 'propagateM' with the no-op emit.
propagate :: [Constraint] -> Domains -> Either Conflict Domains
propagate cs ds = runIdentity (propagateM Ev.noEmit cs ds)
{-# INLINE propagate #-}

{- | Propagate to a fixpoint, threading an emit callback. 'Left' is a conflict (an emptied domain);
'Right' is the stable domain map. The worklist is seeded with all constraints so a contradictory
givens set surfaces here, before any search decision.
-}
propagateM :: (Monad m) => Ev.Emit m -> [Constraint] -> Domains -> m (Either Conflict Domains)
propagateM emit cs = drain [0 .. length cs - 1]
 where
  consMap = IntMap.fromList (zip [0 ..] cs)
  watch = buildWatch cs

  drain [] ds = pure (Right ds)
  drain (i : rest) ds =
    case IntMap.lookup i consMap of
      Nothing -> drain rest ds
      Just c -> case propagateConstraint c ds of
        Conflict v -> emit (Ev.Conflict v) >> pure (Left EmptyDomain)
        Unchanged -> drain rest ds
        Changed vs ds' -> emitRemovals emit vs ds ds' >> drain (concatMap watchersOf vs ++ rest) ds'

  watchersOf v = IntMap.findWithDefault [] v watch
{-# INLINEABLE propagateM #-}

-- | Emit a 'Propagate' for every value each shrunk variable lost between the old and new domains.
emitRemovals :: (Monad m) => Ev.Emit m -> [Var] -> Domains -> Domains -> m ()
emitRemovals emit vs old new =
  mapM_ (\v -> mapM_ (emit . Ev.Propagate v) (removed v)) vs
 where
  removed v = IntSet.toList (IntSet.difference (setOf v old) (setOf v new))
  setOf v ds = case domainOf v ds of Domain s -> s
{-# INLINEABLE emitRemovals #-}

-- | Map each variable to the indices of the constraints that watch it.
buildWatch :: [Constraint] -> WatchMap
buildWatch cs =
  IntMap.fromListWith (++) [(v, [i]) | (i, c) <- zip [0 ..] cs, v <- constraintVars c]
