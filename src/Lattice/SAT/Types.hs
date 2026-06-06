{-# LANGUAGE StrictData #-}

{- | The SAT engine's pure data types: variables, the MiniSat literal encoding, clauses, a CNF
formula, and the solve result. Pure data only; the mutable stores ("Lattice.SAT.ClauseDB",
"Lattice.SAT.Trail") and the algorithms build on these.

The literal encoding is MiniSat-style: an internal variable is 0-based, and a literal is the index
@2*var + sign@ (sign 0 = positive, 1 = negative). Encoding a literal as a single 'Int' index is what
lets the watch lists and the VSIDS activity array be flat unboxed vectors with O(1) lookup. The
DIMACS 1-based signed integers are mapped to this encoding at the parse boundary only
("Lattice.SAT.Dimacs"); the engine never sees DIMACS coordinates.

'Lit' is a newtype around 'Int' so a raw array index is never confused with an encoded literal — the
same discipline 'Lattice.Core.Types.Domain' applies to a bare 'IntSet'.
-}
module Lattice.SAT.Types (
  Var,
  Lit (..),
  mkLit,
  litVar,
  litSign,
  litPos,
  negLit,
  Clause,
  CNF (..),
  SatResult (..),
) where

import Data.Bits (shiftL, shiftR, xor, (.&.))

-- | An internal variable index, 0-based (@0 .. cnfVars - 1@). DIMACS @v@ maps to @v - 1@.
type Var = Int

{- | A literal, MiniSat-encoded as @2*var + sign@ (sign 0 = positive, 1 = negative). The newtype
keeps an encoded literal distinct from a raw 'Int' index at the type level.
-}
newtype Lit = Lit Int
  deriving (Eq, Ord, Show)

{- | Build a literal from a variable and its polarity. @True@ is the positive literal (sign 0),
@False@ the negative (sign 1).
-}
mkLit :: Var -> Bool -> Lit
mkLit v pos = Lit (shiftL v 1 + if pos then 0 else 1)
{-# INLINE mkLit #-}

-- | The variable a literal refers to (@shiftR 1@, dropping the sign bit).
litVar :: Lit -> Var
litVar (Lit l) = shiftR l 1
{-# INLINE litVar #-}

-- | The sign bit of a literal: @False@ for a positive literal, @True@ for a negative one.
litSign :: Lit -> Bool
litSign (Lit l) = (l .&. 1) == 1
{-# INLINE litSign #-}

-- | True iff the literal is positive (the polarity, the complement of 'litSign').
litPos :: Lit -> Bool
litPos (Lit l) = (l .&. 1) == 0
{-# INLINE litPos #-}

{- | Negate a literal: flip the sign bit (@xor 1@). Same variable, opposite polarity, so
@negLit (negLit l) == l@.
-}
negLit :: Lit -> Lit
negLit (Lit l) = Lit (l `xor` 1)
{-# INLINE negLit #-}

{- | A clause is a disjunction of literals, in original (parse) order. A list keeps the type pure
and order-preserving; the mutable store ("Lattice.SAT.ClauseDB") holds each clause as an immutable
unboxed vector of the raw 'Int' encodings for cache-friendly access in the hot loop.
-}
type Clause = [Lit]

{- | A CNF formula: the variable count (variables are @0 .. cnfVars - 1@) and the clauses, a
conjunction. The variable count is authoritative — it sizes every per-variable array — so the parser
validates that no literal's magnitude exceeds it.
-}
data CNF = CNF
  { cnfVars :: Int
  , cnfClauses :: [Clause]
  }
  deriving (Eq, Show)

{- | The outcome of a solve: a satisfying assignment as the list of true literals, or a sound report
that the formula is unsatisfiable. Mirrors 'Lattice.Core.Types.Result'.
-}
data SatResult
  = Sat [Lit]
  | Unsat
  deriving (Eq, Show)
