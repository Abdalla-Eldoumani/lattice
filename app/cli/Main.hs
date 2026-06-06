-- | Command-line entry point. Milestone 1 replaces this stub with: read a puzzle
-- file, run the CP solver in fast mode, and print the solution or a sound report
-- that none exists. Keep IO at the edges; the solver stays pure (or in ST) underneath.
module Main (main) where

import qualified Lattice

main :: IO ()
main = do
  putStrLn ("lattice " <> Lattice.version)
  putStrLn "cli stub. milestone 1: parse a puzzle file and solve it in the terminal."
