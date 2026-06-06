{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE StrictData #-}

{- | Watched-literal unit propagation (BCP) and the two-watched-literal invariant. This is the SAT
engine's propagation core: it owns the 'SatState' the whole solver threads — the clause database, the
assignment trail, the per-literal watch buffers, the propagation queue head, and the current decision
level — and drives unit propagation to a fixpoint over the two-watched scheme.

Each clause of length >= 2 watches exactly two of its literals. The invariant is: every clause watches
two non-false literals, or it is unit (one watch true/unassigned, all others false) or conflicting (all
literals false). The scheme's payoff is that a watched literal only needs attention when it is
/falsified/, and a falsified watch is repaired by finding a new non-false literal to watch — so a
clause is only re-examined a fraction of the time, and, critically:

  * WATCH LISTS NEED ZERO MAINTENANCE ON BACKTRACK. The watched-literal property survives a trail
    unwind by construction: if two literals were non-false at a deeper level, they are still non-false
    after assignments above the backjump level are undone (undoing only un-falsifies literals). Only the
    trail (value/level/reason) unwinds; never undo or "fix up" the watch buffers. Writing undo code for
    them is wrong and slow.

The move logic per visited clause has exactly three outcomes (the source of truth is the SAT literature,
not a repo analog): (a) the OTHER watch is already true -> leave the watch, the clause is satisfied;
(b) a non-false, non-watch literal q exists -> move the watch to q; (c) otherwise the clause is unit (the
other watch is unassigned -> enqueue it with this clause as its reason) or a conflict (the other watch is
false -> return the clause-ref).

'checkInvariant' is a 'Bool'-returning scan used by the test build and a debug solve; it is NOT wired
through the base library's optimizer-dropped assertion combinator (which @-O@ silently removes, so the
check would never run). It is called only behind a flag that is 'False' in fast mode and constant-folds
away.

Generic over 'PrimMonad' so the same code runs in fast 'ST' and trace 'IO', mirroring the CP loop.
-}
module Lattice.SAT.Watched (
  SatState (..),
  newState,
  attachClause,
  learnAndAttach,
  decideLit,
  enqueueLit,
  propagate,
  checkInvariant,
  stateValueOf,
  litValue,
  currentLevel,
) where

import Control.Monad (foldM, when)
import Control.Monad.Primitive (PrimMonad, PrimState)
import Data.Primitive.MutVar (MutVar, newMutVar, readMutVar, writeMutVar)
import Data.Vector qualified as V
import Data.Vector.Unboxed qualified as U
import Data.Vector.Unboxed.Mutable qualified as UM
import Lattice.Event (Emit)
import Lattice.Event qualified as Ev
import Lattice.SAT.ClauseDB (ClauseDB, ClauseRef, addClause, clauseLits, learnClause, newClauseDB)
import Lattice.SAT.Trail (
  Trail,
  assignLit,
  levelCheckpoint,
  newTrail,
  trailLitAt,
  trailSize,
  varValue,
 )
import Lattice.SAT.Types (Clause, Lit (..), Var, litPos, litVar, negLit)

{- | The solver's full mutable state. 'ssWatch' is a boxed vector of one growable @Int@ clause-ref
buffer per literal (indexed @0 .. 2*nVars-1@ by the literal code), so the watch buffers are sized
@2*nVars@, not @nVars@. 'ssClauseW' is a flat unboxed buffer of the two watched literal /codes/ per
clause (slots @2*ref@ and @2*ref+1@): reading it gives "the other watch" in O(1) and writing it is how a
watch moves. 'ssQHead' is the propagation queue head — the next trail index to process — so the trail
itself is the BCP queue. 'ssLevel' is the current decision level.
-}
data SatState s = SatState
  { ssVars :: Int
  , ssDB :: ClauseDB s
  , ssTrail :: Trail s
  , ssWatch :: V.Vector (MutVar s (UM.MVector s Int, Int))
  , ssClauseW :: MutVar s (UM.MVector s Int, Int)
  , ssQHead :: MutVar s Int
  , ssLevel :: MutVar s Int
  , ssConflict :: MutVar s Int
  {- ^ A clause-ref of a conflict found while attaching unit/empty clauses (before the first
  propagate), or @-1@ for none. A unit clause whose literal is already false at level 0 — two
  contradictory input units — is a top-level conflict the initial 'propagate' surfaces as 'Unsat'.
  -}
  }

{- | Build a fresh state for @nVars@ variables and attach every clause. After this, every clause of
length >= 2 watches two distinct literals and the two-watched invariant holds. A unit clause (length 1)
is enqueued immediately as a forced assignment at level 0; an empty clause makes the state trivially
conflicting (it has no watch and BCP never repairs it — the solver's initial propagate surfaces it).
-}
newState :: (PrimMonad m) => Int -> [Clause] -> m (SatState (PrimState m))
newState nVars clauses = do
  db <- newClauseDB
  tr <- newTrail nVars
  -- One growable clause-ref buffer per literal; literals are 0 .. 2*nVars-1.
  watchBufs <- V.generateM (max 0 (2 * nVars)) (const newWatchBuf)
  clauseWBuf <- UM.new 16
  clauseW <- newMutVar (clauseWBuf, 0)
  qHead <- newMutVar 0
  lvl <- newMutVar 0
  conflict <- newMutVar (-1)
  let st =
        SatState
          { ssVars = nVars
          , ssDB = db
          , ssTrail = tr
          , ssWatch = watchBufs
          , ssClauseW = clauseW
          , ssQHead = qHead
          , ssLevel = lvl
          , ssConflict = conflict
          }
  mapM_ (attachClause st) clauses
  pure st
 where
  newWatchBuf = do
    buf <- UM.new 4
    newMutVar (buf, 0 :: Int)

{- | Normalize an input clause before it is stored and watched: drop duplicate literals (keeping the
first occurrence, preserving order) and report a tautology — a clause containing both a literal and its
negation, which is satisfied by every assignment. The watched-literal scheme requires the two watched
literals to be DISTINCT variables' literals; an input clause with a repeated literal (the DIMACS grammar
and the differential generator both permit one) would otherwise watch the same literal twice, corrupting
the per-literal watch buffer when that literal is later falsified. Returns @Nothing@ for a tautology
(the clause is dropped, it constrains nothing) or @Just@ the deduplicated clause.
-}
normalizeClause :: Clause -> Maybe Clause
normalizeClause = go [] []
 where
  -- seenCodes: literal codes already kept; seenVars unused beyond the tautology check below.
  go _ acc [] = Just (reverse acc)
  go seen acc (l : ls)
    | litCode l `elem` seen = go seen acc ls -- a duplicate literal: drop this occurrence.
    | litCode (negLit l) `elem` seen = Nothing -- both l and ¬l present: a tautology, drop the clause.
    | otherwise = go (litCode l : seen) (l : acc) ls
  litCode (Lit c) = c

{- | Attach a clause to the database and set up its two watches. The clause is first normalized
(duplicate literals dropped, a tautological clause skipped entirely). A clause of length >= 2 watches
its first two (now distinct) literals; the clause-ref is appended to each watched literal's buffer and
the two watched codes are recorded in 'ssClauseW'. A unit clause is forced (enqueued at the current
level, reason = the clause). An empty clause is stored with no watch — it can never be repaired by BCP,
which is the correct "already conflicting" behaviour the initial propagate handles.
-}
attachClause :: (PrimMonad m) => SatState (PrimState m) -> Clause -> m ()
attachClause st cls0 = case normalizeClause cls0 of
  Nothing -> pure () -- a tautology constrains nothing; do not store or watch it.
  Just cls -> attachNormalized st cls

{- | Attach an already-normalized clause (distinct literals): store it, ensure its watch slots, and set
up its two watches (or force a unit / record an empty clause as the conflict).
-}
attachNormalized :: (PrimMonad m) => SatState (PrimState m) -> Clause -> m ()
attachNormalized st cls = do
  ref <- addClause (ssDB st) cls
  ensureClauseW st ref
  case cls of
    (a : b : _) -> do
      addWatcher st a ref
      addWatcher st b ref
      setClauseWatch st ref 0 a
      setClauseWatch st ref 1 b
    [a] -> do
      -- A unit clause: record a sentinel watch pair (the literal twice) and force it, guarding the
      -- value first so two contradictory input units (x) and (¬x) become a top-level conflict rather
      -- than a silent overwrite.
      setClauseWatch st ref 0 a
      setClauseWatch st ref 1 a
      enqueueLit st a ref
    [] ->
      -- An empty clause is unsatisfiable on its own: record it as the top-level conflict so the initial
      -- propagate reports Unsat. (BCP never repairs it; it has no literal to watch.)
      writeMutVar (ssConflict st) ref

{- | Learn a clause from conflict analysis: add it to the database and set up its two watches, but do
NOT enqueue anything — the caller (the Solver) enqueues the asserting literal explicitly with the
returned 'ClauseRef' as its reason, after the non-chronological backjump. The caller pre-orders the
learned clause so the asserting literal is first and the highest-level remaining literal is second; this
is the standard learned-clause watch placement (watch the asserting literal and the next-to-backtrack
literal) that keeps the two-watched invariant sound as the search later unwinds. A learned unit clause
(length 1) records a sentinel watch pair on its single literal; the caller forces it at the backjump
level (0). Returns the new clause's 'ClauseRef'.
-}
learnAndAttach :: (PrimMonad m) => SatState (PrimState m) -> Clause -> m ClauseRef
learnAndAttach st cls = do
  ref <- learnClause (ssDB st) cls
  ensureClauseW st ref
  case cls of
    (a : b : _) -> do
      addWatcher st a ref
      addWatcher st b ref
      setClauseWatch st ref 0 a
      setClauseWatch st ref 1 b
    [a] -> do
      setClauseWatch st ref 0 a
      setClauseWatch st ref 1 a
    [] ->
      -- An empty learned clause means the formula is unsatisfiable; record it as the conflict.
      writeMutVar (ssConflict st) ref
  pure ref

-- | Append a clause-ref to a literal's watch buffer (a doubling growable @Int@ buffer).
addWatcher :: (PrimMonad m) => SatState (PrimState m) -> Lit -> ClauseRef -> m ()
addWatcher st (Lit code) ref = do
  let ref' = ssWatch st V.! code
  (buf, used) <- readMutVar ref'
  let cap = UM.length buf
  buf' <-
    if used < cap
      then pure buf
      else UM.grow buf (max 1 cap)
  UM.write buf' used ref
  writeMutVar ref' (buf', used + 1)

-- | Remove the clause-ref at buffer index @i@ from a literal's watch buffer by swap-with-last + shrink.
removeWatcherAt :: (PrimMonad m) => SatState (PrimState m) -> Lit -> Int -> m ()
removeWatcherAt st (Lit code) i = do
  let ref' = ssWatch st V.! code
  (buf, used) <- readMutVar ref'
  -- swap the last element into slot i, then drop the last.
  when (i < used - 1) $ do
    lastRef <- UM.read buf (used - 1)
    UM.write buf i lastRef
  writeMutVar ref' (buf, used - 1)

-- | Grow 'ssClauseW' so slots @2*ref@ and @2*ref+1@ exist.
ensureClauseW :: (PrimMonad m) => SatState (PrimState m) -> ClauseRef -> m ()
ensureClauseW st ref = do
  (buf, used) <- readMutVar (ssClauseW st)
  let need = 2 * ref + 2
      cap = UM.length buf
  if need <= cap
    then writeMutVar (ssClauseW st) (buf, max used need)
    else do
      grown <- UM.grow buf (max need (cap + cap))
      writeMutVar (ssClauseW st) (grown, max used need)

-- | Record that watch @slot@ (0 or 1) of a clause is the given literal code.
setClauseWatch :: (PrimMonad m) => SatState (PrimState m) -> ClauseRef -> Int -> Lit -> m ()
setClauseWatch st ref slot (Lit code) = do
  (buf, _) <- readMutVar (ssClauseW st)
  UM.write buf (2 * ref + slot) code

-- | The two watched literal codes of a clause: @(watch0, watch1)@.
clauseWatches :: (PrimMonad m) => SatState (PrimState m) -> ClauseRef -> m (Int, Int)
clauseWatches st ref = do
  (buf, _) <- readMutVar (ssClauseW st)
  w0 <- UM.read buf (2 * ref)
  w1 <- UM.read buf (2 * ref + 1)
  pure (w0, w1)

-- | Open a new decision level and assign a decision literal (reason = -1) at that level.
decideLit :: (PrimMonad m) => SatState (PrimState m) -> Lit -> m ()
decideLit st lit = do
  lvl <- readMutVar (ssLevel st)
  let lvl' = lvl + 1
  writeMutVar (ssLevel st) lvl'
  levelCheckpoint (ssTrail st)
  assignLit (ssTrail st) lit lvl' (-1)

{- | Enqueue a forced literal at the current decision level with the given antecedent clause-ref as its
reason, guarding the literal's current value: if it is already true the clause is satisfied (no-op); if
it is already false this is a conflict (record the reason clause-ref in 'ssConflict'); only an unassigned
literal is actually assigned and pushed onto the trail for 'propagate' to pick up. The guard is what
makes two contradictory input unit clauses a sound 'Unsat' rather than a silent overwrite.
-}
enqueueLit :: (PrimMonad m) => SatState (PrimState m) -> Lit -> ClauseRef -> m ()
enqueueLit st lit rsn = do
  v <- litValue st lit
  case v of
    1 -> pure () -- already true: the clause is satisfied.
    0 -> writeMutVar (ssConflict st) rsn -- already false: a conflict.
    _ -> do
      lvl <- readMutVar (ssLevel st)
      assignLit (ssTrail st) lit lvl rsn

{- | Propagate unit consequences to a fixpoint. Drains the queue (the trail from 'ssQHead' to its head):
for each newly assigned literal @p@, every clause watching the now-false complement @negLit p@ is
visited and the three-outcome move logic applied. Returns 'Nothing' at a clean fixpoint, or
@Just clauseRef@ for the first clause that becomes fully false (a conflict). Mirrors the CP
'Lattice.CP.Queue.propagateM' worklist-drain shape; the move logic is the watched-literal scheme.
-}
propagate
  :: (PrimMonad m) => Emit m -> SatState (PrimState m) -> m (Maybe ClauseRef)
propagate emit st = loop
 where
  loop = do
    -- A conflict can be registered out of band: by attaching contradictory unit/empty clauses before
    -- the first propagate, or by a unit forced during BCP onto an already-false literal. Surface it.
    pending <- readMutVar (ssConflict st)
    if pending >= 0
      then do
        writeMutVar (ssConflict st) (-1)
        pure (Just pending)
      else do
        qh <- readMutVar (ssQHead st)
        n <- trailSize (ssTrail st)
        if qh >= n
          then pure Nothing -- queue drained: fixpoint
          else do
            raw <- trailLitAt (ssTrail st) qh
            writeMutVar (ssQHead st) (qh + 1)
            let p = Lit raw
            -- p was just assigned true, so negLit p is now false: visit clauses watching it.
            confl <- visitWatchers (negLit p)
            case confl of
              Just c -> pure (Just c)
              Nothing -> loop

  -- Visit every clause watching the falsified literal @fl@, applying the move logic. Walks the watch
  -- buffer by index; a moved watch is removed (swap-with-last), so the index is only advanced when the
  -- watch stays put.
  visitWatchers fl@(Lit flCode) = go 0
   where
    go i = do
      (_, used) <- readMutVar (ssWatch st V.! flCode)
      if i >= used
        then pure Nothing
        else do
          (buf, _) <- readMutVar (ssWatch st V.! flCode)
          ref <- UM.read buf i
          outcome <- visitClause fl ref
          case outcome of
            Conflict -> pure (Just ref)
            Moved -> go i -- this slot now holds the swapped-in last watcher; re-examine it
            Kept -> go (i + 1)

  -- The three-outcome move logic for one clause that watches the falsified literal @fl@.
  visitClause fl@(Lit flCode) ref = do
    (w0, w1) <- clauseWatches st ref
    -- This clause is in fl's watch list, so fl is one of the two watches; "the other" is the other
    -- slot. flSlot is the slot fl occupies (where a moved watch's new literal is recorded).
    let (otherCode, flSlot)
          | w0 == flCode = (w1, 0)
          | otherwise = (w0, 1)
        other = Lit otherCode
    otherV <- litValue st other
    if otherV == 1
      then pure Kept -- (a) the other watch is already true: clause satisfied, leave the watch.
      else do
        -- (b) scan for a non-false literal q that is neither watch; if found, move the watch to it.
        lits <- clauseLits (ssDB st) ref
        mq <- findNonFalse st lits flCode otherCode
        case mq of
          Just qCode -> do
            -- move: drop ref from fl's buffer, append to q's buffer, update the clause's watch slot.
            removeWatcherAt st fl =<< watcherIndex st fl ref
            addWatcher st (Lit qCode) ref
            setClauseWatch st ref flSlot (Lit qCode)
            pure Moved
          Nothing ->
            -- (c) no replacement: the other watch decides.
            if otherV == 0
              then pure Conflict -- the other watch is false: the whole clause is false.
              else do
                -- the other watch is unassigned: the clause is unit, force it.
                enqueueLit st other ref
                emit (Ev.Propagate (litVar other) (if litPos other then 1 else 0))
                pure Kept

-- | The buffer index of a clause-ref within a literal's watch buffer (it is present by construction).
watcherIndex :: (PrimMonad m) => SatState (PrimState m) -> Lit -> ClauseRef -> m Int
watcherIndex st (Lit code) ref = do
  (buf, used) <- readMutVar (ssWatch st V.! code)
  let scan !i
        | i >= used = pure 0 -- unreachable: ref is present by the watched-literal invariant
        | otherwise = do
            r <- UM.read buf i
            if r == ref then pure i else scan (i + 1)
  scan 0

{- | Find a literal code in the clause that is not false and is neither of the two current watches, to
move a watch to. Returns the first such literal's code, or 'Nothing' if every non-watch literal is false.
-}
findNonFalse
  :: (PrimMonad m) => SatState (PrimState m) -> U.Vector Int -> Int -> Int -> m (Maybe Int)
findNonFalse st lits w0 w1 = go 0
 where
  n = U.length lits
  go !i
    | i >= n = pure Nothing
    | otherwise = do
        let code = lits U.! i
        if code == w0 || code == w1
          then go (i + 1)
          else do
            v <- litValue st (Lit code)
            if v == 0 then go (i + 1) else pure (Just code)

-- | A literal's value under the trail: @1@ true, @0@ false, @-1@ unassigned.
litValue :: (PrimMonad m) => SatState (PrimState m) -> Lit -> m Int
litValue st lit = do
  v <- varValue (ssTrail st) (litVar lit)
  pure $ case v of
    -1 -> -1
    _ -> if (v == 1) == litPos lit then 1 else 0

-- | A variable's raw value (@-1@/@0@/@1@), used by the loop to detect a complete assignment.
stateValueOf :: (PrimMonad m) => SatState (PrimState m) -> Var -> m Int
stateValueOf st = varValue (ssTrail st)

-- | The current decision level.
currentLevel :: (PrimMonad m) => SatState (PrimState m) -> m Int
currentLevel st = readMutVar (ssLevel st)

{- | The two-watched-literal invariant checker (SAT-01). Scans every clause and confirms it watches two
non-false literals, OR is unit (a watch unassigned, the rest false) OR conflicting (all literals false).
A clause of length < 2 is exempt (a unit clause is always "forced or satisfied", an empty one is the
formula's conflict). Returns 'True' when the invariant holds. Called only behind a 'Bool' flag that is
'False' in fast mode (so it constant-folds away) and 'True' in the test build — not via the base
library's optimizer-dropped assertion combinator, which @-O@ silently removes.
-}
checkInvariant :: (PrimMonad m) => SatState (PrimState m) -> m Bool
checkInvariant st = do
  n <- clauseCountOf st
  foldM step True [0 .. n - 1]
 where
  step False _ = pure False
  step True ref = do
    lits <- clauseLits (ssDB st) ref
    if U.length lits < 2
      then pure True -- unit/empty clauses are exempt from the two-watch invariant.
      else do
        (w0, w1) <- clauseWatches st ref
        v0 <- litValue st (Lit w0)
        v1 <- litValue st (Lit w1)
        -- Holds when neither watch is false, or the clause is genuinely unit/conflicting.
        if v0 /= 0 && v1 /= 0
          then pure True
          else do
            allFalse <- allLitsFalse st lits
            pure (allFalse || someWatchHolds v0 v1)
  -- A repaired-but-not-yet-checked corner: if a watch is false the clause must be unit (other watch
  -- non-false and all non-watch literals false) or fully false. someWatchHolds permits the unit shape.
  someWatchHolds v0 v1 = (v0 /= 0) /= (v1 /= 0)

-- | Are all literals of a clause false under the current trail?
allLitsFalse :: (PrimMonad m) => SatState (PrimState m) -> U.Vector Int -> m Bool
allLitsFalse st lits = go 0
 where
  n = U.length lits
  go !i
    | i >= n = pure True
    | otherwise = do
        v <- litValue st (Lit (lits U.! i))
        if v == 0 then go (i + 1) else pure False

-- | The number of clauses currently in the database.
clauseCountOf :: (PrimMonad m) => SatState (PrimState m) -> m Int
clauseCountOf st = do
  (_, used) <- readMutVar (ssClauseW st)
  pure (used `div` 2)

-- | The move-logic outcome for one visited clause.
data Outcome = Kept | Moved | Conflict
