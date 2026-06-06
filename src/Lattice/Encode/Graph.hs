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

-- | Parse a graph-coloring instance from its JSON text.
parseGraph :: Text -> Either String Graph
parseGraph = eitherDecodeStrict . encodeUtf8

-- | Build the CSP: each vertex takes a color in @{1..k}@; adjacent vertices differ.
graphModel :: Graph -> Model
graphModel g =
  Model
    { modelDomains =
        IntMap.fromList
          [(v, Domain (IntSet.fromList [1 .. graphK g])) | v <- [0 .. graphVertexCount g - 1]]
    , modelConstraints = [NotEqual u v | (u, v) <- graphEdges g]
    }
