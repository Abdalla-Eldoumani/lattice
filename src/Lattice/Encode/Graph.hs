{-# LANGUAGE OverloadedStrings #-}

{- | The graph-coloring encoder (ENCODE-02). It parses the fixed-layout JSON in @puzzles/graph/*.json@
and builds a CSP: one variable per vertex with domain @{1..k}@, and a 'NotEqual' for every edge so
adjacent vertices take different colors. The @x,y@ layout coordinates are for the visualizer and are
not needed to solve, so they are read past.
-}
module Lattice.Encode.Graph (
  Graph (..),
  parseGraph,
  graphModel,
) where

import Data.Aeson (FromJSON (..), Value, eitherDecodeStrict, withObject, (.:))
import Data.IntMap.Strict qualified as IntMap
import Data.IntSet qualified as IntSet
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Lattice.Core.Types (Constraint (..), Domain (..), Model (..))

{- | A parsed graph-coloring instance: the number of colors, the vertex count (ids are @0..n-1@),
and the undirected edges.
-}
data Graph = Graph
  { graphK :: Int
  , graphVertexCount :: Int
  , graphEdges :: [(Int, Int)]
  }
  deriving (Eq, Show)

instance FromJSON Graph where
  parseJSON = withObject "graph-coloring instance" $ \o -> do
    k <- o .: "k"
    vs <- o .: "vertices"
    edges <- o .: "edges"
    pure Graph {graphK = k, graphVertexCount = length (vs :: [Value]), graphEdges = edges}

{- | Parse a graph-coloring instance from its JSON text. Total: structural decode plus a bounds
check on the untrusted edge list and color count, so a malformed instance is a 'Left' rather than a
silently wrong answer. An edge naming a vertex id outside @0..vertexCount-1@ would otherwise seed an
all-empty domain for that id and report the whole instance unsatisfiable; @k < 1@ gives every vertex
an empty domain (trivially unsat). Both are rejected here so the server's untrusted-input boundary
gets a clean 'Left' instead of a wrong 'NoSolution'.

@k@ and the vertex count are also bounded by a DoS ceiling, the same rationale as @dimacsCeiling@ in
"Lattice.SAT.Dimacs": 'graphModel' builds an @{1..k}@ domain per vertex and the SAT dual encoder
("Lattice.SAT.Encode") builds @C(k,2)@ at-most-one clauses per vertex, so an unbounded @k@ or vertex
count from one tiny untrusted definition (e.g. @{"k":50000000,...}@) exhausts memory on the forked
solve thread. The bundled fixtures are @k <= 4@, ~10 vertices, so @kCeiling = 16@ / @vertexCeiling =
64@ are far above any real instance while keeping the worst-case graph -> CNF (@C(16,2)*64@ plus
@edges*16@) to tens of thousands of clauses — fast and bounded.
-}
parseGraph :: Text -> Either String Graph
parseGraph t = eitherDecodeStrict (encodeUtf8 t) >>= validate
 where
  validate g
    | graphK g < 1 = Left "k must be >= 1"
    | graphK g > kCeiling = Left ("k exceeds the sane ceiling of " <> show kCeiling)
    | graphVertexCount g > vertexCeiling =
        Left ("vertex count exceeds the sane ceiling of " <> show vertexCeiling)
    | any (outOfRange (graphVertexCount g)) (graphEdges g) =
        Left "edge references a vertex id outside 0..vertexCount-1"
    | otherwise = Right g
  outOfRange n (u, v) = u < 0 || v < 0 || u >= n || v >= n

-- | DoS ceilings on @k@ and the vertex count (see 'parseGraph'): far above the fixtures, small CNF.
kCeiling, vertexCeiling :: Int
kCeiling = 16
vertexCeiling = 64

-- | Build the CSP: each vertex takes a color in @{1..k}@; adjacent vertices differ.
graphModel :: Graph -> Model
graphModel g =
  Model
    { modelDomains =
        IntMap.fromList
          [(v, Domain (IntSet.fromList [1 .. graphK g])) | v <- [0 .. graphVertexCount g - 1]]
    , modelConstraints = [NotEqual u v | (u, v) <- graphEdges g]
    }
