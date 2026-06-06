{-# LANGUAGE OverloadedStrings #-}

{- | The nonogram encoder (ENCODE-04). It parses the fixed-layout JSON in
@puzzles/nonogram/*.json@ and builds a CSP with one boolean variable per cell (0 blank, 1 ink)
at the row-major index @r * cols + c@, plus one 'LineClue' constraint per row and per column
carrying that line's variables (in order) and its run-length clue. The cell-boolean encoding
keeps events in the @cell@ = grid-index / @value@ = bit shape the visualizer already speaks,
so no event change is needed and the renderer reads cells directly.

'decodeNonogram' turns a solved assignment back into a 0/1 grid, and 'lineClue' extracts a
line's run lengths — the two halves of the mandatory round-trip (clues -> solve -> grid ->
re-derive clues = the input clues).
-}
module Lattice.Encode.Nonogram (
  Nonogram (..),
  parseNonogram,
  nonogramModel,
  decodeNonogram,
  lineClue,
) where

import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:))
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.List (group)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Lattice.Core.Types (Assignment, Constraint (..), Domain (..), Model (..), Value)

{- | A parsed nonogram instance: the dimensions and the row/column run-length clues. Each clue
is one run-length list per line (top to bottom for rows, left to right for columns); an empty
list is an all-blank line.
-}
data Nonogram = Nonogram
  { nonoRows :: Int
  , nonoCols :: Int
  , nonoRowClues :: [[Int]]
  , nonoColClues :: [[Int]]
  }
  deriving (Eq, Show)

instance FromJSON Nonogram where
  parseJSON = withObject "nonogram instance" $ \o -> do
    rows <- o .: "rows"
    cols <- o .: "cols"
    rowClues <- o .: "rowClues"
    colClues <- o .: "colClues"
    pure
      Nonogram
        { nonoRows = rows
        , nonoCols = cols
        , nonoRowClues = rowClues
        , nonoColClues = colClues
        }

{- | Parse a nonogram instance from its JSON text. Total: malformed JSON or a missing field is a
'Left', never a crash (the server's untrusted-input boundary depends on this, like 'parseGrid').

Structural decode is not enough: an untrusted payload can be well-typed but semantically
malformed (a @rowClues@ list shorter than @rows@, a negative dimension, a non-positive run length).
These would otherwise survive as a lazy 'Right' and crash the forked solve thread when
'nonogramModel' forces the missing clue, or diverge from the oracle on a degenerate @0@-run. So the
parser rejects them here, keeping the encoder's accepted domain inside the domain where the
'placements' enumeration and the oracle's @runs@ agree.
-}
parseNonogram :: Text -> Either String Nonogram
parseNonogram t = eitherDecodeStrict (encodeUtf8 t) >>= validate
 where
  validate n
    | nonoRows n < 0 || nonoCols n < 0 = Left "rows and cols must be non-negative"
    | length (nonoRowClues n) /= nonoRows n = Left "rowClues length must equal rows"
    | length (nonoColClues n) /= nonoCols n = Left "colClues length must equal cols"
    | any (any (<= 0)) (nonoRowClues n ++ nonoColClues n) = Left "run lengths must be positive"
    | otherwise = Right n

{- | Build the CSP: one @{0,1}@ variable per cell at the row-major index @r * cols + c@, and one
'LineClue' per row and per column carrying that line's variables in order and its clue.
-}
nonogramModel :: Nonogram -> Model
nonogramModel n =
  Model
    { modelDomains =
        IntMap.fromList [(idx r c, Domain (IntSet.fromList [0, 1])) | r <- rs, c <- cs]
    , modelConstraints =
        -- Zip the clue lists against their indices rather than indexing with @!!@: a clue list
        -- shorter than its dimension drops out instead of forcing a partial index on the solve
        -- thread. 'parseNonogram' already rejects a length mismatch, so this is defence in depth
        -- that keeps the encoder total even if called on a hand-built 'Nonogram'.
        [LineClue [idx r c | c <- cs] clue | (r, clue) <- zip rs (nonoRowClues n)]
          ++ [LineClue [idx r c | r <- rs] clue | (c, clue) <- zip cs (nonoColClues n)]
    }
 where
  rs = [0 .. nonoRows n - 1]
  cs = [0 .. nonoCols n - 1]
  idx r c = r * nonoCols n + c

{- | Decode a solved assignment into rows of 0/1. A variable missing from the assignment renders
as 0, keeping this total (a complete solution assigns every cell).
-}
decodeNonogram :: Nonogram -> Assignment -> [[Value]]
decodeNonogram n asn =
  [[IntMap.findWithDefault 0 (idx r c) asn | c <- cs] | r <- rs]
 where
  rs = [0 .. nonoRows n - 1]
  cs = [0 .. nonoCols n - 1]
  idx r c = r * nonoCols n + c

{- | The run-length clue of a 0/1 line: the lengths of the maximal runs of 1s, in order
(@[1,1,0,1] -> [2,1]@; an all-blank line -> @[]@). The second half of the round-trip.
-}
lineClue :: [Value] -> [Int]
lineClue line = [length g | g@(b : _) <- group line, b == 1]
