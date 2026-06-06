{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE StrictData #-}

{- | The assignment trail and the per-variable state arrays. This is the engine's mutable spine: a
growable buffer of assigned literals in assignment order, a small growable buffer of per-level trail
checkpoints, and four per-variable unboxed 'Int' arrays sized @nVars@.

The trail is the single source of truth for undo (the SKILL rule): a backjump unwinds it to a level's
checkpoint, and that unwind is the only place that resets the per-variable arrays. No undo logic lives
anywhere else, so chronological backtracking and non-chronological backjumping share one mechanism —
unwind to a lower level's checkpoint.

Per-variable arrays use a sentinel @-1@ for "unassigned" rather than @Maybe@: a boxed @Maybe Int@
would defeat the @Unboxed@ representation, and the loop already works in raw 'Int's:

  * @value@  : @-1@ unassigned, @0@ false, @1@ true.
  * @level@  : the decision level the var was assigned at; @-1@ unassigned.
  * @reason@ : the 'ClauseRef' of the antecedent clause, @-1@ for a decision or unassigned. This is
    the implication-graph edge the later 1UIP walk follows.
  * @phase@  : the last-assigned polarity (phase saving), persisting across restarts; @-1@ until the
    var has ever been assigned.

Generic over 'PrimMonad' so the same code runs in fast 'ST' and trace 'IO'.
-}
module Lattice.SAT.Trail (
  Trail,
  newTrail,
  assignLit,
  levelCheckpoint,
  unwindTo,
  trailSize,
  trailLitAt,
  varValue,
  varLevel,
  varReason,
  varPhase,
  writePhase,
) where

import Control.Monad (when)
import Control.Monad.Primitive (PrimMonad, PrimState)
import Data.Primitive.MutVar (MutVar, newMutVar, readMutVar, writeMutVar)
import Data.Vector.Unboxed.Mutable qualified as UM
import Lattice.Core.Types (Level)
import Lattice.SAT.Types (Lit (..), Var, litPos, litVar)

{- | The trail plus the per-variable state. 'tValue', 'tLevel', 'tReason' and 'tPhase' are fixed-size
@nVars@ arrays; 'tLits' is the growable buffer of assigned literals (raw encodings) with its used
count, and 'tLevels' is the growable buffer of trail-length checkpoints, one per decision level.
-}
data Trail s = Trail
  { tValue :: UM.MVector s Int
  , tLevel :: UM.MVector s Int
  , tReason :: UM.MVector s Int
  , tPhase :: UM.MVector s Int
  , tLits :: MutVar s (UM.MVector s Int, Int)
  , tLevels :: MutVar s (UM.MVector s Int, Int)
  }

{- | A fresh trail for @nVars@ variables: every variable unassigned (all arrays @-1@), an empty
literal buffer, and no level checkpoints (decision level 0 is the implicit base before the first
'levelCheckpoint').
-}
newTrail :: (PrimMonad m) => Int -> m (Trail (PrimState m))
newTrail nVars = do
  value <- UM.replicate nVars (-1)
  level <- UM.replicate nVars (-1)
  reason <- UM.replicate nVars (-1)
  phase <- UM.replicate nVars (-1)
  litsBuf <- UM.new (max 1 nVars)
  litsRef <- newMutVar (litsBuf, 0)
  levelsBuf <- UM.new 16
  levelsRef <- newMutVar (levelsBuf, 0)
  pure
    Trail
      { tValue = value
      , tLevel = level
      , tReason = reason
      , tPhase = phase
      , tLits = litsRef
      , tLevels = levelsRef
      }

-- | Push a value onto a doubling growable @Int@ buffer, growing (allocate-and-copy) when full.
pushBuf :: (PrimMonad m) => MutVar (PrimState m) (UM.MVector (PrimState m) Int, Int) -> Int -> m ()
pushBuf ref x = do
  (buf, used) <- readMutVar ref
  let cap = UM.length buf
  buf' <-
    if used < cap
      then pure buf
      else UM.grow buf (max 1 cap)
  UM.write buf' used x
  writeMutVar ref (buf', used + 1)

{- | Assign a literal at a decision level with an antecedent reason ('ClauseRef', or @-1@ for a
decision). Records the literal on the trail and writes the variable's value, level, reason, and saved
phase. Caller ensures the variable was unassigned.
-}
assignLit :: (PrimMonad m) => Trail (PrimState m) -> Lit -> Level -> Int -> m ()
assignLit tr lit@(Lit raw) lvl rsn = do
  let v = litVar lit
      !val = if litPos lit then 1 else 0
  UM.write (tValue tr) v val
  UM.write (tLevel tr) v lvl
  UM.write (tReason tr) v rsn
  UM.write (tPhase tr) v val
  pushBuf (tLits tr) raw

{- | Open a new decision level: record the current trail length as this level's checkpoint. 'unwindTo'
of the level truncates the trail back to here.
-}
levelCheckpoint :: (PrimMonad m) => Trail (PrimState m) -> m ()
levelCheckpoint tr = do
  (_, used) <- readMutVar (tLits tr)
  pushBuf (tLevels tr) used

{- | Unwind the trail to the given decision level: pop every literal assigned above that level's
checkpoint, resetting each popped variable's value/level/reason to unassigned (the saved phase is kept
for phase saving), and drop the checkpoints for the abandoned levels. Unwinding to level 0 (a restart
or a backjump to the root) discards every DECISION level but KEEPS the level-0 root assignments — the
input unit-clause propagations — which are permanently fixed and never re-derived. The trail is the
only place these resets happen.

CONVENTION DIVERGENCE FROM MiniSat (deliberate, see WR-01). @unwindTo lvl@ truncates to
@tLevels[lvl-1]@ — the trail length when level @lvl@ /opened/ — so it removes level @lvl@ ITSELF along
with everything above. MiniSat @cancelUntil(lvl)@ instead KEEPS level @lvl@ and removes only levels
@> lvl@. The practical consequence on a backjump to @bj@: the learned clause's highest /other/ literal
(at level @bj@ by 'Lattice.SAT.Analyze.secondHighest') is un-assigned by the unwind, so the asserting
clause is NOT unit in the MiniSat sense when the asserting literal is then enqueued. This is sound, not
a bug: the asserting literal is still forced true (the search advances) and no other literal spuriously
satisfies the clause, and every clause the solver learns stays implied by the formula. Both facts are
locked by tests — the @sat/analyze@ "WR-01 lock" property (the post-backjump assert is sound) and the
already-green implied-clause property (@formula AND not-clause@ UNSAT) at a high budget. Do NOT change
this to keep level @bj@ on the static "clause should be unit" concern alone; it is a working,
differentially-green invariant, and the level-0 special case below is the acef277 root-unit fix.
-}
unwindTo :: (PrimMonad m) => Trail (PrimState m) -> Level -> m ()
unwindTo tr lvl = do
  (litsBuf, used) <- readMutVar (tLits tr)
  (levelsBuf, nLevels) <- readMutVar (tLevels tr)
  -- The j-th level checkpoint (tLevels[j-1]) is the trail length at which decision level j opened.
  -- Unwinding to level lvl drops every decision level >= lvl, truncating the trail to tLevels[lvl-1].
  -- Level 0 is special: it holds no decision, only the root unit propagations, so unwinding to 0 must
  -- KEEP those (truncate to tLevels[0], where level 1 opened) and drop only decision levels >= 1 — NOT
  -- truncate to 0, which erased the root units and let those variables be wrongly re-decided.
  let checkpointIdx = if lvl <= 0 then 0 else lvl - 1
  target <-
    if checkpointIdx < nLevels
      then UM.read levelsBuf checkpointIdx
      else pure used -- nothing above this level; no-op
  let popDown !i
        | i <= target = pure ()
        | otherwise = do
            raw <- UM.read litsBuf (i - 1)
            let v = litVar (Lit raw)
            UM.write (tValue tr) v (-1)
            UM.write (tLevel tr) v (-1)
            UM.write (tReason tr) v (-1)
            popDown (i - 1)
  popDown used
  writeMutVar (tLits tr) (litsBuf, target)
  -- Drop the checkpoints for levels above the one we unwound to.
  let keptLevels = min lvl nLevels
  when (keptLevels < nLevels) $
    writeMutVar (tLevels tr) (levelsBuf, max 0 keptLevels)

-- | The number of literals currently on the trail (assigned variables).
trailSize :: (PrimMonad m) => Trail (PrimState m) -> m Int
trailSize tr = snd <$> readMutVar (tLits tr)

{- | The raw literal encoding at trail position @i@ (@0 .. trailSize - 1@), in assignment order. The
propagation queue reads forward through the trail with this; the caller ensures @i@ is in range.
-}
trailLitAt :: (PrimMonad m) => Trail (PrimState m) -> Int -> m Int
trailLitAt tr i = do
  (buf, _) <- readMutVar (tLits tr)
  UM.read buf i

-- | A variable's current value: @-1@ unassigned, @0@ false, @1@ true.
varValue :: (PrimMonad m) => Trail (PrimState m) -> Var -> m Int
varValue tr = UM.read (tValue tr)

-- | A variable's assignment level, or @-1@ if unassigned.
varLevel :: (PrimMonad m) => Trail (PrimState m) -> Var -> m Int
varLevel tr = UM.read (tLevel tr)

-- | A variable's antecedent 'ClauseRef', @-1@ for a decision or an unassigned variable.
varReason :: (PrimMonad m) => Trail (PrimState m) -> Var -> m Int
varReason tr = UM.read (tReason tr)

-- | A variable's saved phase (last-assigned polarity), @-1@ until it has ever been assigned.
varPhase :: (PrimMonad m) => Trail (PrimState m) -> Var -> m Int
varPhase tr = UM.read (tPhase tr)

{- | Overwrite a variable's saved phase directly (phase saving): @1@ for a positive polarity, @0@ for
negative. 'assignLit' already records the phase on every assignment; this is the explicit setter the
VSIDS phase-saving helpers use so the polarity can be remembered independently of an assignment.
-}
writePhase :: (PrimMonad m) => Trail (PrimState m) -> Var -> Int -> m ()
writePhase tr = UM.write (tPhase tr)
