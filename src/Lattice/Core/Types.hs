{-# LANGUAGE StrictData #-}

{- | Core data types for the engine: variables, values, finite-integer domains, and the
persistent domain map. The map backtracks for free — a decision pushes a new map and the
old one is the undo log — which is why the state is an 'IntMap', not a mutable array, in M1.
Pure data only; the six operations over 'Domains' live in "Lattice.Core.Domain".
-}
module Lattice.Core.Types (
  Var,
  Value,
  Level,
  Domain (..),
  Domains,
  Assignment,
  Constraint (..),
  Result (..),
) where

import Data.IntMap.Strict (IntMap)
import Data.IntSet (IntSet)

-- | A variable index. Sudoku cells are 0..80 (9x9) or 0..15 (4x4), row-major.
type Var = Int

-- | A domain value. Sudoku digits are 1..9 (9x9) or 1..4 (4x4).
type Value = Int

-- | Decision depth. Groundwork for later phases; the pure M1 search does not read it.
type Level = Int

{- | The values a variable may still take. Empty is the conflict signal; a singleton is an
assignment. A newtype so it cannot be confused with a bare 'IntSet' elsewhere.
-}
newtype Domain = Domain IntSet
  deriving (Eq, Show)

{- | The persistent variable-to-domain map: the whole mutable-feeling state of a solve, kept
immutable so backtracking is just holding on to the previous map.
-}
type Domains = IntMap Domain

-- | A committed variable-to-value map — every variable pinned to one value.
type Assignment = IntMap Value

{- | The constraints the encoders build. 'NotEqual' is its own constructor (not @AllDifferent
[a, b]@) so Phase 2 graph-coloring reuses the binary case directly.
-}
data Constraint
  = AllDifferent [Var]
  | NotEqual Var Var
  deriving (Eq, Show)

-- | The outcome of a solve: a satisfying assignment, or a sound report that none exists.
data Result
  = Solved Assignment
  | NoSolution
  deriving (Eq, Show)
