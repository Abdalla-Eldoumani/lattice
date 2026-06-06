{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE StrictData #-}

{- | The clause database: a growable store of clauses, each held as an immutable unboxed vector of
the raw 'Int' literal encodings, indexed by a 'ClauseRef'. Original clauses (from the CNF) and
learned clauses (from conflict analysis) live in the same store; a 'ClauseRef' is the antecedent edge
the trail records and the 1UIP walk follows.

The layout is the idiomatic starting point: a boxed @MVector s (Unboxed.Vector Int)@ — one immutable
unboxed literal vector per clause — wrapped in an 'STRef'-style growable buffer that doubles its
capacity on overflow. @grow@ allocates a new vector and copies, so growing by one per append would be
O(n^2); doubling makes a sequence of appends amortized O(1). Generic over 'PrimMonad' so the same
code runs in fast 'ST' and trace 'IO' modes, exactly like the CP loop.
-}
module Lattice.SAT.ClauseDB (
  ClauseRef,
  ClauseDB,
  newClauseDB,
  addClause,
  learnClause,
  clauseLits,
  clauseCount,
) where

import Control.Monad.Primitive (PrimMonad, PrimState)
import Data.Primitive.MutVar (MutVar, newMutVar, readMutVar, writeMutVar)
import Data.Vector.Mutable qualified as MV
import Data.Vector.Unboxed qualified as U
import Lattice.SAT.Types (Clause, Lit (..))

-- | A reference into the clause database: the index of a stored clause (@0 .. clauseCount - 1@).
type ClauseRef = Int

{- | The growable clause store. The 'MutVar' holds the boxed backing vector (whose slots beyond
@used@ are unwritten) and the count of clauses actually stored.

-- >>> FLAT ARENA UPGRADE SLOT <<<
-- (One big @MVector s Int@ literal arena plus a boxed index of @(start, len)@ spans would replace the
-- boxed vector-of-vectors here, trading the per-clause pointer indirection and per-learned-clause
-- allocation for offset arithmetic. The boxed layout below is the legible MVP; the flat arena is the
-- performance upgrade, mirroring the REGIN / LINE-AC upgrade slots in "Lattice.CP.Propagator".)
-}
data ClauseDB s = ClauseDB
  { dbStore :: MutVar s (MV.MVector s (U.Vector Int))
  , dbUsed :: MutVar s Int
  }

{- | A fresh, empty clause database with a small initial capacity. Capacity grows by doubling as
clauses are added, so the initial value only affects how many early reallocations happen.
-}
newClauseDB :: (PrimMonad m) => m (ClauseDB (PrimState m))
newClauseDB = do
  let cap0 = 16
  backing <- MV.new cap0
  store <- newMutVar backing
  used <- newMutVar 0
  pure ClauseDB {dbStore = store, dbUsed = used}

{- | Append a clause (an original or a learned one) to the store and return its 'ClauseRef'. The
clause is frozen into an immutable unboxed vector of raw literal encodings, preserving literal order.
-}
pushClause :: (PrimMonad m) => ClauseDB (PrimState m) -> Clause -> m ClauseRef
pushClause db cls = do
  let !frozen = U.fromList [l | Lit l <- cls]
  used <- readMutVar (dbUsed db)
  backing <- readMutVar (dbStore db)
  let cap = MV.length backing
  backing' <-
    if used < cap
      then pure backing
      else do
        -- grow allocates a new, larger vector and copies; double the capacity for amortized O(1).
        grown <- MV.grow backing (max 1 cap)
        writeMutVar (dbStore db) grown
        pure grown
  MV.write backing' used frozen
  writeMutVar (dbUsed db) (used + 1)
  pure used

-- | Add an original clause from the input formula. Returns its 'ClauseRef'.
addClause :: (PrimMonad m) => ClauseDB (PrimState m) -> Clause -> m ClauseRef
addClause = pushClause

{- | Add a clause learned by conflict analysis. Structurally identical to 'addClause' (same store);
the distinct name documents intent at the call site, mirroring the planned 1UIP integration.
-}
learnClause :: (PrimMonad m) => ClauseDB (PrimState m) -> Clause -> m ClauseRef
learnClause = pushClause

{- | The literals of a stored clause, as the immutable unboxed vector of raw 'Int' encodings. Callers
wrap each element back in 'Lit' as needed; the raw vector stays unboxed for the hot loop.
-}
clauseLits :: (PrimMonad m) => ClauseDB (PrimState m) -> ClauseRef -> m (U.Vector Int)
clauseLits db ref = do
  backing <- readMutVar (dbStore db)
  MV.read backing ref

-- | The number of clauses currently stored.
clauseCount :: (PrimMonad m) => ClauseDB (PrimState m) -> m Int
clauseCount db = readMutVar (dbUsed db)
