{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}

{- | The CDCL solver entry points, mirroring the CP 'Lattice.CP.Solver' two-mode shape one-to-one.
'solveSat' is fast mode: 'runST' with the no-op emit, which @-O@ specializes-and-deletes so the loop is
a tight allocation-free 'ST' loop over the mutable spine. 'cdclLoop' is the loop generic over
'PrimMonad', threading an 'Emit' callback, marked @INLINEABLE@ so GHC specializes the emit per mode — the
EVENT-02 precedent re-applied to SAT. The fast-mode emit must vanish; the @-ddump-simpl@ acceptance check
confirms no 'Lattice.Event' constructor survives in the fast path.

This is real CDCL: decide a variable at a fresh level (saved phase first), propagate via watched-literal
BCP, and on a conflict run 'analyze1UIP' to learn an asserting clause and a non-chronological backjump
level. The learned clause is added to the database and watched, the trail is unwound straight to the
backjump level (not merely one level up), and the asserting literal is enqueued as a unit forced by the
new clause — the search then propagates from there. A conflict at level 0 (or an empty learned clause)
is 'Unsat'. The load-bearing correctness gate is the implied-clause property (every learned clause is
implied by the formula, @formula AND not-clause@ UNSAT by the @2^n@ oracle) plus the brute-vs-SAT
differential with learning enabled.

The trail is the single source of truth for undo: 'Lattice.SAT.Trail.unwindTo' resets value/level/reason
for every popped literal in lock-step, and the propagation queue head is clamped to the trail size after
each unwind, so trail, level, and queue never desync on a non-chronological backjump.
-}
module Lattice.SAT.Solver (
  solveSat,
  solveSatTrace,
  solveSatLearned,
  solveSatLearnedAtLevels,
  cdclLoop,
) where

import Control.Monad (forM_)
import Control.Monad.Primitive (PrimMonad, PrimState)
import Control.Monad.ST (runST)
import Data.Primitive.MutVar (MutVar, newMutVar, readMutVar, writeMutVar)
import Lattice.Core.Types (Level)
import Lattice.Event (Emit)
import Lattice.Event qualified as Ev
import Lattice.SAT.Analyze (analyze1UIP)
import Lattice.SAT.Trail (trailSize, unwindTo, varLevel, varValue)
import Lattice.SAT.Types (CNF (..), Lit, SatResult (..), litPos, litVar, mkLit)
import Lattice.SAT.VSIDS (
  VSIDS,
  branchPhase,
  bumpActivity,
  decayActivity,
  luby,
  newVSIDS,
  pickBranch,
 )
import Lattice.SAT.Watched (
  SatState (..),
  currentLevel,
  decideLit,
  enqueueLit,
  learnAndAttach,
  newState,
  propagate,
 )

{- | A callback invoked with each learned clause as it is learned (the conflict-level passed alongside),
so a test-only solve can collect the clauses. Fast mode passes the no-op 'noLearnHook'.
-}
type LearnHook m = [Lit] -> Level -> m ()

-- | The fast-mode learn sink: ignore every learned clause. Constant-folds away under @-O@.
noLearnHook :: (Applicative m) => LearnHook m
noLearnHook _ _ = pure ()
{-# INLINE noLearnHook #-}

{- | Solve a CNF in fast mode: 'Sat' with a model (the list of true literals) or a sound 'Unsat'.
'runST' with 'Ev.noEmit' and the no-op learn hook; the @INLINE@ lets GHC drop both the dead emit and the
'Event' construction.
-}
solveSat :: CNF -> SatResult
solveSat cnf = runST $ do
  st <- newState (cnfVars cnf) (cnfClauses cnf)
  vs <- newVSIDS (cnfVars cnf)
  cdclLoop Ev.noEmit noLearnHook st vs
-- The INLINE + INLINEABLE pair lets GHC specialize the no-op emit and learn hook to nothing in fast
-- mode (verified with -ddump-simpl: no Lattice.Event constructor and no learn-hook call survive).
{-# INLINE solveSat #-}

{- | Solve a CNF in trace mode, streaming the SAT reasoning as events: a 'Ev.Decision' per branch
(@cell@ = variable, @value@ = polarity 0/1, @level@ = decision level) for the CHOSEN literal, a
'Ev.Propagate' per FORCED literal — both the unit-propagation consequences (from BCP) and the
post-backjump asserting literal, which is forced by the just-learned clause (@cell@ = variable,
@value@ = polarity 0/1) — a 'Ev.Conflict' on a falsified clause, a 'Ev.Learned' clause from 1UIP
analysis (literals in signed variable coordinates), a 'Ev.Backtrack' to the non-chronological backjump
(or to 0 on a restart), a 'Ev.Restart' when the Luby schedule fires, and a final 'Ev.Solution' or
'Ev.Unsat'. The decision/propagate split is the trail view's "chosen vs forced" second signal (the
decision ring vs the plain propagated border). The result is identical to 'solveSat'; only the stream
differs. Mirrors 'Lattice.CP.Solver.solveTrace' — the same 'cdclLoop' instantiated in 'IO' (both are
'PrimMonad') with a streaming emit and the no-op learn hook (the learn hook is the test-only clause
collector; the trace @learn@ event is emitted by the loop).
-}
solveSatTrace :: Emit IO -> CNF -> IO SatResult
solveSatTrace emit cnf = do
  st <- newState (cnfVars cnf) (cnfClauses cnf)
  vs <- newVSIDS (cnfVars cnf)
  cdclLoop emit noLearnHook st vs

{- | A test-only solve that also returns every clause the solver learned, for the implied-clause
property (each learned clause must be implied by the formula). Runs in 'ST' with a collecting hook; the
result is identical to 'solveSat'. Not for production use — the collector list allocates.
-}
solveSatLearned :: CNF -> (SatResult, [[Lit]])
solveSatLearned cnf = runST $ do
  st <- newState (cnfVars cnf) (cnfClauses cnf)
  vs <- newVSIDS (cnfVars cnf)
  acc <- newMutVar []
  let hook c _lvl = modifyMutVar acc (c :)
  res <- cdclLoop Ev.noEmit hook st vs
  learned <- readMutVar acc
  pure (res, reverse learned)

{- | A test-only solve that returns every learned clause paired with the decision level current when it
was learned, each literal tagged with its assignment level at that moment, for the asserting-clause
property (exactly one literal at the conflict's current level). Runs in 'ST'; the result matches
'solveSat'. The per-literal levels are read at learn time, before the backjump unwinds them.
-}
solveSatLearnedAtLevels :: CNF -> (SatResult, [([(Lit, Level)], Level)])
solveSatLearnedAtLevels cnf = runST $ do
  st <- newState (cnfVars cnf) (cnfClauses cnf)
  vs <- newVSIDS (cnfVars cnf)
  acc <- newMutVar []
  let hook c lvl = do
        tagged <- mapM (\l -> (,) l <$> varLevel (ssTrail st) (litVar l)) c
        modifyMutVar acc ((tagged, lvl) :)
  res <- cdclLoop Ev.noEmit hook st vs
  entries <- readMutVar acc
  pure (res, reverse entries)

{- | Strict in-place modify for the collector 'MutVar' (the test-only learned-clause sink). The new
value is forced with @($!)@ before it is stored, so the collector holds a proper @(c : cs)@ cons cell
rather than an unevaluated @(c :)@ thunk chain that would only be forced at @readMutVar acc@ at the end
of a long solve (a space leak, the lazy-value-forced-late class Phase 4 flagged). Equivalent to
@Data.Primitive.MutVar.modifyMutVar'@, written out to keep the import surface unchanged.
-}
modifyMutVar :: (PrimMonad m) => MutVar (PrimState m) a -> (a -> a) -> m ()
modifyMutVar ref f = do
  x <- readMutVar ref
  writeMutVar ref $! f x

{- | The base unit of the Luby restart schedule: the solver restarts after @lubyUnit * luby i@
conflicts for the restart index @i@. A small constant keeps the FLEX tier's tiny instances restarting
often enough to exercise the schedule (and phase saving) without thrashing.
-}
lubyUnit :: Int
lubyUnit = 32

{- | The CDCL loop generic over the monad. Runs the initial propagation of the input's unit clauses,
then the decide/propagate/analyze/backjump cycle, now driven by the VSIDS heuristics: 'pickBranch' picks
the highest-activity unassigned variable, 'branchPhase' supplies the saved polarity, each conflict bumps
the learned clause's variables and decays the increment, and the trail restarts on the Luby schedule
(unwind to level 0, keeping the learned clauses and the activities). @INLINEABLE@ so the 'Emit' and the
learn hook specialize per mode and the fast-mode no-ops vanish.
-}
cdclLoop
  :: (PrimMonad m)
  => Emit m
  -> LearnHook m
  -> SatState (PrimState m)
  -> VSIDS (PrimState m)
  -> m SatResult
cdclLoop emit learn st vs = do
  -- The initial propagation: unit clauses in the input force assignments at level 0. A conflict here
  -- (contradictory unit clauses, or an empty clause) means the formula is unsatisfiable outright.
  confl0 <- propagate emit st
  case confl0 of
    -- Contradictory input units (or an empty clause) are unsatisfiable outright. Emit the conflict AND
    -- the terminal Unsat so a trace consumer sees the result and stops waiting (the other two level-0
    -- Unsat exits in handleConflict emit Ev.Unsat too; this one must as well or the client spins).
    Just _ -> emit (Ev.Conflict 0) >> emit Ev.Unsat >> pure Unsat
    -- Drive from restart index 1 with no conflicts yet accumulated against the first Luby budget.
    Nothing -> drive 1 0
 where
  -- The iterative CDCL driver, threading the Luby restart index @i@ and the conflict count since the
  -- last restart. Each step either resolves a conflict (analyze, learn, bump, decay, non-chronological
  -- backjump, enqueue the asserting literal) or, at a clean fixpoint, decides the next variable via
  -- VSIDS. A conflict above level 0 is learned from; a conflict at level 0 is Unsat.
  drive !i !confls =
    pickBranch st vs >>= \case
      Nothing -> do
        model <- readModel st
        emit (Ev.Solution (map litPair model))
        pure (Sat model)
      Just v -> do
        ph <- branchPhase st v -- phase saving: branch the saved polarity.
        decideLit st (mkLit v ph)
        -- Stream the decision so the trail view shows a CHOSEN literal (the accent-ring cell) distinct
        -- from a forced one. `cell` = variable, `value` = polarity 0/1, `level` = the just-opened
        -- decision level — the shape the front end's `decision` arm reads (and snapshots for backjump
        -- un-fill). Behind `emit`, so fast-mode `solveSat` deletes it (the -ddump-simpl check).
        dl <- currentLevel st
        emit (Ev.Decision v (if ph then 1 else 0) dl)
        propagateThen i confls

  -- Propagate after a decision or a forced asserting literal; branch on a conflict.
  propagateThen !i !confls =
    propagate emit st >>= \case
      Nothing -> drive i confls
      Just confl -> handleConflict i confls confl

  -- A conflict: at level 0 it is unsatisfiable; above level 0, learn a 1UIP clause, bump the clause's
  -- variables, decay the increment, backjump, then assert the unit. After the backjump, restart on the
  -- Luby schedule if the conflict budget for this restart index is spent.
  handleConflict !i !confls confl = do
    lvl <- currentLevel st
    if lvl <= 0
      then emit Ev.Unsat >> pure Unsat
      else do
        (learned, bj) <- analyze1UIP st confl
        emit (Ev.Conflict (conflVar learned))
        learn learned lvl
        -- The trace `learn` event: the learned clause as signed variable ids (puzzle coordinates,
        -- the DIMACS convention — a positive id is a true literal, a negative id a false one), never
        -- the internal 2*var+sign code. In fast mode the no-op emit and this construction vanish.
        emit (Ev.Learned (map litSigned learned))
        bumpClause learned -- VSIDS: bump the conflict-side (learned-clause) variables.
        decayActivity vs -- and grow the increment once per conflict (EVSIDS decay).
        case learned of
          [] -> emit Ev.Unsat >> pure Unsat -- an empty learned clause is outright Unsat
          (asserting : _) -> do
            -- Order the learned clause so the asserting literal is watched first and the highest-level
            -- remaining literal second (the standard learned-clause watch placement), then add+watch it.
            ordered <- orderForWatch st learned
            ref <- learnAndAttach st ordered
            backjumpTo bj
            -- The asserting literal is forced by the new clause: enqueue it at the backjump level.
            enqueueLit st asserting ref
            -- Stream the asserting literal as a FORCED assignment (a propagate, not a decision: it is
            -- implied by the learned clause, so the trail view gives it the plain "propagated" border,
            -- not the decision ring). `cell` = variable, `value`/`removed` = its polarity. Behind
            -- `emit`, so fast mode deletes it like the propagate emits in BCP.
            emit (Ev.Propagate (litVar asserting) (if litPos asserting then 1 else 0))
            maybeRestart i (confls + 1)

  -- After a conflict, decide whether to restart: once the conflicts since the last restart reach
  -- @lubyUnit * luby i@, unwind to level 0 (keeping learned clauses and activities), advance the
  -- restart index, and reset the conflict count. Otherwise keep propagating the just-asserted literal.
  maybeRestart !i !confls
    | confls >= lubyUnit * luby i = do
        backjumpTo 0 -- restart: erase only the assignment; learned clauses and activities persist.
        emit Ev.Restart -- the trace `restart` event; the no-op emit deletes it in fast mode.
        drive (i + 1) 0
    | otherwise = propagateThen i confls

  -- Bump the VSIDS activity of every variable in the learned (conflict-side) clause.
  bumpClause lits = forM_ lits (bumpActivity vs . litVar)

  -- Non-chronological unwind to the backjump level and re-sync the loop bookkeeping: drop everything
  -- above @bj@, reset the decision level, and clamp the propagation queue head to the (shorter) trail.
  -- This is the non-chronological backjump that replaced the plan-02 chronological backtrack; a Luby
  -- restart reuses it with @bj = 0@ (the restart keeps the clause DB and activities — it never rebuilds
  -- them; only the trail assignment is erased).
  --
  -- CONVENTION NOTE (WR-01): 'Lattice.SAT.Trail.unwindTo' drops level @bj@ ITSELF (truncating to where
  -- @bj@ opened), diverging from MiniSat @cancelUntil@, which keeps @bj@. So the @enqueueLit asserting@
  -- below puts the asserting literal at @bj@ as the only literal there and the learned clause is NOT
  -- unit in the MiniSat sense (its second-highest literal, at @bj@, is un-assigned by this unwind).
  -- That is sound: the assert still advances the search and every learned clause stays implied — locked
  -- by the @sat/analyze@ "WR-01 lock" and implied-clause properties. See the 'unwindTo' header.
  backjumpTo bj = do
    unwindTo (ssTrail st) bj
    writeMutVar (ssLevel st) bj
    n <- trailSize (ssTrail st)
    writeMutVar (ssQHead st) n
    emit (Ev.Backtrack bj)

  conflVar (l : _) = litVar l
  conflVar [] = 0
{-# INLINEABLE cdclLoop #-}

{- | Order a learned clause for watching: the asserting literal (caller-guaranteed first) stays first,
and the literal with the highest assignment level among the rest moves to second. Watching the asserting
literal and the highest-level other literal keeps the two-watched invariant sound as the search later
unwinds, mirroring the MiniSat learned-clause watch placement. A unit clause is returned unchanged.
-}
orderForWatch :: (PrimMonad m) => SatState (PrimState m) -> [Lit] -> m [Lit]
orderForWatch _ [] = pure []
orderForWatch _ [a] = pure [a]
orderForWatch st (a : rest) = do
  leveled <- mapM (\l -> (,) l <$> varLevel (ssTrail st) (litVar l)) rest
  let (hi, others) = pickMax leveled
  pure (a : hi : map fst others)
 where
  -- Split off the literal with the maximum level; keep the others in their original relative order.
  pickMax (x : xs) = go x [] xs
   where
    go best acc [] = (fst best, reverse acc)
    go best acc (y : ys)
      | snd y > snd best = go y (best : acc) ys
      | otherwise = go best (y : acc) ys
  pickMax [] = error "orderForWatch: pickMax on empty (unreachable; rest is non-empty here)"

-- | Read the full model off the trail: every variable's true literal under the current assignment.
readModel :: (PrimMonad m) => SatState (PrimState m) -> m [Lit]
readModel st = go 0 []
 where
  n = ssVars st
  go !v acc
    | v >= n = pure (reverse acc)
    | otherwise = do
        val <- varValue (ssTrail st) v
        go (v + 1) (mkLit v (val == 1) : acc)

-- | A literal as a @(var, polarity)@ pair for the 'Ev.Solution' event (0/1 polarity, puzzle coordinates).
litPair :: Lit -> (Int, Int)
litPair l = (litVar l, if litPos l then 1 else 0)

{- | A literal as a signed 1-based variable id for the 'Ev.Learned' event, the DIMACS convention the
front end reads: variable @v@ is @v + 1@, positive when the literal is positive and negated when it is
negative. This keeps the wire in puzzle coordinates (a signed variable id), never the internal
@2*var+sign@ code. The 1-based shift is what gives variable 0 a sign (it would be @0@, unsignable,
otherwise) — the same mapping 'Lattice.SAT.Dimacs.printDimacs' uses.
-}
litSigned :: Lit -> Int
litSigned l = let v = litVar l + 1 in if litPos l then v else negate v
