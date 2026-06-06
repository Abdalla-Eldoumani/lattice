{-# LANGUAGE OverloadedStrings #-}

{- | The client-to-server control protocol — the complement of the server-to-client events in
"Lattice.Event". Same versioned, tagged JSON shape (a @v@ version and a @t@ tag). 'Start' carries the
puzzle kind, the puzzle definition to solve, and the run mode; 'Step' / 'Play' / 'Pause' / 'Restart'
drive the trace stream.
-}
module Lattice.Protocol (
  Control (..),
) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import Lattice.Event (protocolVersion)

{- | A control message from the client. 'Start' begins a solve of the given puzzle definition in the
given mode (@"trace"@ or @"fast"@); its first field is the puzzle @kind@ (@"sudoku"@, @"graph"@,
@"queens"@, @"nonogram"@), which the server routes to the matching encoder. The rest drive
single-stepping and playback of a trace.
-}
data Control
  = -- | @Start kind puzzle mode@
    Start Text Text Text
  | Step
  | Play Double
  | Pause
  | Restart
  deriving (Eq, Show)

-- | Build the tagged, versioned wire object shared by every control encoding.
tagged :: String -> [Pair] -> Aeson.Value
tagged t fields = object (("v" .= protocolVersion) : ("t" .= t) : fields)

instance ToJSON Control where
  toJSON (Start kind puzzle mode) =
    tagged "start" ["kind" .= kind, "puzzle" .= puzzle, "mode" .= mode]
  toJSON Step = tagged "step" []
  toJSON (Play speed) = tagged "play" ["speed" .= speed]
  toJSON Pause = tagged "pause" []
  toJSON Restart = tagged "restart" []

instance FromJSON Control where
  parseJSON = withObject "control" $ \o -> do
    t <- o .: "t"
    case (t :: String) of
      -- @kind@ defaults to "sudoku" so an old kindless start (the v1 contract before this field)
      -- still decodes; the field is additive and the protocol stays at v1.
      "start" -> Start <$> o .:? "kind" .!= "sudoku" <*> o .: "puzzle" <*> o .: "mode"
      "step" -> pure Step
      "play" -> Play <$> o .: "speed"
      "pause" -> pure Pause
      "restart" -> pure Restart
      _ -> fail ("unknown control tag: " <> t)
