{- | The Sudoku encoder: parse a dot-for-blank, row-per-line grid into a constraint model,
and decode a solved assignment back to a digit string. It handles 9x9 (3x3 boxes) and 4x4
(2x2 boxes) because the puzzle generators emit both; the box side is the integer square
root of the side length. This is the only external-input boundary in Phase 1, so
'parseGrid' is total and surfaces every malformed input as a 'ParseError' rather than a crash.
-}
module Lattice.Encode.Sudoku (
  ParseError (..),
  Grid,
  Model (..),
  parseGrid,
  toModel,
  decode,
) where

import Data.Char (digitToInt, intToDigit, isDigit)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.Text (Text)
import Data.Text qualified as T
import Lattice.Core.Types (Assignment, Constraint (..), Domain (..), Domains, Value)

{- | Why a grid failed to parse. Each constructor carries the location detail needed to point
a user at the offending line or column. A contradictory-but-well-formed grid is deliberately
NOT an error here: it parses, and the solver later reports it unsolvable (parse error means a
non-zero exit; unsolvable is a clean exit).
-}
data ParseError
  = EmptyInput
  | NotSquareSize Int
  | BadLineLength Int Int Int
  | BadChar Int Int Char
  | DigitOutOfRange Int Int Int Int
  deriving (Eq, Show)

-- | A parsed grid: the side length and the row-major cells ('Nothing' is a blank).
data Grid = Grid Int [Maybe Value]
  deriving (Eq, Show)

{- | A model ready for the solver: the side length (kept so 'decode' knows the width), the
seeded domains (blanks -> {1..n}, givens -> {d}), and the row/column/box all-different
constraints.
-}
data Model = Model
  { modelSize :: Int
  , modelDomains :: Domains
  , modelConstraints :: [Constraint]
  }
  deriving (Eq, Show)

{- | Parse a dot-for-blank, row-per-line grid. The side length is inferred from the line count
and must be a perfect square; '.' and '0' are blanks, '1'..'n' are givens. A wrong line
length, an unexpected character, or an out-of-range digit is a 'ParseError'.
-}
parseGrid :: Text -> Either ParseError Grid
parseGrid input =
  case rows of
    [] -> Left EmptyInput
    _
      | b * b /= n -> Left (NotSquareSize n)
      | otherwise -> Grid n . concat <$> traverse parseRow (zip [0 ..] rows)
 where
  rows = dropTrailingBlank (map (T.dropWhileEnd (== '\r')) (T.lines input))
  n = length rows
  b = isqrt n

  parseRow :: (Int, Text) -> Either ParseError [Maybe Value]
  parseRow (r, line)
    | T.length line /= n = Left (BadLineLength r n (T.length line))
    | otherwise = traverse (parseCell r) (zip [0 ..] (T.unpack line))

  parseCell :: Int -> (Int, Char) -> Either ParseError (Maybe Value)
  parseCell r (c, ch)
    | ch == '.' || ch == '0' = Right Nothing
    | isDigit ch =
        let d = digitToInt ch
         in if d <= n then Right (Just d) else Left (DigitOutOfRange r c d n)
    | otherwise = Left (BadChar r c ch)

{- | Build the constraint model from a parsed grid: seed each cell's domain and emit an
all-different over every row, column, and box.
-}
toModel :: Grid -> Model
toModel (Grid n cells) =
  Model
    { modelSize = n
    , modelDomains = IntMap.fromList (zipWith seed [0 ..] cells)
    , modelConstraints = rowCons ++ colCons ++ boxCons
    }
 where
  b = isqrt n
  full = IntSet.fromList [1 .. n]
  seed i cell = (i, Domain (maybe full IntSet.singleton cell))
  rowCons = [AllDifferent [r * n + c | c <- [0 .. n - 1]] | r <- [0 .. n - 1]]
  colCons = [AllDifferent [r * n + c | r <- [0 .. n - 1]] | c <- [0 .. n - 1]]
  boxCons =
    [ AllDifferent [(br * b + i) * n + (bc * b + j) | i <- [0 .. b - 1], j <- [0 .. b - 1]]
    | br <- [0 .. b - 1]
    , bc <- [0 .. b - 1]
    ]

{- | Render a full assignment as the n*n row-major digit string. A variable missing from the
assignment (not expected for a complete solution) renders as '.', keeping this total.
-}
decode :: Model -> Assignment -> Text
decode model asn =
  T.pack [maybe '.' intToDigit (IntMap.lookup i asn) | i <- [0 .. n * n - 1]]
 where
  n = modelSize model

-- | Integer square root, exact for perfect squares (recovers the box side from the width).
isqrt :: Int -> Int
isqrt n = go (max 0 (floor (sqrt (fromIntegral n :: Double))))
 where
  go b
    | b * b > n = go (b - 1)
    | (b + 1) * (b + 1) <= n = go (b + 1)
    | otherwise = b

-- | Drop a single trailing blank line (left by a trailing newline) so the line count is n.
dropTrailingBlank :: [Text] -> [Text]
dropTrailingBlank xs = case reverse xs of
  (lastLine : rest) | T.null lastLine -> reverse rest
  _ -> xs
