{-# LANGUAGE BangPatterns #-}

{- | First-UIP (1UIP) conflict analysis: the heart of CDCL learning. Given the clause that became
all-false during propagation, 'analyze1UIP' walks the implication graph backward along the trail,
resolving each conflict-side literal against the reason (antecedent) clause that forced it, until
exactly one literal assigned at the current decision level remains — the /first unique implication
point/. That literal, negated, is the asserting literal of the learned clause; the rest of the clause
is the lower-level literals seen during resolution. The backjump level is the second-highest decision
level among the learned clause's literals (0 when the clause is unit), and it is non-chronological: the
solver unwinds straight to that level, not merely one level up.

There is NO repo analog for this — the CP engine backtracks chronologically and never analyzes a
conflict. The algorithm is the standard counter formulation (MiniSat @analyze@ / the GRASP first-UIP
scheme), sourced from the SAT literature, not from a copyable file:

  * Seed a per-variable @seen@ marker and a @counter@ of how many marked literals are at the current
    decision level. Mark every literal of the conflict clause (skipping level-0 literals, which are
    permanently fixed and never belong in a learned clause); count those at the current level and route
    the lower-level ones straight into the learned clause.
  * Walk the trail BACKWARD to the most recently assigned still-@seen@ literal @p@ at the current level.
    Resolve: replace @p@ by the other literals of its reason clause (mark new ones, counting/recording
    them the same way), unmark @p@, and decrement the counter.
  * Stop when @counter == 1@ — exactly one literal at the current level is left. That surviving literal
    is the UIP. The asserting literal is its negation; it leads the learned clause.

THE STOP CONDITION IS THE PITFALL: resolve while more than one current-level literal is marked, stop at
one. Stopping early yields a non-asserting clause that loops the search; stopping late over-resolves.
The mandatory guard is the implied-clause property (the test suite): @formula AND not-learnedClause@ is
UNSAT by the @2^n@ oracle, so every learned clause is genuinely implied by the formula.

Generic over 'PrimMonad' so the same code runs in fast 'ST' and trace 'IO', like the rest of the engine.
-}
module Lattice.SAT.Analyze (
  analyze1UIP,
) where

import Control.Monad.Primitive (PrimMonad, PrimState)
import Data.Primitive.MutVar (readMutVar)
import Data.Vector.Unboxed qualified as U
import Data.Vector.Unboxed.Mutable qualified as UM
import Lattice.Core.Types (Level)
import Lattice.SAT.ClauseDB (ClauseRef, clauseLits)
import Lattice.SAT.Trail (trailLitAt, trailSize, varLevel, varReason)
import Lattice.SAT.Types (Lit (..), litVar, negLit)
import Lattice.SAT.Watched (SatState (..))

{- | Analyze a conflict by first-UIP resolution. Returns the learned clause (the asserting literal
first, then the lower-level literals) and the non-chronological backjump level (the second-highest
decision level among the learned literals, or 0 if the clause is unit). The caller learns the clause,
unwinds to the returned level, and enqueues the asserting literal as a unit forced by the new clause.
-}
analyze1UIP
  :: (PrimMonad m) => SatState (PrimState m) -> ClauseRef -> m ([Lit], Level)
analyze1UIP st confl = do
  dl <- readMutVar (ssLevel st)
  -- A per-variable "seen" marker so each variable is resolved at most once. Allocated per analysis;
  -- the instances are small (FLEX tier) so the allocation is not on a hot industrial path.
  seen <- UM.replicate (max 0 (ssVars st)) False
  tn <- trailSize (ssTrail st)
  -- Seed from the conflict clause: mark its literals, counting current-level ones and collecting
  -- lower-level ones into the learned accumulator. No literal has been resolved on yet (no skip var).
  (counter0, learned0) <- absorb dl seen Nothing confl (0 :: Int) []
  -- Walk the trail backward, resolving the top still-seen current-level literal, until one remains.
  let loop !ti !counter !learned
        | counter <= 1 = do
            -- Exactly one current-level literal is marked: find it (the UIP) and assert its negation.
            (uip, _) <- topSeen seen ti
            pure (negLit uip : reverse learned)
        | otherwise = do
            (p, ti') <- topSeen seen ti
            -- Resolve p against its reason clause; unmark p and absorb the reason's other literals.
            UM.write seen (litVar p) False
            rsn <- varReason (ssTrail st) (litVar p)
            (counter', learned') <- absorb dl seen (Just (litVar p)) rsn (counter - 1) learned
            loop (ti' - 1) counter' learned'
  learnedClause <- loop (tn - 1) counter0 learned0
  bj <- backjumpLevel st learnedClause
  pure (learnedClause, bj)
 where
  -- Absorb the literals of clause @ref@ into the analysis: for each literal not yet seen and assigned
  -- above level 0, mark it, then either count it (current level) or route it into the learned clause
  -- (lower level). The literal whose variable is @skip@ (the one being resolved on) is not re-absorbed.
  absorb dl seen skip ref counter learned = do
    lits <- clauseLits (ssDB st) ref
    let n = U.length lits
        go !i !c !acc
          | i >= n = pure (c, acc)
          | otherwise = do
              let l = Lit (lits U.! i)
                  v = litVar l
              if Just v == skip
                then go (i + 1) c acc
                else do
                  already <- UM.read seen v
                  if already
                    then go (i + 1) c acc
                    else do
                      lvl <- varLevel (ssTrail st) v
                      if lvl <= 0
                        then go (i + 1) c acc -- a level-0 literal is permanently fixed; drop it.
                        else do
                          UM.write seen v True
                          if lvl == dl
                            then go (i + 1) (c + 1) acc -- still at the current level: count it.
                            else go (i + 1) c (l : acc) -- a lower-level literal joins the clause.
    go 0 counter learned

  -- Walk the trail backward from index @ti@ to the most recently assigned literal whose variable is
  -- still marked @seen@, returning that literal and the index it sat at. Present by construction while
  -- a current-level literal is still marked.
  topSeen seen = goTop
   where
    goTop !i
      | i < 0 = pure (Lit 0, 0) -- unreachable while a current-level literal remains marked
      | otherwise = do
          raw <- trailLitAt (ssTrail st) i
          let l = Lit raw
          marked <- UM.read seen (litVar l)
          if marked then pure (l, i) else goTop (i - 1)

{- | The backjump level: the second-highest decision level among the learned clause's literals, or 0
when the clause has a single literal (a unit clause asserts at the root). The highest level is the
asserting literal's own (the current level); the second-highest is where the clause becomes unit again.
-}
backjumpLevel
  :: (PrimMonad m) => SatState (PrimState m) -> [Lit] -> m Level
backjumpLevel st clause = do
  levels <- mapM (varLevel (ssTrail st) . litVar) clause
  pure (secondHighest levels)

{- | The second-highest level among the learned clause's literals. The asserting literal sits at the
current (highest) level; the next-highest is the backjump target, where the clause becomes unit again.
With fewer than two assigned literals (a unit learned clause) the answer is 0, the root. Unassigned
literals (level @-1@, which a correct 1UIP clause does not contain) cannot raise the result above 0.
-}
secondHighest :: [Level] -> Level
secondHighest xs = go xs 0 0
 where
  go [] _ second = second
  go (x : rest) first second
    | x > first = go rest x first
    | x < first && x > second = go rest first x
    | otherwise = go rest first second
