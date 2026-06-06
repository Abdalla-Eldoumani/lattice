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
  Model (..),
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
[a, b]@) so graph-coloring reuses the binary case directly. Phase 2 adds three more:
'AllDiffOffset' makes the values @v + offset@ pairwise distinct (the three-line N-queens encoding —
columns and both diagonals), and 'SumEq' / 'LessEq' are the sum and comparison constraints.
Phase 4 adds 'LineClue' for nonograms: a line of @{0,1}@ cells (in order) whose maximal runs of 1s
must match the run-length clue — contiguity no existing constraint expresses ('SumEq' fixes a
line's total ink but not its run pattern).
-}
data Constraint
  = AllDifferent [Var]
  | NotEqual Var Var
  | AllDiffOffset [(Var, Int)]
  | SumEq [Var] Int
  | LessEq Var Var
  | LineClue [Var] [Int]
  deriving (Eq, Show)

-- | The outcome of a solve: a satisfying assignment, or a sound report that none exists.
data Result
  = Solved Assignment
  | NoSolution
  deriving (Eq, Show)

{- | A constraint-satisfaction problem the solver and the oracle consume: the seeded domains and the
constraints over them. Encoders build it; it is deliberately puzzle-agnostic (Sudoku, graph-coloring,
and N-queens all produce this same shape), so 'solve' and "Lattice.Brute" work for every encoder.
-}
data Model = Model
  { modelDomains :: Domains
  , modelConstraints :: [Constraint]
  }
  deriving (Eq, Show)
