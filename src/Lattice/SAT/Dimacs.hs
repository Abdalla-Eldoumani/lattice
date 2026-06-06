{- | The DIMACS CNF boundary: a total parser from untrusted text to a 'CNF', and a canonical printer.
This is an untrusted-input boundary, so 'parseDimacs' is a total @Either String CNF@ in the same
posture as 'Lattice.Encode.Graph.parseGraph' — every numeric parse is 'readMaybe'-bounded (no partial
parse, no unsafe first-element or index access), and a malformed instance is a 'Left', never a crash
or a silently wrong formula. The Phase 4 review flagged exactly the partial-function-on-untrusted-
input bug class this guards against.

DIMACS is 1-based and signed; the engine is 0-based and MiniSat-encoded. The mapping
@dimacsVar v -> 2*(v-1) + sign@ happens here at the boundary only; the engine never sees DIMACS
coordinates.

'printDimacs' is canonical: the @p cnf N M@ header, one clause per line, literals in their original
parse order (the printer never reorders them — reordering would change textual identity and is not
required), single-space separated, each terminated by @ 0@, with a trailing newline and no comments.
The identity that matters is @parseDimacs (printDimacs (parseDimacs raw)) == parseDimacs raw@: parse,
print, re-parse yields the same 'CNF'. The input's exact whitespace and comments are deliberately not
preserved.
-}
module Lattice.SAT.Dimacs (
  parseDimacs,
  printDimacs,
) where

import Data.Text (Text)
import Data.Text qualified as T
import Text.Read (readMaybe)

import Lattice.SAT.Types (CNF (..), Clause, litPos, litVar, mkLit)

{- | The maximum variable and clause counts the parser accepts in a @p cnf N M@ header. A header far
above any instance this project handles is rejected as a 'Left' rather than triggering a runaway
@2*N@ allocation when the engine sizes its per-literal arrays (the queens @4..20@ bound has the same
shape). Sized for the FLEX tier's tiny fixtures: the bundled CNFs and the graph dual encodings are
tens of variables, so @10000@ is already generous (and still seeds @2 * 10000@ boxed watch buffers,
the @2*N@ allocation this guards). The old @1000000@ let a single small header line pin hundreds of MB
of 'Lattice.SAT.Watched.newState' allocation on the forked server solve thread from a lie in the
header (M can be tiny). The server is loopback-only and single-user, so the threat is a local user
exhausting their own memory — but the FLEX-sized ceiling refuses it outright rather than honoring it.
-}
dimacsCeiling :: Int
dimacsCeiling = 10000

{- | Parse DIMACS CNF text into a 'CNF', or report why it is malformed. Drops @c@ comment lines, reads
exactly one authoritative @p cnf N M@ header, then reads @0@-terminated clauses (whitespace and
newlines are flexible separators, so a clause may span lines). Rejects, as a 'Left': a missing or
malformed header, an N or M above 'dimacsCeiling', any non-@c@/non-@p@ token before the header, a
literal whose magnitude exceeds N, and a final clause left unterminated by @0@.
-}
parseDimacs :: Text -> Either String CNF
parseDimacs t = do
  (nVars, _nClauses, rest) <- readHeader (contentLines t)
  clauses <- readClauses nVars (concatMap T.words rest)
  pure CNF {cnfVars = nVars, cnfClauses = clauses}

{- | The lines that carry data: comment lines (@c ...@) and blank lines are dropped, so the first
remaining line must be the header.
-}
contentLines :: Text -> [Text]
contentLines = filter (not . isComment) . map T.strip . T.lines
 where
  isComment line = T.null line || T.isPrefixOf (T.pack "c ") line || line == T.pack "c"

{- | Read the authoritative @p cnf N M@ header off the front of the content lines, validating the
counts and the ceiling. Anything other than a well-formed header in the first content position is a
'Left' (this catches a stray token before the header, since comments were already dropped).
-}
readHeader :: [Text] -> Either String (Int, Int, [Text])
readHeader [] = Left "missing 'p cnf N M' header"
readHeader (line : rest) =
  case T.words line of
    [p, cnf, nv, nc]
      | p == T.pack "p" && cnf == T.pack "cnf" -> do
          nVars <- boundedCount "variable" nv
          nClauses <- boundedCount "clause" nc
          pure (nVars, nClauses, rest)
    _ -> Left ("expected a 'p cnf N M' header, got: " <> T.unpack line)

-- | Parse a header count: a non-negative integer no larger than 'dimacsCeiling'.
boundedCount :: String -> Text -> Either String Int
boundedCount what tok = case readMaybe (T.unpack tok) of
  Just n
    | n < 0 -> Left ("negative " <> what <> " count: " <> T.unpack tok)
    | n > dimacsCeiling -> Left (what <> " count " <> T.unpack tok <> " exceeds the sane ceiling")
    | otherwise -> Right n
  Nothing -> Left ("non-numeric " <> what <> " count: " <> T.unpack tok)

{- | Read the @0@-terminated clauses from the flat token stream after the header. Each token is a
'readMaybe'-bounded signed 'Integer' (not 'Int', which would WRAP on overflow and let an out-of-range
or wrapped-into-range literal slip past the magnitude check); @0@ closes the current clause; any other
literal's magnitude must not exceed the declared variable count. A leftover non-empty clause at end of
input (no trailing @0@) is rejected.
-}
readClauses :: Int -> [Text] -> Either String [Clause]
readClauses nVars toks0 = go [] toks0 []
 where
  -- The walk threads the finished clauses (reversed), the token stream, and the in-progress
  -- (reversed) clause.
  go done [] [] = Right (reverse done)
  go _ [] (_ : _) = Left "the final clause is not terminated by 0"
  go done (tok : toks) cur = do
    -- Read the literal as 'Integer', not 'Int': @readMaybe \@Int@ WRAPS on overflow (a token past
    -- maxBound returns @Just minBound@, not 'Nothing'; a 2^64-sized token wraps modulo 2^64 to a
    -- small in-range value), so an 'Int' parse both (a) admits a wrapped minBound the @abs@-based
    -- bound let index a maxBound variable into the unboxed arrays — an uncaught crash — and (b)
    -- silently corrupts the formula by accepting a wrapped literal as a different variable. 'Integer'
    -- never wraps, so the magnitude check below sees the true value.
    n <- maybe (Left ("non-numeric literal: " <> T.unpack tok)) Right (readMaybe (T.unpack tok))
    if n == 0
      then go (reverse cur : done) toks []
      else do
        lit <- toLit n
        go done toks (lit : cur)

  -- A SIGNED range check on the true (un-wrapped) 'Integer' magnitude. After the guard the value is
  -- within @[-nVars, nVars]@ and nVars <= dimacsCeiling, so @fromInteger@ and @abs@ cannot overflow.
  toLit n
    | n < negate nVarsZ || n > nVarsZ =
        Left ("literal magnitude " <> show n <> " exceeds the declared variable count")
    | otherwise = Right (mkLit (fromInteger (abs n) - 1) (n > 0))

  -- The declared variable count promoted to 'Integer' for the un-wrapped magnitude comparison.
  nVarsZ :: Integer
  nVarsZ = fromIntegral nVars

-- | The canonical DIMACS text for a 'CNF': header, one clause per line, original literal order.
printDimacs :: CNF -> Text
printDimacs cnf =
  T.unlines (headerLine : map clauseLine (cnfClauses cnf))
 where
  headerLine =
    T.unwords
      [ T.pack "p"
      , T.pack "cnf"
      , T.pack (show (cnfVars cnf))
      , T.pack (show (length (cnfClauses cnf)))
      ]
  clauseLine cls = T.unwords (map (T.pack . show) (map dimacsOf cls ++ [0]))
  dimacsOf lit =
    let v = litVar lit + 1
     in if litPos lit then v else negate v
