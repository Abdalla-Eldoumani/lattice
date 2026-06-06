{- | The N-queens encoder (ENCODE-03). One variable per row (0..n-1), its value the queen's column
(0..n-1). The three classic constraints are offset-all-different: the columns @q_i@ are distinct, the
up-diagonals @q_i + i@ are distinct, and the down-diagonals @q_i - i@ are distinct. Counting the
solutions of @queensModel n@ with the oracle reproduces the known sequence (2, 10, 4, ..., 92).
-}
module Lattice.Encode.Queens (
  queensModel,
) where

import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Lattice.Core.Types (Constraint (..), Domain (..), Model (..))

-- | The N-queens CSP for an @n x n@ board.
queensModel :: Int -> Model
queensModel n =
  Model
    { modelDomains =
        IntMap.fromList [(i, Domain (IntSet.fromList [0 .. n - 1])) | i <- [0 .. n - 1]]
    , modelConstraints =
        [ AllDiffOffset [(i, 0) | i <- [0 .. n - 1]]
        , AllDiffOffset [(i, i) | i <- [0 .. n - 1]]
        , AllDiffOffset [(i, negate i) | i <- [0 .. n - 1]]
        ]
    }
