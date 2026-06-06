{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The streaming visualizer server (SERVER-01/02). Scotty serves the front end on 127.0.0.1:8080,
and a single WebSocket carries the bidirectional protocol: the client sends 'Control' messages, the
server streams 'Lattice.Event.Event's. The connection runs in single-step mode — each emitted event
blocks on a gate until the client releases it, so a solve animates at human pace. 'Step' releases one
event; 'Play' releases events repeatedly at a speed; 'Pause' stops releasing.
-}
module Main (main) where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.STM (TMVar, atomically, newEmptyTMVarIO, takeTMVar, tryPutTMVar)
import Control.Exception (handle)
import Control.Monad (forever, void, when)
import Data.Aeson (eitherDecodeStrict, encode)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Lattice (
  graphModel,
  nonogramModel,
  parseGraph,
  parseGrid,
  parseNonogram,
  queensModel,
  toModel,
 )
import Lattice.CP.Solver (solveTrace)
import Lattice.Core.Types (Model)
import Lattice.Event (Emit)
import Lattice.Protocol (Control (..))
import Network.Wai.Handler.Warp (run)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets qualified as WS
import Text.Read (readMaybe)
import Web.Scotty (ScottyM, get, html, scottyApp)

-- | Loopback port; WSL2 forwards localhost to the host browser.
port :: Int
port = 8080

main :: IO ()
main = do
  app <- scottyApp httpRoutes
  putStrLn ("lattice-server listening on http://127.0.0.1:" <> show port)
  run port (websocketsOr WS.defaultConnectionOptions wsApp app)

{- | HTTP routes. Serves the built front end once it exists; until then a placeholder confirms the
server is up and points at the WebSocket.
-}
httpRoutes :: ScottyM ()
httpRoutes =
  get "/" $
    html
      "<!doctype html><html><head><meta charset=utf-8><title>lattice</title></head>\
      \<body><p>lattice visualizer server is running. The browser front end connects over a \
      \WebSocket to this origin.</p></body></html>"

{- | The per-connection mutable state. The two 'ThreadId' refs let a new @Start@/@Play@ supersede
the in-flight one rather than racing it: without them, two @Play@ messages start two 'playLoop's that
both release the same gate (events drain at double the speed), and a second @Start@ leaves the old
solve thread blocked on the gate so two solves interleave their events onto one socket.
-}
data Session = Session
  { sessConn :: WS.Connection
  -- ^ the socket the events stream to.
  , sessGate :: TMVar ()
  -- ^ the step gate each emitted event blocks on until released.
  , sessPlaying :: IORef Bool
  -- ^ whether playback is releasing the gate on a timer.
  , sessPlayLoop :: IORef (Maybe ThreadId)
  -- ^ the live 'playLoop' thread, if any, so a new @Play@ supersedes it.
  , sessSolve :: IORef (Maybe ThreadId)
  -- ^ the live 'solveTrace' thread, if any, so a new @Start@ supersedes it.
  }

{- | One WebSocket connection: a step gate the emit blocks on, a flag the play loop watches, the live
play-loop and solve thread ids, and a reader loop that dispatches client control messages.
-}
wsApp :: WS.ServerApp
wsApp pending = do
  conn <- WS.acceptRequest pending
  gate <- newEmptyTMVarIO
  playing <- newIORef False
  playLoopId <- newIORef Nothing
  solveId <- newIORef Nothing
  let sess = Session conn gate playing playLoopId solveId
  handle (\(_ :: WS.ConnectionException) -> pure ()) $
    forever $ do
      raw <- WS.receiveData conn
      case eitherDecodeStrict raw of
        Left _ -> pure ()
        Right ctrl -> dispatch sess ctrl

-- | Act on one control message.
dispatch :: Session -> Control -> IO ()
dispatch sess = go
 where
  conn = sessConn sess
  gate = sessGate sess
  playing = sessPlaying sess
  go (Start kind puzzle _mode) = case buildModel kind puzzle of
    Left _ -> pure ()
    Right m -> do
      -- Stop any in-flight playback and solve before forking a new solve, so the old solve thread
      -- cannot keep draining the gate and interleaving its events with the new stream.
      atomicWriteIORef playing False
      stopThread (sessPlayLoop sess)
      stopThread (sessSolve sess)
      tid <- forkIO (void (solveTrace (gatedEmit conn gate) m))
      writeIORef (sessSolve sess) (Just tid)
  go Step = release gate
  go (Play speed) =
    -- Check-and-set: only the transition from not-playing to playing forks a loop, so a second
    -- @Play@ (a speed change or a double-click) replaces the loop instead of running two at once.
    do
      stopThread (sessPlayLoop sess)
      atomicWriteIORef playing True
      tid <- forkIO (playLoop gate playing (delayOf speed))
      writeIORef (sessPlayLoop sess) (Just tid)
  go Pause = stopPlayback
  go Restart = do
    -- Restart stops both playback and the running solve so the next @Start@ begins from a clean
    -- gate with no thread left blocked on a stale permit.
    stopPlayback
    stopThread (sessSolve sess)
  stopPlayback = do
    atomicWriteIORef playing False
    stopThread (sessPlayLoop sess)

{- | Kill the thread the ref points at (if any) and clear the ref, atomically swapping the ref to
'Nothing' so two concurrent stops do not both kill — only the one that reads the live id does.
-}
stopThread :: IORef (Maybe ThreadId) -> IO ()
stopThread ref = do
  prev <- atomicModifyIORef' ref clearAndTake
  mapM_ killThread prev
 where
  -- swap the ref to Nothing and hand back whatever it held, so only this caller sees the live id.
  clearAndTake old = (Nothing, old)

{- | Route a @start@ definition to the encoder named by its @kind@. Every arm is total: a malformed
definition is a 'Left' the 'Start' branch ignores, never a crash on the solve thread. The queens @N@
is parsed with a bounded validator ('readMaybe' plus a @4..20@ guard), never a partial @read@, so
untrusted text cannot diverge. @nonogram@ parses the cell-boolean clue JSON ('parseNonogram' is total).
-}
buildModel :: Text -> Text -> Either String Model
buildModel kind puzzle = case kind of
  "sudoku" -> either (Left . show) (Right . toModel) (parseGrid puzzle)
  "graph" -> graphModel <$> parseGraph puzzle
  "queens" -> case readMaybe (T.unpack (T.strip puzzle)) of
    Just n | n >= 4 && n <= 20 -> Right (queensModel n)
    _ -> Left "queens N must be an integer in 4..20"
  "nonogram" -> nonogramModel <$> parseNonogram puzzle
  _ -> Left ("unknown puzzle kind: " <> T.unpack kind)

-- | Release the step gate (permit one event); a no-op if a permit is already pending.
release :: TMVar () -> IO ()
release gate = void (atomically (tryPutTMVar gate ()))

-- | Release the gate every @d@ microseconds while playback stays active.
playLoop :: TMVar () -> IORef Bool -> Int -> IO ()
playLoop gate playing d = loop
 where
  loop = do
    active <- readIORef playing
    when active (release gate >> threadDelay d >> loop)

{- | Microseconds between steps for a play speed (events per second). The client-supplied 'Double'
is untrusted, so the speed is first clamped to a documented @[0.1, 1000]@ band: a non-positive or
NaN speed coerces to the @0.1@ floor (a slow crawl, not a divide-by-zero or a negative delay), and a
huge speed coerces to @1000@ ev/s. The resulting delay is then bounded to @[1000, 10_000_000]@ us
(1 ms .. 10 s) so 'threadDelay' never sees a pathological 'round' of an enormous 'Double'.
-}
delayOf :: Double -> Int
delayOf speed = max 1000 (min 10000000 (round (1000000 / clamped)))
 where
  -- @max@ first so a NaN speed (NaN fails every comparison) falls through to the 0.1 floor.
  clamped = min 1000 (max 0.1 speed)

-- | The trace emit: send the event as JSON, then block until the gate is released (one step).
gatedEmit :: WS.Connection -> TMVar () -> Emit IO
gatedEmit conn gate ev = do
  WS.sendTextData conn (encode ev)
  atomically (takeTMVar gate)
