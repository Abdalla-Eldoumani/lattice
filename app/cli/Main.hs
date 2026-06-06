{- | Command-line entry point. Read a puzzle file, solve it with the CP engine in fast mode, and
print the solved grid or a sound report that none exists. IO lives here; the solver core under
@src/@ stays pure. The exit-code contract: a malformed file exits 1, wrong arguments exit 2, and a
solved or soundly-unsolvable instance exits 0 (unsolvable is an answer, not an error).
-}
module Main (main) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Lattice (Result (..), decode, parseGrid, solve, toModel)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitSuccess, exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> solveFile path
    _ -> do
      hPutStrLn stderr "usage: lattice-cli <puzzle-file>"
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
