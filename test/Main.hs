{-# LANGUAGE OverloadedStrings #-}

{- | Test entry point. This suite is the correctness contract for the whole project: a
propagation or backtracking bug is invisible on easy puzzles and wrong on hard ones, and the only
defense is testing against an independent oracle. The four property groups — soundness,
completeness, sound propagation, and differential — compare the CP engine against the deliberately
dumb 'Lattice.Brute' oracle on generated 4x4 instances, where the oracle is fast. The golden tests
pin the recorded solutions for the larger known puzzles.
-}
module Main (main) where

import Data.ByteString.Lazy qualified as BL
import Data.Char (intToDigit, isDigit)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.List (intercalate)
import Data.Maybe (isNothing, mapMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Lattice (Result (..), decode, parseGrid, solve, toModel, version)
import Lattice.Brute qualified as Brute
import Lattice.CP.Queue (propagate)
import Lattice.Core.Domain (domainOf)
import Lattice.Core.Types (Assignment, Constraint (..), Domain (..))
import Lattice.Encode.Sudoku (Model (..))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (
  Arbitrary (..),
  Gen,
  Property,
  counterexample,
  elements,
  forAll,
  frequency,
  property,
  shuffle,
  sublistOf,
  testProperty,
  vectorOf,
  (.&&.),
  (===),
 )

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "lattice"
    [ smoke
    , encoderOracle
    , correctness
    , golden
    ]

smoke :: TestTree
smoke = testCase "library version is set" (version @?= "0.1.0.0")

-- Recorded, verified-unique solutions (puzzles/sudoku/SOLUTIONS.md).

easySolution :: T.Text
easySolution =
  "534678912672195348198342567859761423426853791713924856961537284287419635345286179"

diff4x4Solution :: T.Text
diff4x4Solution = "1234341243212143"

{- | The encoder and the oracle agree on the recorded solutions before the engine is trusted, and
the oracle's unsat path runs on a contradictory-but-well-formed grid.
-}
encoderOracle :: TestTree
encoderOracle =
  testGroup
    "encoder + oracle round-trip"
    [ testCase "easy.txt brute-solves to the recorded 9x9 solution" $
        roundTrip "puzzles/sudoku/easy.txt" easySolution
    , testCase "diff-4x4.txt brute-solves to the recorded 4x4 solution" $
        roundTrip "puzzles/sudoku/diff-4x4.txt" diff4x4Solution
    , testCase "contradictory givens parse cleanly but are unsolvable" $
        case parseGrid "11..\n....\n....\n....\n" of
          Left err -> assertFailure ("expected a valid parse, got " <> show err)
          Right g -> Brute.solveFirst (toModel g) @?= Nothing
    ]

roundTrip :: FilePath -> T.Text -> IO ()
roundTrip path expected = do
  raw <- TIO.readFile path
  case parseGrid raw of
    Left err -> assertFailure ("parse failed: " <> show err)
    Right g ->
      let model = toModel g
       in case Brute.solveFirst model of
            Nothing -> assertFailure "oracle found no solution"
            Just a -> decode model a @?= expected

{- | The four correctness groups, the reason the project exists. Each compares the CP engine to the
independent oracle on generated 4x4 instances; the unsat path also runs on a deterministic fixture.
-}
correctness :: TestTree
correctness =
  testGroup
    "correctness"
    [ testProperty "soundness: a returned assignment satisfies every constraint" prop_soundness
    , testProperty "completeness: CP and the oracle agree on unsatisfiability" prop_completeness
    , testCase "a contradictory 4x4 is unsolvable for both engine and oracle" unsatFixture
    , testProperty "sound propagation: no solution value is ever pruned" prop_soundProp
    , testProperty "differential: CP and the oracle agree (and on the unique solution)" prop_differential
    ]

{- | Golden tests: the CP engine solves the recorded puzzles to their pinned solution strings, so a
regression diffs loudly against the committed files. Timing for hard-17 is machine-dependent and is
deliberately not asserted.
-}
golden :: TestTree
golden =
  testGroup
    "golden"
    [ goldenVsString
        "easy.txt solves to the recorded solution"
        "test/golden/easy.sol"
        (cpSolutionBytes "puzzles/sudoku/easy.txt")
    , goldenVsString
        "hard-17.txt solves to the recorded solution"
        "test/golden/hard-17.sol"
        (cpSolutionBytes "puzzles/sudoku/hard-17.txt")
    ]

{- | Solve a puzzle file with the CP engine and return the decoded solution as bytes for the golden
comparison.
-}
cpSolutionBytes :: FilePath -> IO BL.ByteString
cpSolutionBytes path = do
  raw <- TIO.readFile path
  pure $ case parseGrid raw of
    Left e -> encode (T.pack ("parse error: " <> show e))
    Right g ->
      let model = toModel g
       in case solve model of
            Solved a -> encode (decode model a)
            NoSolution -> encode "no solution"
 where
  encode = BL.fromStrict . TE.encodeUtf8

{- | Soundness (CORRECT-01): if the engine returns 'Solved', that assignment satisfies every row,
column, and box constraint, checked directly. A 'Solved' that violates a constraint is a hard fail.
-}
prop_soundness :: Puzzle -> Bool
prop_soundness p = case solve model of
  Solved a -> satisfies model a
  NoSolution -> True
 where
  model = puzzleModel p

{- | Completeness (CORRECT-02): the engine and the oracle agree on satisfiability for every instance
— CP reports unsolvable exactly when the oracle finds no solution. This catches both a false unsat
and a false sat.
-}
prop_completeness :: Puzzle -> Property
prop_completeness p = (solve model == NoSolution) === isNothing (Brute.solveFirst model)
 where
  model = puzzleModel p

{- | A deterministic genuinely-unsatisfiable fixture (two identical givens in one row) so the
NoSolution path runs every build, not only when the generator happens to produce an unsat grid.
-}
unsatFixture :: IO ()
unsatFixture = case parseGrid "11..\n....\n....\n....\n" of
  Left err -> assertFailure ("expected a valid parse, got " <> show err)
  Right g -> do
    let model = toModel g
    solve model @?= NoSolution
    Brute.solveFirst model @?= Nothing

{- | Sound propagation (CORRECT-03), the highest-value test: one fixpoint propagation from the
givens (no search) must never remove a value that appears in some real solution. A propagator that
prunes a real answer is the silent-killer bug; this is its guard.
-}
prop_soundProp :: Property
prop_soundProp = forAll genSatGrid $ \gridStr ->
  let model = gridModel gridStr
      sols = Brute.solveAll model
      unionVals = IntMap.unionsWith IntSet.union [IntMap.map IntSet.singleton a | a <- sols]
   in case propagate (modelConstraints model) (modelDomains model) of
        Left _ -> counterexample "propagation reported a conflict despite a real solution" False
        Right ds ->
          property $
            and [valueIn x v ds | (v, vals) <- IntMap.toList unionVals, x <- IntSet.toList vals]
 where
  valueIn x v ds = case domainOf v ds of Domain dom -> x `IntSet.member` dom

{- | Differential (CORRECT-04): CP and the oracle agree on satisfiability, and where the oracle's
solution is unique, CP returns that same assignment.
-}
prop_differential :: Puzzle -> Property
prop_differential p = (cpSat === bruteSat) .&&. uniqueAgrees
 where
  model = puzzleModel p
  sols = Brute.solveAll model
  cpSat = solve model /= NoSolution
  bruteSat = not (null sols)
  uniqueAgrees = case sols of
    [unique] -> case solve model of
      Solved a -> a === unique
      NoSolution -> counterexample "CP found no solution but the oracle's is unique" False
    _ -> property True

{- | Does an assignment satisfy every constraint of the model? Every constrained variable must be
assigned, and each all-different must hold (no duplicates) and each not-equal must differ.
-}
satisfies :: Model -> Assignment -> Bool
satisfies model asn = all holds (modelConstraints model)
 where
  holds (AllDifferent vs) =
    let xs = mapMaybe (`IntMap.lookup` asn) vs
     in length xs == length vs && IntSet.size (IntSet.fromList xs) == length xs
  holds (NotEqual a b) = case (IntMap.lookup a asn, IntMap.lookup b asn) of
    (Just x, Just y) -> x /= y
    _ -> False

-- | A generated 4x4 puzzle, carried as its grid text so a failing case prints a readable grid.
newtype Puzzle = Puzzle String
  deriving (Eq)

instance Show Puzzle where
  show (Puzzle s) = '\n' : s

instance Arbitrary Puzzle where
  arbitrary = Puzzle <$> genGrid4
  shrink (Puzzle s) = [Puzzle (blankAt i s) | i <- [0 .. length s - 1], isDigit (s !! i)]

{- | Generate a 4x4 grid (digits 1..4, '.' for blank) with roughly half the cells given, which
yields a healthy mix of satisfiable, unsatisfiable, and uniquely-solvable instances.
-}
genGrid4 :: Gen String
genGrid4 = do
  cells <- vectorOf 16 cell
  pure (intercalate "\n" [take 4 (drop (4 * i) cells) | i <- [0 .. 3]])
 where
  cell = frequency [(1, pure '.'), (1, elements "1234")]

-- | Blank the cell at index @i@ (used by shrinking to find the minimal failing grid).
blankAt :: Int -> String -> String
blankAt i s = take i s ++ "." ++ drop (i + 1) s

{- | Generate an always-satisfiable 4x4: relabel a fixed valid solution with a random digit
permutation, then blank a random subset of cells. The full relabeled grid is always a solution, so
'Brute.solveAll' is non-empty and the sound-propagation property never has to discard a case.
-}
genSatGrid :: Gen String
genSatGrid = do
  perm <- shuffle [1, 2, 3, 4]
  blanks <- sublistOf [0 .. 15]
  let cellAt i
        | i `elem` blanks = '.'
        | otherwise = intToDigit (perm !! (base !! i - 1))
      cells = map cellAt [0 .. 15]
  pure (intercalate "\n" [take 4 (drop (4 * i) cells) | i <- [0 .. 3]])
 where
  base = [1, 2, 3, 4, 3, 4, 1, 2, 2, 1, 4, 3, 4, 3, 2, 1]

{- | Parse and model a generated grid. The generators only emit valid characters, so a parse
failure here is an invariant violation, not user input.
-}
gridModel :: String -> Model
gridModel s = case parseGrid (T.pack s) of
  Right g -> toModel g
  Left e -> error ("generated grid did not parse: " <> show e)

puzzleModel :: Puzzle -> Model
puzzleModel (Puzzle s) = gridModel s
