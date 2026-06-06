{-# LANGUAGE OverloadedStrings #-}

{- | The client-to-server control protocol — the complement of the server-to-client events in
"Lattice.Event". Same versioned, tagged JSON shape (a @v@ version and a @t@ tag). 'Start' carries the
puzzle to solve and the run mode; 'Step' / 'Play' / 'Pause' / 'Restart' drive the trace stream.
-}
module Lattice.Protocol (
  Control (..),
) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import Lattice.Event (protocolVersion)

{- | A control message from the client. 'Start' begins a solve of the given puzzle text in the given
mode (@"trace"@ or @"fast"@); the rest drive single-stepping and playback of a trace.
-}
data Control
  = Start Text Text
  | Step
  | Play Double
  | Pause
  | Restart
  deriving (Eq, Show)

-- | Build the tagged, versioned wire object shared by every control encoding.
tagged :: String -> [Pair] -> Aeson.Value
tagged t fields = object (("v" .= protocolVersion) : ("t" .= t) : fields)

instance ToJSON Control where
  toJSON (Start puzzle mode) = tagged "start" ["puzzle" .= puzzle, "mode" .= mode]
  toJSON Step = tagged "step" []
  toJSON (Play speed) = tagged "play" ["speed" .= speed]
  toJSON Pause = tagged "pause" []
  toJSON Restart = tagged "restart" []

instance FromJSON Control where
  parseJSON = withObject "control" $ \o -> do
    t <- o .: "t"
    case (t :: String) of
      "start" -> Start <$> o .: "puzzle" <*> o .: "mode"
      "step" -> pure Step
      "play" -> Play <$> o .: "speed"
      "pause" -> pure Pause
      "restart" -> pure Restart
      _ -> fail ("unknown control tag: " <> t)
