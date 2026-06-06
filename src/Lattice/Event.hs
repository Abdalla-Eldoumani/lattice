{-# LANGUAGE OverloadedStrings #-}

{- | The event protocol (EVENT-01/02): the 'Event' ADT the engine emits as it reasons, the 'Emit'
callback that carries events out of the hot loop, and the versioned, tagged JSON wire form the front
end consumes. The wire form is one object with a version field @v@ and a tag @t@; payloads speak
puzzle coordinates (cell indices), never internal solver ids. Fast mode passes 'noEmit', a callback
the compiler deletes, so instrumenting the loop costs nothing when events are not wanted.
-}
module Lattice.Event (
  Event (..),
  Emit,
  noEmit,
  protocolVersion,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Lattice.Core.Types (Level, Value, Var)

-- | The protocol version, emitted as @v@ on every event so the front end can reject a mismatch.
protocolVersion :: Int
protocolVersion = 1

{- | A server-to-client event. The CP engine emits Decision/Propagate/Conflict/Backtrack/Solution/
Unsat; 'Stats' carries the running counters. 'Learned' and 'Restart' are the two SAT-specific
additions: a learned clause (its literals in puzzle/variable coordinates) and a restart firing. They
are additive — the protocol stays at v1 and the front end derives the @learnedClauses@/@restarts@
counters by tallying these events, so 'Stats' keeps its existing four-counter arity rather than
widening.
-}
data Event
  = Decision Var Value Level
  | Propagate Var Value
  | Conflict Var
  | Backtrack Level
  | -- | A learned clause from 1UIP analysis, as literals in puzzle/variable coordinates.
    Learned [Int]
  | -- | A restart fired: the trail unwound to level 0, learned clauses and activities kept.
    Restart
  | Solution [(Var, Value)]
  | Unsat
  | Stats Int Int Int Int
  deriving (Eq, Show)

{- | How the hot loop talks to the outside world, if at all. Generic over the monad: trace mode
supplies a callback that streams events; fast mode supplies 'noEmit'.
-}
type Emit m = Event -> m ()

{- | The fast-mode sink: do nothing. With @-O2@ and an inlined loop the dead callback and the
'Event' construction feeding it are optimized away, so fast mode pays no instrumentation tax.
-}
noEmit :: (Applicative m) => Emit m
noEmit _ = pure ()

-- | Build the tagged, versioned wire object shared by every event encoding.
tagged :: String -> [Pair] -> Aeson.Value
tagged t fields = object (("v" .= protocolVersion) : ("t" .= t) : fields)

instance ToJSON Event where
  toJSON (Decision v x l) = tagged "decision" ["cell" .= v, "value" .= x, "level" .= l]
  toJSON (Propagate c x) = tagged "propagate" ["cell" .= c, "removed" .= x]
  toJSON (Conflict c) = tagged "conflict" ["cell" .= c]
  toJSON (Backtrack l) = tagged "backtrack" ["level" .= l]
  toJSON (Learned ls) = tagged "learn" ["clause" .= ls]
  toJSON Restart = tagged "restart" []
  toJSON (Solution a) = tagged "solution" ["assignment" .= a]
  toJSON Unsat = tagged "unsat" []
  toJSON (Stats d p b c) =
    tagged "stats" ["decisions" .= d, "propagations" .= p, "backtracks" .= b, "conflicts" .= c]

instance FromJSON Event where
  parseJSON = withObject "event" $ \o -> do
    t <- o .: "t"
    case (t :: String) of
      "decision" -> Decision <$> o .: "cell" <*> o .: "value" <*> o .: "level"
      "propagate" -> Propagate <$> o .: "cell" <*> o .: "removed"
      "conflict" -> Conflict <$> o .: "cell"
      "backtrack" -> Backtrack <$> o .: "level"
      "learn" -> Learned <$> o .: "clause"
      "restart" -> pure Restart
      "solution" -> Solution <$> o .: "assignment"
      "unsat" -> pure Unsat
      "stats" ->
        Stats <$> o .: "decisions" <*> o .: "propagations" <*> o .: "backtracks" <*> o .: "conflicts"
      _ -> fail ("unknown event tag: " <> t)
