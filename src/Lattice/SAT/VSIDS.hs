{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE StrictData #-}

{- | The CDCL search heuristics: the VSIDS branching activity, phase saving, and the Luby restart
sequence. These decide WHICH path the solver explores and WHEN it restarts; they never change which
assignments are valid, so the differential (every learned-clause and the brute-vs-SAT agreement) is the
guard, not these heuristics themselves.

There is NO repo analog for the mechanism. The CP engine recomputes an MRV/degree/LCV key per decision
from the live domains ('Lattice.CP.Search' @mrvKey@/@lcvCost@); VSIDS instead keeps a persistent
per-variable activity score that conflict analysis bumps. The activity array plays the same ORDERING
role the CP key plays, but the data flow is the opposite: CP derives the key fresh, VSIDS accumulates it.
The recurrences and constants below are from the SAT literature (MiniSat / "Understanding VSIDS" /
Luby-Sinclair-Zuckerman), not from a copyable file.

  * VSIDS activity (EVSIDS form). Each variable has a 'Double' activity. On a conflict, the variables on
    the conflict side are /bumped/ by the current increment; once per conflict the increment is /grown/
    by @1 / var_decay@ (@var_decay = 0.95@). Growing the increment is the EVSIDS trick: it is equivalent
    to multiplicatively decaying every activity, but costs O(1) instead of an O(nVars) sweep. 'pickBranch'
    chooses the highest-activity UNASSIGNED variable.
  * Overflow rescale (Pitfall 5). The increment grows unboundedly; without a guard the activities
    overflow to @Infinity@ and the heuristic degrades to first-index order. When any activity (or the
    increment) exceeds @1e100@, every activity and the increment are multiplied by @1e-100@. The scale is
    uniform, so the relative ordering — all 'pickBranch' depends on — is preserved.
  * Phase saving. The last polarity a variable was assigned is remembered (the trail's @phase@ array);
    on a decision the saved polarity is reused rather than a fixed default. It persists across restarts,
    so a restart often re-derives the same partial assignment quickly.
  * Luby restarts. The reluctant-doubling sequence @1,1,2,1,1,2,4,1,1,2,1,1,2,4,8,...@ scaled by a unit
    gives the conflict budget between restarts. A restart unwinds the trail to level 0 but keeps the
    learned clauses and the activities (only the assignment is erased), so progress accumulates.

@pickBranch@ is a linear argmax scan, which is fine for the FLEX tier's small instances. A max-heap keyed
on activity is the standard upgrade for large instances; see the UPGRADE SLOT note on 'pickBranch'.

Generic over 'PrimMonad' so the same code runs in fast 'ST' and trace 'IO', like the rest of the engine.
-}
module Lattice.SAT.VSIDS (
  VSIDS,
  newVSIDS,
  bumpActivity,
  decayActivity,
  rescaleActivities,
  readActivity,
  pickBranch,
  savePhase,
  branchPhase,
  luby,
) where

import Control.Monad (when)
import Control.Monad.Primitive (PrimMonad, PrimState)
import Data.Bits (shiftL)
import Data.Primitive.MutVar (MutVar, newMutVar, readMutVar, writeMutVar)
import Data.Vector.Unboxed.Mutable qualified as UM
import Lattice.SAT.Trail (varPhase, varValue, writePhase)
import Lattice.SAT.Types (Var)
import Lattice.SAT.Watched (SatState (..))

{- | The VSIDS state: the per-variable activity array (sized @nVars@, an unboxed 'Double' vector) and
the current bump increment held in a 'MutVar'. The increment grows each conflict (the EVSIDS trick);
both it and the activities are rescaled down together when they overflow past the threshold.
-}
data VSIDS s = VSIDS
  { vsActivity :: UM.MVector s Double
  , vsInc :: MutVar s Double
  }

{- | The multiplicative decay factor (MiniSat's @var_decay@): a 5% decay, applied by growing the
increment by @1 / var_decay@ each conflict rather than sweeping every activity.
-}
varDecay :: Double
varDecay = 0.95

-- | The overflow threshold: when an activity or the increment exceeds this, rescale everything down.
rescaleThreshold :: Double
rescaleThreshold = 1e100

{- | The rescale factor applied to every activity and the increment on overflow (the reciprocal of the
threshold, so a value at the threshold returns to ~1 and ordering is preserved).
-}
rescaleFactor :: Double
rescaleFactor = 1e-100

{- | A fresh VSIDS state for @nVars@ variables: every activity starts at 0, the increment at 1. The
increment is positive and grows from here; the activities accumulate bumps.
-}
newVSIDS :: (PrimMonad m) => Int -> m (VSIDS (PrimState m))
newVSIDS nVars = do
  act <- UM.replicate (max 0 nVars) 0
  inc <- newMutVar 1.0
  pure VSIDS {vsActivity = act, vsInc = inc}

{- | Bump a variable's activity by the current increment (called for each conflict-side variable during
analysis). If the bump pushes the activity past the overflow threshold, rescale every activity and the
increment down by 'rescaleFactor' — a uniform scale that preserves the relative ordering 'pickBranch'
reads (Pitfall 5).
-}
bumpActivity :: (PrimMonad m) => VSIDS (PrimState m) -> Var -> m ()
bumpActivity vs v = do
  inc <- readMutVar (vsInc vs)
  a <- UM.read (vsActivity vs) v
  let !a' = a + inc
  UM.write (vsActivity vs) v a'
  -- Guard the overflow: a single activity past the threshold triggers a global rescale.
  when (a' > rescaleThreshold) (rescaleActivities vs)

{- | Decay the activities once per conflict by GROWING the increment (the EVSIDS equivalence: scaling
the increment up by @1 / var_decay@ is the same, for ordering, as scaling every activity down by
@var_decay@, but O(1) instead of O(nVars)). If the grown increment crosses the overflow threshold,
rescale everything down so the next bumps stay in range.
-}
decayActivity :: (PrimMonad m) => VSIDS (PrimState m) -> m ()
decayActivity vs = do
  inc <- readMutVar (vsInc vs)
  let !inc' = inc / varDecay
  writeMutVar (vsInc vs) inc'
  when (inc' > rescaleThreshold) (rescaleActivities vs)

{- | Rescale every activity and the increment down by 'rescaleFactor'. The scale is uniform, so the
relative order of the activities is unchanged — the branching heuristic, which only compares activities,
is unaffected. This is the overflow guard that keeps the activities finite over a long solve.
-}
rescaleActivities :: (PrimMonad m) => VSIDS (PrimState m) -> m ()
rescaleActivities vs = do
  let n = UM.length (vsActivity vs)
      scaleAll !i
        | i >= n = pure ()
        | otherwise = do
            a <- UM.read (vsActivity vs) i
            UM.write (vsActivity vs) i (a * rescaleFactor)
            scaleAll (i + 1)
  scaleAll 0
  inc <- readMutVar (vsInc vs)
  writeMutVar (vsInc vs) (inc * rescaleFactor)

-- | Read a variable's current activity (used by the tests and by 'pickBranch').
readActivity :: (PrimMonad m) => VSIDS (PrimState m) -> Var -> m Double
readActivity vs = UM.read (vsActivity vs)

{- | Pick the branching variable: the UNASSIGNED variable with the highest activity, or 'Nothing' when
every variable is assigned (a complete assignment — the loop reads a model). A linear argmax scan over
the variables, skipping assigned ones.

>>> UPGRADE SLOT <<<
A max-heap keyed on activity (decrease-key on bump, lazy deletion of assigned variables) is the standard
structure for large instances, replacing this O(nVars) scan with O(log n) per decision. The linear scan
is the legible MVP for the FLEX tier's small instances, mirroring the project's value-elimination /
recomputed-MRV discipline; the heap is the performance upgrade, not the MVP.
-}
pickBranch :: (PrimMonad m) => SatState (PrimState m) -> VSIDS (PrimState m) -> m (Maybe Var)
pickBranch st vs = go 0 Nothing (negate (1 / 0))
 where
  n = ssVars st
  -- Walk every variable; track the best (highest-activity) unassigned one seen so far. The initial
  -- best activity is negative infinity so the first unassigned variable always wins the comparison.
  go !v !best !bestAct
    | v >= n = pure best
    | otherwise = do
        val <- varValue (ssTrail st) v
        if val /= -1
          then go (v + 1) best bestAct -- assigned: skip it.
          else do
            a <- UM.read (vsActivity vs) v
            if a > bestAct
              then go (v + 1) (Just v) a
              else go (v + 1) best bestAct

{- | Save a variable's branching phase (last-assigned polarity): 'True' positive, 'False' negative. The
trail already records the phase on every assignment ('Lattice.SAT.Trail.assignLit'); this lets the
polarity be remembered explicitly, persisting across restarts.
-}
savePhase :: (PrimMonad m) => SatState (PrimState m) -> Var -> Bool -> m ()
savePhase st v pos = writePhase (ssTrail st) v (if pos then 1 else 0)

{- | The saved branching phase of a variable: 'True' if its stored phase is positive, 'False' otherwise
(including a never-assigned variable, whose phase is the @-1@ sentinel — defaulting to the MiniSat
negative-first convention).
-}
branchPhase :: (PrimMonad m) => SatState (PrimState m) -> Var -> m Bool
branchPhase st v = (== 1) <$> varPhase (ssTrail st) v

{- | The Luby restart sequence (reluctant doubling): @luby i@ for @i = 1, 2, 3, ...@ is
@1,1,2,1,1,2,4,1,1,2,1,1,2,4,8,...@. The closed recurrence (Knuth's iterative form):

  * @t_i = 2^(k-1)@                 when @i = 2^k - 1@ (the end of a block);
  * @t_i = t_(i - 2^(k-1) + 1)@     when @2^(k-1) <= i < 2^k - 1@ (recurse into the prefix).

A restart fires after @unit * luby i@ conflicts; the multiplier @unit@ is a constant the solver picks.
Pure and total for @i >= 1@, so it is unit-tested against the literal sequence (the SAT-03 deliverable).
-}
luby :: Int -> Int
luby i = go 1 1
 where
  -- seqLen = 2^k - 1, the length of the block ending at this k. Grow k until the block reaches i, i.e.
  -- until 2^k - 1 >= i (the SMALLEST such k). The guard is @seqLen < i@, not @seqLen < i + 1@: for the
  -- block-end case i = 2^k - 1 we must STOP at this k (seqLen == i) and emit 2^(k-1); overshooting by
  -- one block makes the prefix recursion below diverge (luby 1 would loop forever).
  go !k !seqLen
    | seqLen < i = go (k + 1) (2 * seqLen + 1)
    | seqLen == i = 1 `shiftL` (k - 1) -- i sits exactly at a block end (2^k - 1): value 2^(k-1).
    | otherwise = luby (i - (1 `shiftL` (k - 1)) + 1) -- recurse into the block's prefix.
