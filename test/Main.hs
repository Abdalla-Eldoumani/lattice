{-# LANGUAGE OverloadedStrings #-}
-- The test module defines an 'Arbitrary' instance for the library's 'Event' (an orphan): the
-- library must not depend on QuickCheck, so the generator lives here, with orphans waived for tests.
{-# OPTIONS_GHC -Wno-orphans #-}

{- | Test entry point. This suite is the correctness contract for the whole project: a
propagation or backtracking bug is invisible on easy puzzles and wrong on hard ones, and the only
defense is testing against an independent oracle. The four property groups — soundness,
completeness, sound propagation, and differential — compare the CP engine against the deliberately
dumb 'Lattice.Brute' oracle on generated 4x4 instances, where the oracle is fast. The golden tests
pin the recorded solutions for the larger known puzzles.
-}
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Char (intToDigit, isDigit)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.List (intercalate, transpose)
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Lattice (Result (..), decode, parseGrid, solve, toModel, version)
import Lattice.Brute qualified as Brute
import Lattice.CP.Queue (propagate)
import Lattice.CP.Search (Strategy (..), searchStats)
import Lattice.CP.Solver (solveTrace)
import Lattice.Core.Domain (domainOf)
import Lattice.Core.Types (Assignment, Constraint (..), Domain (..), Model (..))
import Lattice.Encode.Graph (Graph (..), graphModel, parseGraph)
import Lattice.Encode.Nonogram (
  Nonogram (..),
  decodeNonogram,
  lineClue,
  nonogramModel,
  parseNonogram,
 )
import Lattice.Encode.Queens (queensModel)
import Lattice.Event (Event (..))
import Lattice.Protocol (Control (..))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (
  Arbitrary (..),
  Gen,
  Property,
  choose,
  counterexample,
  elements,
  forAll,
  frequency,
  oneof,
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
    , graph
    , queens
    , nonogram
    , ordering
    , sumComparison
    , eventProtocol
    , traceMode
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
            Just a -> decode g a @?= expected

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
    , goldenVsString
        "heart.json solves to the recorded picture"
        "test/golden/heart.sol"
        nonogramPictureBytes
    ]

{- | Solve the heart nonogram with the CP engine and render the decoded picture (one row per line,
@#@ for ink, @.@ for blank) for the golden pin.
-}
nonogramPictureBytes :: IO BL.ByteString
nonogramPictureBytes = do
  raw <- TIO.readFile "puzzles/nonogram/heart.json"
  pure $ case parseNonogram raw of
    Left e -> encode (T.pack ("parse error: " <> e))
    Right n -> case solve (nonogramModel n) of
      Solved a -> encode (renderPicture (decodeNonogram n a))
      NoSolution -> encode "no solution"
 where
  encode = BL.fromStrict . TE.encodeUtf8
  renderPicture grid =
    T.intercalate "\n" [T.pack [if cell == 1 then '#' else '.' | cell <- row] | row <- grid]

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
            Solved a -> encode (decode g a)
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
prop_soundProp = forAll genSatGrid (soundPropHolds . gridModel)

{- | Sound propagation on a satisfiable model: one fixpoint from the givens keeps every value that
appears in some solution. Shared by the Sudoku and the sum/comparison groups.
-}
soundPropHolds :: Model -> Property
soundPropHolds m =
  let sols = Brute.solveAll m
      unionVals = IntMap.unionsWith IntSet.union [IntMap.map IntSet.singleton a | a <- sols]
   in case propagate (modelConstraints m) (modelDomains m) of
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
  holds (AllDiffOffset pairs) =
    let xs = mapMaybe (\(v, off) -> (+ off) <$> IntMap.lookup v asn) pairs
     in length xs == length pairs && IntSet.size (IntSet.fromList xs) == length xs
  holds (LessEq a b) = case (IntMap.lookup a asn, IntMap.lookup b asn) of
    (Just x, Just y) -> x <= y
    _ -> False
  holds (SumEq vs c) =
    let xs = mapMaybe (`IntMap.lookup` asn) vs
     in length xs == length vs && sum xs == c
  holds (LineClue vs clue) =
    let xs = mapMaybe (`IntMap.lookup` asn) vs
     in length xs == length vs && lineClue xs == clue

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

{- | Graph coloring (ENCODE-02): the Petersen graph 3-colors, and CP agrees with the oracle on
k-colorability for small random graphs.
-}
graph :: TestTree
graph =
  testGroup
    "graph coloring"
    [ testCase "the Petersen graph 3-colors" petersenColors
    , testProperty "CP and the oracle agree on k-colorability" prop_graphColoring
    , testCase "parseGraph rejects an edge naming a non-existent vertex" $
        -- An out-of-range edge (vertex 99 in a 2-vertex graph) would seed an empty domain and
        -- report a wrong NoSolution; reject it at the parse boundary instead (CR-02).
        assertLeft
          ( parseGraph
              "{\"k\":3,\"vertices\":[{\"x\":0,\"y\":0},{\"x\":1,\"y\":1}],\"edges\":[[0,99]]}"
          )
    , testCase "parseGraph rejects k < 1" $
        assertLeft
          (parseGraph "{\"k\":0,\"vertices\":[{\"x\":0,\"y\":0}],\"edges\":[]}")
    ]

petersenColors :: IO ()
petersenColors = do
  raw <- TIO.readFile "puzzles/graph/petersen.json"
  case parseGraph raw of
    Left e -> assertFailure ("graph parse failed: " <> e)
    Right g -> case solve (graphModel g) of
      NoSolution -> assertFailure "the Petersen graph is 3-colorable but CP found no coloring"
      Solved a -> assertBool "the coloring violates an edge" (satisfies (graphModel g) a)

prop_graphColoring :: Property
prop_graphColoring = forAll genSmallGraph $ \g ->
  let m = graphModel g
   in (solve m /= NoSolution) === isJust (Brute.solveFirst m)

-- | Small random graphs (2-5 vertices, 1-3 colors) for the differential k-colorability check.
genSmallGraph :: Gen Graph
genSmallGraph = do
  n <- choose (2, 5)
  k <- choose (1, 3)
  edges <- sublistOf [(i, j) | i <- [0 .. n - 1], j <- [i + 1 .. n - 1]]
  pure Graph {graphK = k, graphVertexCount = n, graphEdges = edges}

{- | N-queens (ENCODE-03): the encoder's solution counts match the known sequence. Counting uses the
oracle on the queens model, validating the encoding independently of the CP engine.
-}
queens :: TestTree
queens =
  testCase "N-queens solution counts match the known sequence" $ do
    queenCount 4 @?= 2
    queenCount 5 @?= 10
    queenCount 6 @?= 4
    queenCount 8 @?= 92
 where
  queenCount n = length (Brute.solveAll (queensModel n))

{- | Nonogram (ENCODE-04): the mandatory round-trip (clues -> CP solve -> grid -> re-derive clues =
the input), a unit check of the run-length extraction, a tractable uniqueness gate on a tiny
instance the dumb oracle can enumerate, and the sound-propagation property on random small
satisfiable nonograms (the silent-killer guard for the new 'LineClue' propagator). The heart
fixture's own uniqueness is verified out of band (it has 100 free cells, so 'Brute.solveAll' over
the full boolean grid is intractable by design); see the SUMMARY for the independent count.
-}
nonogram :: TestTree
nonogram =
  testGroup
    "nonogram"
    [ testCase "lineClue extracts the run lengths of a 0/1 line" $ do
        lineClue [1, 1, 0, 1] @?= [2, 1]
        lineClue [0, 0, 0] @?= []
        lineClue [1, 1, 1] @?= [3]
        lineClue [] @?= []
    , testCase
        "the heart fixture round-trips (clues -> solve -> grid -> re-derive clues)"
        nonogramRoundTrip
    , testCase "a tiny nonogram has a unique solution the oracle confirms" $ do
        let m = nonogramModel tinyNono
        length (Brute.solveAll m) @?= 1
    , testProperty "sound propagation: the LineClue propagator never prunes a real value" $
        forAll genSatNonogram (soundPropHolds . nonogramModel)
    , testCase "parseNonogram rejects a clue list shorter than its dimension" $
        -- A well-typed but malformed payload (rows says 10, rowClues is empty) must be a Left,
        -- not a Right that crashes the solve thread on a partial index (CR-01).
        assertLeft (parseNonogram "{\"rows\":10,\"cols\":10,\"rowClues\":[],\"colClues\":[]}")
    , testCase "parseNonogram rejects a non-positive run length" $
        -- A degenerate 0-run clue diverges from the oracle (WR-01); reject it at the boundary.
        assertLeft
          ( parseNonogram
              "{\"rows\":1,\"cols\":3,\"rowClues\":[[0]],\"colClues\":[[],[],[]]}"
          )
    ]

-- | Assert a parser returned a 'Left' (malformed input was rejected, not silently accepted).
assertLeft :: (Show a) => Either String a -> IO ()
assertLeft (Left _) = pure ()
assertLeft (Right a) = assertFailure ("expected Left for malformed input, got Right " <> show a)

{- | The mandatory ENCODE-04 round-trip: the CP engine solves the heart fixture, and the solved grid
re-derives exactly the input row and column clues. Two independent checks in one — a wrong solve or a
wrong encoding both fail it.
-}
nonogramRoundTrip :: IO ()
nonogramRoundTrip = do
  raw <- TIO.readFile "puzzles/nonogram/heart.json"
  case parseNonogram raw of
    Left e -> assertFailure ("nonogram parse failed: " <> e)
    Right n -> case solve (nonogramModel n) of
      NoSolution -> assertFailure "the heart fixture is solvable but CP found no solution"
      Solved a -> do
        let grid = decodeNonogram n a
        map lineClue grid @?= nonoRowClues n
        map lineClue (transpose grid) @?= nonoColClues n

{- | A tiny 3x3 nonogram with a single solution (an X / diagonal-corners shape), small enough that
the dumb 'Brute.solveAll' over its 9 cells enumerates quickly. Solution:
@1 0 1 / 0 1 0 / 1 0 1@.
-}
tinyNono :: Nonogram
tinyNono =
  Nonogram
    { nonoRows = 3
    , nonoCols = 3
    , nonoRowClues = [[1, 1], [1], [1, 1]]
    , nonoColClues = [[1, 1], [1], [1, 1]]
    }

{- | Generate an always-satisfiable small nonogram: draw a random small 0/1 grid, derive its row and
column clues, and build the instance from those clues. The drawn grid is always a solution, so
'Brute.solveAll' is non-empty and the sound-propagation property never discards a case. Kept tiny
(2..4 per side) so the dumb oracle enumerates fast.
-}
genSatNonogram :: Gen Nonogram
genSatNonogram = do
  rows <- choose (2, 4)
  cols <- choose (2, 4)
  grid <- vectorOf rows (vectorOf cols (elements [0, 1]))
  pure
    Nonogram
      { nonoRows = rows
      , nonoCols = cols
      , nonoRowClues = map lineClue grid
      , nonoColClues = map lineClue (transpose grid)
      }

{- | Ordering (ORDER-01/02/03): MRV with the degree tie-break and LCV measurably reduces the
decisions the search makes on hard-17 versus naive in-order selection. Recorded counts (deterministic
on this instance): naive makes 36400 decisions, MRV makes 1473 — about a 25x reduction. The assertion
prints both counts on failure.
-}
ordering :: TestTree
ordering =
  testCase "MRV reduces decisions on hard-17 versus naive in-order selection" $ do
    raw <- TIO.readFile "puzzles/sudoku/hard-17.txt"
    case parseGrid raw of
      Left e -> assertFailure ("parse failed: " <> show e)
      Right g -> do
        let m = toModel g
            naiveD = snd (searchStats Naive (modelConstraints m) (modelDomains m))
            mrvD = snd (searchStats Mrv (modelConstraints m) (modelDomains m))
        assertBool
          ("expected MRV < naive, got MRV=" <> show mrvD <> " naive=" <> show naiveD)
          (mrvD < naiveD)

{- | Sum and comparison propagators (CORE-06): on satisfiable-by-construction models that use 'SumEq'
and 'LessEq', the engine returns a valid solution (soundness) and one fixpoint never prunes a real
solution value (sound propagation).
-}
sumComparison :: TestTree
sumComparison =
  testGroup
    "sum and comparison propagators"
    [ testProperty "a returned solution is valid and SAT instances are not called unsolvable" prop_sumComp
    , testProperty "sound propagation holds for sum and comparison" prop_sumCompSoundProp
    ]

prop_sumComp :: Property
prop_sumComp = forAll genSumCompModel $ \m ->
  case solve m of
    Solved a -> counterexample "returned solution is invalid" (satisfies m a)
    NoSolution -> counterexample "a satisfiable-by-construction model was called unsolvable" False

prop_sumCompSoundProp :: Property
prop_sumCompSoundProp = forAll genSumCompModel soundPropHolds

{- | A satisfiable-by-construction CSP over 2-4 variables using a sum constraint and some comparison
constraints: a witness assignment is drawn first, the sum target is its sum, and only comparisons the
witness satisfies are added — so the witness is always a solution.
-}
genSumCompModel :: Gen Model
genSumCompModel = do
  n <- choose (2, 4)
  hi <- choose (1, 4)
  witness <- vectorOf n (choose (0, hi))
  let vars = [0 .. n - 1]
      vw = zip vars witness
      domains = IntMap.fromList [(v, Domain (IntSet.fromList [0 .. hi])) | v <- vars]
  comps <- sublistOf [(a, b) | (a, va) <- vw, (b, vb) <- vw, a /= b, va <= vb]
  pure
    Model
      { modelDomains = domains
      , modelConstraints = SumEq vars (sum witness) : [LessEq a b | (a, b) <- comps]
      }

{- | The event protocol (EVENT-02): the versioned, tagged JSON round-trips — encoding an event and
decoding it back is the identity.
-}
eventProtocol :: TestTree
eventProtocol =
  testGroup
    "protocol"
    [ testProperty "event JSON round-trips (encode then decode is identity)" prop_eventRoundTrip
    , testProperty "control JSON round-trips (encode then decode is identity)" prop_controlRoundTrip
    ]

prop_eventRoundTrip :: Event -> Property
prop_eventRoundTrip e = Aeson.decode (Aeson.encode e) === Just e

prop_controlRoundTrip :: Control -> Property
prop_controlRoundTrip c = Aeson.decode (Aeson.encode c) === Just c

instance Arbitrary Control where
  arbitrary =
    oneof
      [ Start . T.pack
          <$> elements ["sudoku", "graph", "queens", "nonogram"]
          <*> (T.pack <$> arbitrary)
          <*> (T.pack <$> arbitrary)
      , pure Step
      , Play <$> choose (0.1, 16.0)
      , pure Pause
      , pure Restart
      ]

{- | Trace mode (EVENT-01): solving a small instance emits a coherent event stream — propagation
events as candidates are pruned, and a final 'Solution' event whose assignment matches the result.
-}
traceMode :: TestTree
traceMode = testCase "trace mode emits a coherent event stream ending in a solution" $ do
  raw <- TIO.readFile "puzzles/sudoku/diff-4x4.txt"
  case parseGrid raw of
    Left e -> assertFailure ("parse failed: " <> show e)
    Right g -> do
      ref <- newIORef []
      result <- solveTrace (\e -> modifyIORef' ref (e :)) (toModel g)
      events <- reverse <$> readIORef ref
      case result of
        NoSolution -> assertFailure "expected a solution"
        Solved a -> do
          assertBool "expected propagate events" (any isPropagate events)
          case reverse events of
            (Solution pairs : _) -> IntMap.fromList pairs @?= a
            _ -> assertFailure "the last event should be a Solution matching the result"
 where
  isPropagate Propagate {} = True
  isPropagate _ = False

instance Arbitrary Event where
  arbitrary =
    oneof
      [ Decision <$> arbitrary <*> arbitrary <*> arbitrary
      , Propagate <$> arbitrary <*> arbitrary
      , Conflict <$> arbitrary
      , Backtrack <$> arbitrary
      , Solution <$> arbitrary
      , pure Unsat
      , Stats <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
      ]
