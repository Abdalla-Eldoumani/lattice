{- | The graph-coloring CNF dual encoder. 'graphCNF' turns a graph-coloring instance into a 'CNF' the
SAT engine and the @2^n@ oracle both consume, so CP (via 'Lattice.Encode.Graph.graphModel'), SAT, and
brute force solve the genuinely same problem — the foundation of the three-way differential (SAT-05)
and the solver race. This module OWNS the @var <-> (vertex, color)@ map, the same discipline
'graphModel' has over its @vertex -> CSP variable@ map; the SAT engine never sees vertex/color
coordinates, only the flat boolean variables this encoder hands it.

The encoding is the textbook direct (at-least-one + at-most-one) coloring CNF:

  * one boolean @x_{v,c}@ per (vertex, color) pair, color @c@ in @0..k-1@, at CNF variable @v*k + c@;
  * AT-LEAST-ONE per vertex: the clause @(x_{v,0} v ... v x_{v,k-1})@ — every vertex gets a color;
  * AT-MOST-ONE per vertex (pairwise): @(not x_{v,c} v not x_{v,c'})@ for every @c < c'@ — at most one
    color per vertex (so together with at-least-one, exactly one);
  * EDGE per edge @(u,v)@ and color @c@: @(not x_{u,c} v not x_{v,c})@ — adjacent vertices differ.

'cnfColoring' is the inverse: it reads a satisfying model (the list of true literals) back into a
vertex -> color 'Assignment' in the SAME @1..k@ color labels 'graphModel' uses, so a decoded SAT model
is directly comparable to a CP coloring. With the at-least-one/at-most-one clauses a satisfiable model
has exactly one colour true per vertex; the decode takes the first true colour defensively.
-}
module Lattice.SAT.Encode (
  graphCNF,
  cnfColoring,
  colorVar,
) where

import Data.IntMap.Strict qualified as IntMap
import Lattice.Core.Types (Assignment)
import Lattice.Encode.Graph (Graph (..))
import Lattice.SAT.Types (CNF (..), Lit, litPos, litVar, mkLit)

{- | The CNF variable for "vertex @v@ has color @c@" (@c@ in @0 .. k-1@): @v*k + c@. The encoder owns
this map; it is the only place the (vertex, color) pair becomes a flat boolean variable, mirroring how
'graphModel' owns the vertex -> CSP variable map.
-}
colorVar :: Int -> Int -> Int -> Int
colorVar k v c = v * k + c

{- | Dual-encode a graph-coloring instance to CNF. The variable count is @vertices * k@; the clauses are
the at-least-one (one per vertex), pairwise at-most-one (one per color pair per vertex), and edge (one
per color per edge) sets described in the module header. A total function: any 'Graph' (already bounds-
validated by 'Lattice.Encode.Graph.parseGraph') maps to a well-formed CNF whose every literal magnitude
is within the declared variable count.
-}
graphCNF :: Graph -> CNF
graphCNF g =
  CNF
    { cnfVars = n * k
    , cnfClauses = atLeastOne <> atMostOne <> edgeClauses
    }
 where
  n = graphVertexCount g
  k = graphK g
  -- A positive/negative literal for "vertex v has color c".
  pos v c = mkLit (colorVar k v c) True
  neg v c = mkLit (colorVar k v c) False
  -- At least one colour per vertex.
  atLeastOne = [[pos v c | c <- [0 .. k - 1]] | v <- [0 .. n - 1]]
  -- At most one colour per vertex (pairwise).
  atMostOne =
    [[neg v c, neg v c'] | v <- [0 .. n - 1], c <- [0 .. k - 1], c' <- [c + 1 .. k - 1]]
  -- Adjacent vertices never share a colour.
  edgeClauses =
    [[neg u c, neg v c] | (u, v) <- graphEdges g, c <- [0 .. k - 1]]

{- | Decode a satisfying SAT model (the list of true literals from 'Lattice.SAT.Solver.solveSat') into a
vertex -> color 'Assignment'. Colors are reported in the @1..k@ labels 'graphModel' uses (CNF color @c@
maps to @c+1@), so the result is directly comparable to a CP coloring. A vertex with no true color
variable in the model (only possible on a non-satisfying model) is simply absent from the assignment.
-}
cnfColoring :: Graph -> [Lit] -> Assignment
cnfColoring g model =
  IntMap.fromList
    [ (v, c + 1)
    | v <- [0 .. n - 1]
    , c <- take 1 [c' | c' <- [0 .. k - 1], colorVar k v c' `elem` trueVars]
    ]
 where
  n = graphVertexCount g
  k = graphK g
  -- The variables assigned true in the model (a positive literal on a variable).
  trueVars = [litVar l | l <- model, litPos l]
