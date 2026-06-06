-- | Test entry point. This suite is the correctness contract for the whole project.
-- Milestone 1 expands it with the groups that actually matter:
--
--   * soundness            any returned assignment satisfies every constraint (QuickCheck)
--   * completeness (small) if the solver reports unsolvable, an exhaustive brute-force
--                          check agrees, on small instances
--   * sound propagation    propagation never removes a value present in some solution
--                          (check against brute force on small grids)
--   * differential testing CP vs brute force agree on small instances. This is the main
--                          defense against the silent-wrong-on-hard-instances class of bug.
--
-- This stub wires tasty + HUnit + QuickCheck so those groups have a home and CI is green
-- from the first build.
module Main (main) where

import qualified Lattice
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "lattice"
    [ testGroup
        "smoke"
        [ testCase "version is set" (Lattice.version @?= "0.1.0.0"),
          testProperty "reverse is its own inverse" $
            \xs -> reverse (reverse xs) == (xs :: [Int])
        ]
    ]
