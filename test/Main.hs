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

import Control.Monad.ST (runST)
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
import Lattice.Event (Event (..), noEmit)
import Lattice.Protocol (Control (..))
import Lattice.SAT.Analyze (analyze1UIP)
import Lattice.SAT.Dimacs (parseDimacs, printDimacs)
import Lattice.SAT.Encode (cnfColoring, graphCNF)
import Lattice.SAT.Solver (solveSat, solveSatLearned, solveSatLearnedAtLevels)
import Lattice.SAT.Trail qualified as Trail
import Lattice.SAT.Types (CNF (..), Lit (..), SatResult (Sat), litPos, litVar, mkLit, negLit)
import Lattice.SAT.Types qualified as SatT
import Lattice.SAT.VSIDS (
  branchPhase,
  bumpActivity,
  luby,
  newVSIDS,
  pickBranch,
  readActivity,
  rescaleActivities,
  savePhase,
 )
import Lattice.SAT.Watched qualified as SatW
import Test.Tasty (TestTree, adjustOption, defaultMain, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (
  Arbitrary (..),
  Gen,
  Property,
  QuickCheckTests (..),
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
    , sat
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
    , testCase "parseGraph rejects a huge k (DoS ceiling)" $
        -- A ~40-byte definition with k = 50_000_000 would otherwise build a 50M-element domain per
        -- vertex (and C(k,2) at-most-one clauses in the SAT dual encoder), exhausting memory on the
        -- forked solve thread. The ceiling refuses it at the parse boundary.
        assertLeft (parseGraph "{\"k\":50000000,\"vertices\":[{\"x\":0,\"y\":0}],\"edges\":[]}")
    , testCase "parseGraph rejects a vertex count above the ceiling (DoS)" $
        assertLeft (parseGraph (manyVertexGraph 65))
    , testCase "parseGraph accepts the Petersen fixture (within the ceilings)" $ do
        raw <- TIO.readFile "puzzles/graph/petersen.json"
        case parseGraph raw of
          Left e -> assertFailure ("Petersen should parse within the DoS ceilings: " <> e)
          Right _ -> pure ()
    ]

{- | A graph-coloring JSON with @n@ vertices (and k = 3, no edges), to exercise the vertex-count
ceiling. Each vertex is the minimal @{x,y}@ object the parser reads past.
-}
manyVertexGraph :: Int -> T.Text
manyVertexGraph n =
  T.pack
    ( "{\"k\":3,\"vertices\":["
        <> intercalate "," (replicate n "{\"x\":0,\"y\":0}")
        <> "],\"edges\":[]}"
    )

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
          <$> elements ["sudoku", "graph", "queens", "nonogram", "dimacs"]
          <*> (T.pack <$> arbitrary)
          <*> (T.pack <$> arbitrary)
          <*> (T.pack <$> elements ["cp", "sat", "race"])
      , pure Step
      , Play <$> choose (0.1, 16.0)
      , pure Pause
      , -- 'Restart' is exported by both 'Lattice.Event' (the new SAT event) and 'Lattice.Protocol'
        -- (this control); qualify so the occurrence is unambiguous.
        pure Lattice.Protocol.Restart
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
      , Learned <$> arbitrary
      , pure Lattice.Event.Restart
      , Solution <$> arbitrary
      , pure Unsat
      , Stats <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
      ]

{- | The SAT group: the DIMACS boundary (total parse, canonical print, parse-print identity, and the
malformed-input rejections) and the exhaustive CNF oracle in 'Lattice.Brute'. These are this phase's
data-spine correctness checks; the engine's own differential lands in a later slice.
-}
sat :: TestTree
sat =
  -- Raise the QuickCheck budget for the SAT group. The brute-vs-SAT differentials are this engine's
  -- only defense against silent-wrong-on-some-instances bugs, and the failures are rare per draw: the
  -- backjump-to-0 trail-unwind bug (fixed) slipped past the default 100-test budget and only showed up
  -- in the tens of thousands. 20000 makes that class reliably reproducible while keeping these tiny-CNF
  -- properties to roughly a second each. A higher --quickcheck-tests on the CLI still wins (max).
  adjustOption (\(QuickCheckTests n) -> QuickCheckTests (max n 20000)) $
    testGroup
      "sat"
      [ testGroup "dimacs" dimacsTests
      , testGroup "oracle" oracleTests
      , testGroup "three-way" threeWayTests
      , testGroup "watched" watchedTests
      , testGroup "skeleton" skeletonTests
      , testGroup "analyze" analyzeTests
      , testGroup "vsids" vsidsTests
      , testGroup "heuristics" heuristicsTests
      ]

-- | Both DIMACS fixtures, parsed once for the identity and the header checks.
satDemoRaw, unsatDemoRaw :: IO T.Text
satDemoRaw = TIO.readFile "puzzles/cnf/sat-demo.cnf"
unsatDemoRaw = TIO.readFile "puzzles/cnf/unsat-demo.cnf"

{- | DIMACS parser/printer tests: the fixtures parse with the header's declared variable count,
parse-then-print-then-reparse is identity (the robust formulation that does not depend on the input's
exact whitespace/comments), and every malformed case is a 'Left' (the total-parser contract).
-}
dimacsTests :: [TestTree]
dimacsTests =
  [ testCase "sat-demo.cnf parses with cnfVars matching the header (3)" $ do
      raw <- satDemoRaw
      case parseDimacs raw of
        Left e -> assertFailure ("expected a parse, got " <> e)
        Right cnf -> cnfVars cnf @?= 3
  , testCase "unsat-demo.cnf parses with cnfVars matching the header (1)" $ do
      raw <- unsatDemoRaw
      case parseDimacs raw of
        Left e -> assertFailure ("expected a parse, got " <> e)
        Right cnf -> cnfVars cnf @?= 1
  , testCase "parse-print-reparse is identity on sat-demo.cnf" $ do
      raw <- satDemoRaw
      assertIdentity raw
  , testCase "parse-print-reparse is identity on unsat-demo.cnf" $ do
      raw <- unsatDemoRaw
      assertIdentity raw
  , testCase "rejects a missing header" $
      assertLeft (parseDimacs "1 -2 0\n2 3 0\n")
  , testCase "rejects a malformed header (non-numeric counts)" $
      assertLeft (parseDimacs "p cnf x y\n1 0\n")
  , testCase "rejects a literal magnitude above the declared var count" $
      assertLeft (parseDimacs "p cnf 2 1\n1 3 0\n")
  , testCase "rejects a clause not terminated by 0" $
      assertLeft (parseDimacs "p cnf 2 1\n1 2\n")
  , testCase "rejects a stray token before the header" $
      assertLeft (parseDimacs "garbage\np cnf 1 1\n1 0\n")
  , testCase "rejects a var count above the sane ceiling" $
      assertLeft (parseDimacs "p cnf 100000000 1\n1 0\n")
  , -- readMaybe @Int wraps on overflow (maxBound+1 -> minBound), so an abs-based bound was
    -- bypassable: the signed range check now rejects an overflowing literal instead of indexing
    -- a maxBound variable into the unboxed arrays and crashing the solver thread.
    testCase "rejects a literal that overflows Int (wraps to minBound)" $
      assertLeft (parseDimacs "p cnf 3 1\n9223372036854775808 0\n")
  , testCase "rejects a literal that wraps around 2^64 to a small in-range value" $
      assertLeft (parseDimacs "p cnf 10 1\n18446744073709551621 0\n")
  ]

{- | Parse, print, re-parse: the re-parsed CNF must equal the originally parsed CNF. This proves the
printer preserves the parsed model up to canonicalization without depending on the input's literal
whitespace.
-}
assertIdentity :: T.Text -> IO ()
assertIdentity raw =
  case parseDimacs raw of
    Left e -> assertFailure ("fixture did not parse: " <> e)
    Right cnf -> parseDimacs (printDimacs cnf) @?= Right cnf

{- | The exhaustive 2^n CNF oracle ('Lattice.Brute.satisfiableCNF') agrees with each fixture's known
status, and 'solveAllCNF' returns exactly one model for a CNF with a unique solution. The oracle
shares no inference with the SAT engine, which is what will make the later differential meaningful.
-}
oracleTests :: [TestTree]
oracleTests =
  [ testCase "satisfiableCNF is True on the known-SAT fixture" $ do
      cnf <- parseFixture "puzzles/cnf/sat-demo.cnf"
      Brute.satisfiableCNF cnf @?= True
  , testCase "satisfiableCNF is False on the known-UNSAT fixture" $ do
      cnf <- parseFixture "puzzles/cnf/unsat-demo.cnf"
      Brute.satisfiableCNF cnf @?= False
  , testCase "solveAllCNF returns exactly the one model of a unique-solution CNF" $
      -- Over 2 vars, (x1) and (x2) force x1=True, x2=True — a single satisfying assignment.
      case parseDimacs "p cnf 2 2\n1 0\n2 0\n" of
        Left e -> assertFailure ("setup CNF did not parse: " <> e)
        Right cnf -> Brute.solveAllCNF cnf @?= [[True, True]]
  ]

-- | Parse a CNF fixture file or fail the test with the parser's error.
parseFixture :: FilePath -> IO CNF
parseFixture path = do
  raw <- TIO.readFile path
  case parseDimacs raw of
    Left e -> assertFailure ("fixture did not parse: " <> e)
    Right cnf -> pure cnf

{- | Watched-literal BCP tests (SAT-01). A small clause set is built by hand, clauses are attached,
a literal is forced, and propagation drives a fixpoint — the unit case forces the other watch, the
conflict case returns the falsified clause-ref, and the two-watched invariant holds after every step.
The invariant is the silent-killer guard for mis-propagation (T-05-04).
-}
watchedTests :: [TestTree]
watchedTests =
  [ testCase "the invariant holds on a freshly attached clause set" $
      assertBool "checkInvariant should hold after attaching" $
        runST $ do
          st <- SatW.newState 3 [[lit 0 True, lit 1 True], [lit 1 False, lit 2 True]]
          SatW.checkInvariant st
  , testCase "a unit clause forces the other watch (BCP, no conflict)" $
      -- Clause (¬x0 ∨ x1): deciding x0 = True falsifies ¬x0, forcing x1 = True.
      let (confl, v1, ok) = runST $ do
            st <- SatW.newState 2 [[lit 0 False, lit 1 True]]
            SatW.decideLit st (lit 0 True)
            c <- SatW.propagate noEmit st
            x1 <- SatW.stateValueOf st 1
            inv <- SatW.checkInvariant st
            pure (c, x1, inv)
       in do
            confl @?= Nothing -- no conflict
            v1 @?= 1 -- x1 forced True
            assertBool "invariant holds after a unit propagation" ok
  , testCase "an all-falsified clause is reported as a conflict" $
      -- Clauses (¬x0 ∨ x1) and (¬x0 ∨ ¬x1): deciding x0 = True forces x1 = True via the first,
      -- which then falsifies the second clause entirely — a conflict.
      let confl = runST $ do
            st <- SatW.newState 2 [[lit 0 False, lit 1 True], [lit 0 False, lit 1 False]]
            SatW.decideLit st (lit 0 True)
            SatW.propagate noEmit st
       in assertBool "expected a conflict clause-ref" (isJust confl)
  , testCase "a satisfied watch is left untouched (other watch already true)" $
      -- Clause (x0 ∨ x1): with x1 already True, deciding x0 = False (falsifying the x0 watch)
      -- leaves the clause satisfied and propagation reports no conflict.
      let (confl, ok) = runST $ do
            st <- SatW.newState 2 [[lit 0 True, lit 1 True]]
            SatW.decideLit st (lit 1 True)
            _ <- SatW.propagate noEmit st
            SatW.decideLit st (lit 0 False)
            c <- SatW.propagate noEmit st
            inv <- SatW.checkInvariant st
            pure (c, inv)
       in do
            confl @?= Nothing
            assertBool "invariant holds when a clause stays satisfied" ok
  ]
 where
  lit = mkLit

{- | The naive-decision CDCL skeleton (SAT-05, SAT half): 'solveSat' agrees with each fixture's known
status and returns a model that satisfies the formula, and the brute-vs-SAT differential holds on small
random CNF — 'solveSat' reports Sat iff the exhaustive oracle does, and any reported model satisfies
every clause. The oracle shares no inference with the engine, so a backtrack-only divergence (T-05-05)
surfaces here.
-}
skeletonTests :: [TestTree]
skeletonTests =
  [ testCase "solveSat reports Sat on the known-SAT fixture, with a satisfying model" $ do
      cnf <- parseFixture "puzzles/cnf/sat-demo.cnf"
      case solveSat cnf of
        SatT.Unsat -> assertFailure "solveSat reported Unsat on a satisfiable fixture"
        Sat model -> assertBool "the returned model violates a clause" (modelSatisfies cnf model)
  , testCase "solveSat reports Unsat on the known-UNSAT fixture" $ do
      cnf <- parseFixture "puzzles/cnf/unsat-demo.cnf"
      solveSat cnf @?= SatT.Unsat
  , -- Regression for the backjump-to-0 / restart trail-unwind bug: a backjump (or restart) to level 0
    -- used to discard the level-0 unit-clause propagations along with the decision levels, so an input
    -- unit clause was no longer enforced in the final model. This dense UNSAT instance forces a conflict
    -- whose 1UIP backjump target is level 0; it is genuinely UNSAT (x0 from the unit, then the remaining
    -- clauses are contradictory). The random differential found it only at a very high test budget.
    testCase "backjump to level 0 keeps the root unit (UNSAT instance is not reported Sat)" $
      solveSat
        ( CNF
            4
            [[Lit 0], [Lit 2, Lit 4, Lit 1], [Lit 6, Lit 5], [Lit 7, Lit 5], [Lit 3, Lit 4]]
        )
        @?= SatT.Unsat
  , testProperty "brute-vs-SAT differential: solveSat agrees with the oracle (and model satisfies)" $
      forAll genCNF prop_satDifferential
  ]

{- | The brute-vs-SAT differential property: 'solveSat' is satisfiable exactly when the exhaustive
oracle is, and when 'solveSat' returns a model that model satisfies the CNF.
-}
prop_satDifferential :: CNF -> Property
prop_satDifferential cnf = (satByEngine === satByOracle) .&&. modelHolds
 where
  res = solveSat cnf
  satByEngine = res /= SatT.Unsat
  satByOracle = Brute.satisfiableCNF cnf
  modelHolds = case res of
    Sat model -> counterexample "solveSat returned a non-satisfying model" (modelSatisfies cnf model)
    SatT.Unsat -> property True

{- | Does a list of true literals (a 'solveSat' model) satisfy every clause of the CNF? A clause holds
when one of its literals is in the model. Built directly from the literals, independent of the engine.
-}
modelSatisfies :: CNF -> [Lit] -> Bool
modelSatisfies cnf model =
  all (any ((`IntSet.member` trueLits) . litCode)) (cnfClauses cnf)
 where
  trueLits = IntSet.fromList (map litCode model)
  litCode l = 2 * litVar l + (if litPos l then 0 else 1)

{- | Generate a small random CNF (2..5 vars, up to 8 clauses of 1..3 literals) so the exhaustive @2^n@
oracle stays fast. A literal is a random variable with a random polarity; a duplicate-free clause is not
required (the engine and the oracle handle repeats identically).
-}
genCNF :: Gen CNF
genCNF = do
  nVars <- choose (2, 5)
  nClauses <- choose (0, 8)
  clauses <- vectorOf nClauses (genClause nVars)
  pure CNF {cnfVars = nVars, cnfClauses = clauses}
 where
  genClause nVars = do
    width <- choose (1, 3)
    vectorOf width (genLit nVars)
  genLit nVars = do
    v <- choose (0, nVars - 1)
    pos <- elements [True, False]
    pure (mkLit v pos)

{- | 1UIP conflict analysis (SAT-02), the learning-correctness gate. The PRIMARY check is the
implied-clause property — the silent-killer guard, the SAT analogue of the CP sound-propagation test:
every clause the solver learns is implied by the formula, i.e. @formula AND not-clause@ is UNSAT by
the @2^n@ 'Brute' oracle. Plus: 'analyze1UIP' on a constructed conflict produces a clause that is
asserting (exactly one literal at the conflict's current decision level) and backjumps
non-chronologically (below @currentLevel - 1@) on an instance whose UIP jumps more than one level, and
the brute-vs-SAT differential stays green WITH learning enabled.
-}
analyzeTests :: [TestTree]
analyzeTests =
  [ testProperty "every learned clause is implied by the formula (formula AND not-clause is UNSAT)" $
      forAll genCNF prop_learnedImplied
  , testProperty "every learned clause is asserting (one literal at the conflict's current level)" $
      forAll genCNF prop_learnedAsserting
  , testCase "a constructed conflict backjumps non-chronologically (below currentLevel - 1)" $
      assertBool "expected the 1UIP backjump to skip more than one level" nonChronoBackjump
  , testProperty "post-learning differential: solveSat still agrees with the oracle" $
      forAll genCNF prop_postLearnDifferential
  , testProperty
      "post-backjump assert is sound (asserting lit true, no other lit true): the WR-01 lock"
      $ forAll genDenseCNF prop_assertedClauseSound
  ]

{- | The PRIMARY property (T-05-07): collect every clause the solver learns on a random CNF and assert
each is implied by the formula — @formula AND (negation of the learned clause)@ is UNSAT by the
exhaustive oracle. A learned clause that is not implied silently corrupts trust in the result; this is
the SAT counterpart of the CP sound-propagation guard and gates the plan.
-}
prop_learnedImplied :: CNF -> Property
prop_learnedImplied cnf =
  let (_, learned) = solveSatLearned cnf
   in conjoinAll [impliedBy cnf c | c <- learned]
 where
  conjoinAll [] = property True
  conjoinAll (p : ps) = p .&&. conjoinAll ps

{- | A clause @C@ is implied by the CNF iff @formula AND not-C@ is unsatisfiable. @not-C@ is the
conjunction of the negations of @C@'s literals (one unit clause per negated literal). Checked by the
@2^n@ oracle, which shares no inference with the engine.
-}
impliedBy :: CNF -> [Lit] -> Property
impliedBy cnf clause =
  counterexample ("learned clause not implied by the formula: " <> show (map litCodeOf clause)) $
    not (Brute.satisfiableCNF augmented)
 where
  augmented = cnf {cnfClauses = cnfClauses cnf <> [[negLit l] | l <- clause]}
  litCodeOf (Lit code) = code

{- | Every learned clause is asserting: exactly one of its literals was assigned at the conflict's
current decision level. A non-asserting learned clause does not flip the search forward and loops it
(T-05-08); the 1UIP stop condition guarantees this shape. Re-derived here by replaying the solve and
checking each learned clause against the levels recorded when it was learned (the collector records the
conflict level alongside the clause).
-}
prop_learnedAsserting :: CNF -> Property
prop_learnedAsserting cnf =
  let (_, learned) = solveSatLearnedLevels cnf
   in conjoinAll [assertingAt c lvl | (c, lvl) <- learned]
 where
  conjoinAll [] = property True
  conjoinAll (p : ps) = p .&&. conjoinAll ps
  assertingAt c lvl =
    counterexample ("learned clause is not asserting at level " <> show lvl) $
      length [() | (_, l) <- c, l == lvl] === 1

{- | A constructed instance whose 1UIP analysis jumps more than one level. The single clause
@(¬x0 ∨ x4)@ ties the last decision (x4) only to the first (x0). Deciding x0..x3 true across levels 1..4
and then x4 false at level 5 falsifies the clause — a conflict. The 1UIP learned clause involves only x4
(level 5) and x0 (level 1), so its second-highest level is 1: the backjump target is 1, far below the
chronological @currentLevel - 1 = 4@. A chronological undo would land at exactly 4; a non-chronological
backjump lands at 1.
-}
nonChronoBackjump :: Bool
nonChronoBackjump = runST $ do
  st <- SatW.newState 5 [[lit 0 False, lit 4 True]]
  -- Five independent decisions; x4 is itself a decision (reason -1), so the conflict's only reason chain
  -- runs through the single clause back to x0 at level 1.
  SatW.decideLit st (lit 0 True)
  _ <- SatW.propagate noEmit st
  SatW.decideLit st (lit 1 True)
  _ <- SatW.propagate noEmit st
  SatW.decideLit st (lit 2 True)
  _ <- SatW.propagate noEmit st
  SatW.decideLit st (lit 3 True)
  _ <- SatW.propagate noEmit st
  SatW.decideLit st (lit 4 False)
  confl <- SatW.propagate noEmit st
  case confl of
    Nothing -> pure False -- no conflict: the construction is wrong, fail the test
    Just ref -> do
      (_, bj) <- analyze1UIP st ref
      cur <- SatW.currentLevel st
      pure (bj < cur - 1)
 where
  lit = mkLit

{- | The post-learning differential (T-05-09): with conflict analysis and non-chronological backjump
wired into 'solveSat', the engine still agrees with the exhaustive oracle on satisfiability and any
returned model still satisfies the formula. A learning bug that corrupts the trail on backjump surfaces
on a backtracking instance here.
-}
prop_postLearnDifferential :: CNF -> Property
prop_postLearnDifferential = prop_satDifferential

{- | A test-only solve that also returns each learned clause paired with the decision level that was
current when it was learned (in @(literal, assignment-level)@ form per literal), for the asserting-clause
check. Built on the same collecting solve as 'solveSatLearned'.
-}
solveSatLearnedLevels :: CNF -> (SatResult, [([(Lit, Int)], Int)])
solveSatLearnedLevels = solveSatLearnedAtLevels

{- | WR-01 lock: the precise, load-bearing post-backjump invariant — written to match the engine's
ACTUAL convention, which is deliberately non-canonical and was confirmed empirically (see below).

The engine's @unwindTo bj@ truncates the trail to @tLevels[bj-1]@, i.e. it drops decision level @bj@
ITSELF along with everything above it — diverging from MiniSat @cancelUntil(bj)@, which keeps level
@bj@. The reviewer (WR-01) worried this leaves the learned clause's highest /other/ literal (at level
@bj@ by 'secondHighest') UNASSIGNED, so the asserting clause is not unit when the asserting literal is
enqueued, and that a later 1UIP resolution against this clause could then drop that unassigned literal
('Analyze.absorb' reads @varLevel == -1 <= 0@ and skips it) and learn a NON-IMPLIED clause.

Empirically (replaying the solver's exact @analyze1UIP; unwindTo bj; enqueueLit asserting@ step on
random dense CNFs): the clause is indeed NOT unit — the second-highest literal sits at level @bj@ and
the unwind un-assigns it. So the MiniSat unit shape does NOT hold here. But this is NOT a soundness
bug, and the reason it is safe is the load-bearing invariant this property locks, together with the
already-green implied-clause property ('prop_learnedImplied' at 100000+):

  1. The asserting literal is assigned TRUE at assert time (the search makes forward progress), AND
  2. every OTHER literal of the learned clause is either FALSE or sits at exactly level @bj@ — never
     at a level ABOVE @bj@. A literal stranded above @bj@ would be a genuine trail/level desync (the
     class the acef277 root-unit fix belonged to); a literal at level @bj@ is the deliberately-dropped
     band, re-decided later, and the implied-clause property proves no non-implied clause results.

So the verdict is: the @unwindTo bj@ / @secondHighest@ pair is a self-consistent NON-CANONICAL
convention, not the MiniSat one. This test is the regression lock; the acef277 level-0 fix is
untouched (an @unwindTo 0@ still keeps the root units). Do NOT "fix" 'unwindTo' to keep level @bj@ on
the strength of the static concern — that would change a working, differentially-green invariant.
-}
prop_assertedClauseSound :: CNF -> Property
prop_assertedClauseSound cnf =
  let (ok, diag) = runST $ do
        st <- SatW.newState (cnfVars cnf) (cnfClauses cnf)
        confl0 <- SatW.propagate noEmit st
        case confl0 of
          Just _ -> pure (True, "")
          Nothing -> driveCheck st (0 :: Int)
   in counterexample diag (property ok)
 where
  -- Bound the steps so an adversarial instance cannot loop the test; the tiny dense CNFs settle fast.
  stepBudget = 2000 :: Int
  driveCheck st !steps
    | steps >= stepBudget = pure (True, "")
    | otherwise = do
        mv <- pickInOrder st
        case mv of
          Nothing -> pure (True, "") -- a full assignment with no conflict: nothing more to check.
          Just v -> do
            SatW.decideLit st (mkLit v True)
            propagateCheck st steps
  propagateCheck st !steps = do
    confl <- SatW.propagate noEmit st
    case confl of
      Nothing -> driveCheck st (steps + 1)
      Just ref -> do
        lvl <- SatW.currentLevel st
        if lvl <= 0
          then pure (True, "") -- a conflict at level 0 ends the solve (Unsat); no clause is asserted.
          else do
            (learned, bj) <- analyze1UIP st ref
            case learned of
              [] -> pure (True, "") -- an empty learned clause is outright Unsat; nothing asserted.
              (asserting : rest) -> do
                -- Check the FIRST conflict only, then stop: up to here the trail was built by faithful
                -- real decisions+propagations, so the post-backjump state is exactly the engine's. We
                -- deliberately do not continue driving (which would need 'learnAndAttach' + the
                -- @ssLevel := bj@ / @ssQHead@ resync to stay faithful, dragging in 'primitive'); one
                -- honest backjump per random instance is what locks the invariant.
                Trail.unwindTo (SatW.ssTrail st) bj
                SatW.enqueueLit st asserting ref
                -- (1) the asserting literal is now true: the search advances.
                av <- SatW.litValue st asserting
                -- (2) every OTHER literal is false (it was below bj, still assigned and false) or
                -- unassigned (it was at level bj, the band the unwind legitimately dropped). None is
                -- true: no other literal spuriously satisfies the clause, and none survives assigned
                -- at a level the backjump should have cleared. (1)+(2) plus the green implied-clause
                -- property is what makes the non-unit assert sound.
                restOk <- allRestSound st rest
                if av == 1 && restOk
                  then pure (True, "") -- first honest backjump checked; stop (see note above).
                  else do
                    restLvls <- mapM (Trail.varLevel (SatW.ssTrail st) . litVar) rest
                    restVals <- mapM (SatW.litValue st) rest
                    pure
                      ( False
                      , "conflictLvl="
                          <> show lvl
                          <> " bj="
                          <> show bj
                          <> " learned(var,pos)="
                          <> show (map (\l -> (litVar l, litPos l)) learned)
                          <> " assertingValue="
                          <> show av
                          <> " restLevels="
                          <> show restLvls
                          <> " restValues="
                          <> show restVals
                      )
  -- The first unassigned variable, mirroring a trivial branch order (no heuristic needed for the lock).
  pickInOrder st = go 0
   where
    nv = cnfVars cnf
    go !v
      | v >= nv = pure Nothing
      | otherwise = do
          val <- Trail.varValue (SatW.ssTrail st) v
          if val == -1 then pure (Just v) else go (v + 1)
  -- Each non-asserting literal must be false (still assigned, below bj) or unassigned (the dropped
  -- level-bj band). A literal that reads TRUE here would mean the clause is satisfied by something
  -- other than the asserting literal — the post-backjump state the lock rules out.
  allRestSound st = go
   where
    go [] = pure True
    go (l : ls) = do
      lv <- SatW.litValue st l
      if lv == 0 || lv == -1 then go ls else pure False

{- | VSIDS + phase saving + the Luby generator (SAT-03), the deterministic search-heuristic deliverable.
These are pinned to exact values — no randomness: the Luby sequence equals the known literal sequence; a
bumped variable wins 'pickBranch' over an un-bumped one; the overflow rescale scales every activity down
while preserving the relative order; and phase saving returns the last-saved polarity. End-to-end search
correctness is covered separately by the post-heuristics differential (the 'analyze' / 'skeleton' groups).
-}
vsidsTests :: [TestTree]
vsidsTests =
  [ testCase "luby 1..15 equals the known reluctant-doubling sequence" $
      map luby [1 .. 15] @?= [1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8]
  , testCase "luby continues correctly past the first block (16..18)" $
      -- 1,1,2,4,8 begins the next block (i=16,17,18 -> 1,1,2); pins the recurrence past 2^k-1.
      map luby [16, 17, 18] @?= [1, 1, 2]
  , testCase "a bumped variable wins pickBranch over an un-bumped one" $
      -- Two unassigned variables; bump v1 once. pickBranch (argmax activity) must return v1.
      assertBool "the bumped variable should be picked first" $
        runST $ do
          st <- SatW.newState 3 []
          vs <- newVSIDS 3
          bumpActivity vs 1
          picked <- pickBranch st vs
          pure (picked == Just 1)
  , testCase "pickBranch orders by activity magnitude, not variable index (WR-06)" $
      -- The single-bump test above passes even if pickBranch ignored activity and returned the first
      -- unassigned var (here v1 is also the lowest index). This pins ORDERING: bump v2 thrice and v1
      -- once, so activity(v2) > activity(v1) > activity(v0)=0. pickBranch must return the higher-index
      -- v2 first; after v2 is assigned it must return v1 (not v0, the lowest index). A regression that
      -- dropped the activity comparison (returning the first unassigned var) would pick v0 here.
      assertBool "pickBranch must follow activity order v2 then v1, not index order" $
        runST $ do
          st <- SatW.newState 3 []
          vs <- newVSIDS 3
          bumpActivity vs 2
          bumpActivity vs 2
          bumpActivity vs 2
          bumpActivity vs 1
          first <- pickBranch st vs
          -- Assign v2 (the picked one) so the next pick is over {v0, v1}.
          SatW.decideLit st (mkLit 2 True)
          second <- pickBranch st vs
          pure (first == Just 2 && second == Just 1)
  , testCase "pickBranch returns Nothing when every variable is assigned" $
      -- With no unassigned variable left, there is nothing to branch on.
      assertBool "a fully assigned state has no branch variable" $
        runST $ do
          st <- SatW.newState 2 [[lit 0 True], [lit 1 True]]
          _ <- SatW.propagate noEmit st
          vs <- newVSIDS 2
          picked <- pickBranch st vs
          pure (isNothing picked)
  , testCase "the overflow rescale scales activities down and preserves their order" $
      -- Two activities past 1e100 (one strictly larger); after rescale both shrink by 1e-100 and the
      -- larger stays larger. The relative order is what the branching heuristic depends on (Pitfall 5).
      assertBool "rescale must shrink activities and keep the larger one larger" $
        runST $ do
          vs <- newVSIDS 2
          -- Drive both activities past the 1e100 threshold by bumping with a huge increment.
          bumpActivity vs 0
          bumpActivity vs 0 -- v0 bumped twice
          bumpActivity vs 1 -- v1 bumped once: a0 > a1, both eventually > 1e100 after scaling up
          -- Force the activities above the threshold, then rescale and read them back.
          before0 <- readActivity vs 0
          before1 <- readActivity vs 1
          rescaleActivities vs
          after0 <- readActivity vs 0
          after1 <- readActivity vs 1
          pure (after0 < before0 && after1 < before1 && (after0 > after1) == (before0 > before1))
  , testCase "phase saving returns the last-saved polarity" $
      -- Save True for v0 and False for v1; branchPhase must return exactly those.
      assertBool "branchPhase should return the saved polarity per variable" $
        runST $ do
          st <- SatW.newState 2 []
          savePhase st 0 True
          savePhase st 1 False
          p0 <- branchPhase st 0
          p1 <- branchPhase st 1
          pure (p0 && not p1)
  ]
 where
  lit = mkLit

{- | The post-heuristics differential (the second half of SAT-05). With VSIDS branching, phase saving,
and the Luby restart schedule wired into the CDCL loop, the solver still agrees with the exhaustive
oracle on satisfiability and any returned model still satisfies the formula. VSIDS/Luby change WHICH
path is explored, never which answers are valid — a restart that dropped a learned clause or corrupted
the trail (T-05-11) would diverge from the oracle here. The 'denser' generator piles more clauses onto
fewer variables so conflicts and restarts actually fire.
-}
heuristicsTests :: [TestTree]
heuristicsTests =
  [ testProperty "post-heuristics differential: VSIDS+Luby solveSat agrees with the oracle" $
      forAll genCNF prop_satDifferential
  , testProperty "restart-prone differential: a dense CNF still agrees with the oracle" $
      forAll genDenseCNF prop_satDifferential
  , testCase "a restart-prone UNSAT instance is still reported Unsat" $
      -- All eight clauses over 3 vars: every assignment is excluded, so the formula is UNSAT. The
      -- search drives many conflicts (and crosses the Luby budget) before proving it.
      let allClauses =
            [ [mkLit 0 s0, mkLit 1 s1, mkLit 2 s2]
            | s0 <- [True, False]
            , s1 <- [True, False]
            , s2 <- [True, False]
            ]
          cnf = CNF {cnfVars = 3, cnfClauses = allClauses}
       in solveSat cnf @?= SatT.Unsat
  ]

{- | A denser small CNF (3..5 vars, 6..14 clauses of 1..3 literals): more clauses on fewer variables
than 'genCNF', so the solver hits conflicts and the Luby restart schedule fires, exercising the wired
heuristics rather than solving everything on the first descent. Still tiny enough for the @2^n@ oracle.
-}
genDenseCNF :: Gen CNF
genDenseCNF = do
  nVars <- choose (3, 5)
  nClauses <- choose (6, 14)
  clauses <- vectorOf nClauses (genClause nVars)
  pure CNF {cnfVars = nVars, cnfClauses = clauses}
 where
  genClause nVars = do
    width <- choose (1, 3)
    vectorOf width (genLit nVars)
  genLit nVars = do
    v <- choose (0, nVars - 1)
    pos <- elements [True, False]
    pure (mkLit v pos)

{- | The three-way differential (SAT-05, the phase's load-bearing correctness gate). A small graph is
dual-encoded to CNF by 'graphCNF', so CP (the 'graphModel' CSP), SAT ('solveSat' on the CNF), and brute
force (BOTH the @2^n@ CNF oracle 'Brute.satisfiableCNF' AND the CP enumerator 'Brute.solveFirst') solve
the genuinely same instance. The three engines must AGREE on satisfiability, and on a unique-solution
instance on the coloring. If the dual encoding were wrong (T-05-15), SAT would solve a different problem
than CP/brute and diverge here — that is exactly what this gate catches. Graphs are tiny (2..4 vertices,
2..3 colors) so the @2^n@ oracle over the @vertices * colors@ CNF variables stays fast.
-}
threeWayTests :: [TestTree]
threeWayTests =
  [ testProperty "CP, SAT, and brute force agree on satisfiability (dual-encoded graph)" $
      forAll genTinyGraph prop_threeWayAgree
  , testProperty "a SAT model decodes to a valid k-coloring of the graph" $
      forAll genTinyGraph prop_satModelDecodesToColoring
  , testProperty "on a unique-solution instance CP, SAT, and brute force agree on the coloring" $
      forAll genTinyGraph prop_threeWayUnique
  , testCase "the Petersen graph is SAT-satisfiable via the dual encoding (3-colorable)" $ do
      raw <- TIO.readFile "puzzles/graph/petersen.json"
      case parseGraph raw of
        Left e -> assertFailure ("graph parse failed: " <> e)
        Right g -> do
          assertBool "CP could not 3-color Petersen" (solve (graphModel g) /= NoSolution)
          case solveSat (graphCNF g) of
            SatT.Unsat -> assertFailure "SAT reported the 3-colorable Petersen CNF as Unsat"
            Sat model ->
              assertBool
                "the decoded SAT coloring is not a valid Petersen coloring"
                (satisfies (graphModel g) (cnfColoring g model))
  ]

{- | The three engines agree on satisfiability: CP (graphModel), SAT (solveSat . graphCNF), the @2^n@
CNF oracle, and the CP brute enumerator all report the same k-colorability verdict.
-}
prop_threeWayAgree :: Graph -> Property
prop_threeWayAgree g =
  counterexample (show (cpSat, satSat, cnfOracle, cpBrute)) $
    (cpSat === satSat) .&&. (satSat === cnfOracle) .&&. (cnfOracle === cpBrute)
 where
  cpSat = solve (graphModel g) /= NoSolution
  satSat = solveSat (graphCNF g) /= SatT.Unsat
  cnfOracle = Brute.satisfiableCNF (graphCNF g)
  cpBrute = isJust (Brute.solveFirst (graphModel g))

{- | When SAT reports the dual-encoded graph satisfiable, the decoded coloring is a genuine k-coloring
of the original graph (every vertex gets exactly one color, adjacent vertices differ) — the proof that
'graphCNF' and its 'cnfColoring' decode are faithful to 'graphModel'.
-}
prop_satModelDecodesToColoring :: Graph -> Property
prop_satModelDecodesToColoring g = case solveSat (graphCNF g) of
  SatT.Unsat -> property True
  Sat model ->
    let coloring = cnfColoring g model
     in counterexample ("decoded coloring is not valid: " <> show (IntMap.toList coloring)) $
          satisfies (graphModel g) coloring

{- | On a graph whose CP coloring is unique (the oracle enumerates exactly one over colors 1..k), CP
returns that coloring and the decoded SAT coloring equals it. Color-symmetry makes a literally unique
coloring rare, so this is usually vacuous — but when it fires it pins the actual labeling across all
three engines, not just satisfiability.
-}
prop_threeWayUnique :: Graph -> Property
prop_threeWayUnique g = case Brute.solveAll (graphModel g) of
  [unique] ->
    let cpAgrees = case solve (graphModel g) of
          Solved a -> a === unique
          NoSolution -> counterexample "CP found nothing but the oracle's coloring is unique" False
        satAgrees = case solveSat (graphCNF g) of
          SatT.Unsat -> counterexample "SAT found nothing but the oracle's coloring is unique" False
          Sat model -> cnfColoring g model === unique
     in cpAgrees .&&. satAgrees
  _ -> property True

{- | Tiny graphs (2..4 vertices, 2..3 colors) for the three-way differential: small enough that the
@2^n@ CNF oracle over the @vertices * colors@ boolean variables (at most 12) stays fast.
-}
genTinyGraph :: Gen Graph
genTinyGraph = do
  n <- choose (2, 4)
  k <- choose (2, 3)
  edges <- sublistOf [(i, j) | i <- [0 .. n - 1], j <- [i + 1 .. n - 1]]
  pure Graph {graphK = k, graphVertexCount = n, graphEdges = edges}
