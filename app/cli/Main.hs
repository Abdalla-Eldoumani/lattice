{- | Command-line entry point. Read a puzzle file and solve it in fast mode: a CP puzzle (the default
arm) prints the solved grid, or a DIMACS CNF (the @--sat@ arm) runs the SAT engine and prints
@SAT@ plus a model or @UNSAT@. IO lives here; the solver core under @src/@ stays pure. The exit-code
contract: a malformed file exits 1, wrong arguments exit 2, and a solved or soundly-unsolvable instance
exits 0 (UNSAT, like a CP "no solution", is an answer, not an error).
-}
module Main (main) where

import Control.Exception (IOException, try)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Lattice (
  Lit (..),
  Result (..),
  SatResult (..),
  decode,
  parseDimacs,
  parseGrid,
  solve,
  solveSat,
  toModel,
 )
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitSuccess, exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--sat", path] -> solveDimacsFile path
    [path] -> solveFile path
    _ -> do
      hPutStrLn stderr "usage: lattice-cli <puzzle-file> | --sat <dimacs-file>"
      exitWith (ExitFailure 2)

{- | Read, parse, solve, and print one puzzle under the exit-code contract. A read error (a
missing or unreadable file) is reported cleanly rather than as an uncaught exception.
-}
solveFile :: FilePath -> IO ()
solveFile path = do
  readResult <- try (TIO.readFile path) :: IO (Either IOException Text)
  case readResult of
    Left _ -> do
      hPutStrLn stderr ("cannot read file: " <> path)
      exitWith (ExitFailure 1)
    Right raw -> case parseGrid raw of
      Left err -> do
        hPutStrLn stderr ("parse error: " <> show err)
        exitWith (ExitFailure 1)
      Right grid ->
        let model = toModel grid
         in case solve model of
              Solved a -> TIO.putStrLn (decode grid a) >> exitSuccess
              NoSolution -> putStrLn "no solution" >> exitSuccess

{- | Read, parse, and SAT-solve one DIMACS CNF file in fast mode under the same exit-code contract: a
read error or a malformed DIMACS file (a 'Left' from the total 'parseDimacs') exits 1; @SAT@ with a
model or @UNSAT@ exits 0. The model is printed as the standard space-separated signed DIMACS literals
(positive = true, negative = false), one per variable in variable order, terminated by @0@.
-}
solveDimacsFile :: FilePath -> IO ()
solveDimacsFile path = do
  readResult <- try (TIO.readFile path) :: IO (Either IOException Text)
  case readResult of
    Left _ -> do
      hPutStrLn stderr ("cannot read file: " <> path)
      exitWith (ExitFailure 1)
    Right raw -> case parseDimacs raw of
      Left err -> do
        hPutStrLn stderr ("parse error: " <> err)
        exitWith (ExitFailure 1)
      Right cnf -> case solveSat cnf of
        Sat model -> do
          putStrLn "SAT"
          putStrLn (showModel model)
          exitSuccess
        Unsat -> putStrLn "UNSAT" >> exitSuccess

{- | Render a SAT model (the list of true literals) as a DIMACS-style assignment line: each literal as
a signed 1-based variable id in variable order, terminated by @0@ (the conventional solver output).
-}
showModel :: [Lit] -> String
showModel model = unwords (map (show . signedOf) (sortOn litVarOf model) <> ["0"])
 where
  litVarOf (Lit code) = code `div` 2
  signedOf (Lit code) =
    let v = code `div` 2 + 1
     in if even code then v else negate v
