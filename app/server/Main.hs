{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The streaming visualizer server (SERVER-01/02). Scotty serves the front end on 127.0.0.1:8080,
and a single WebSocket carries the bidirectional protocol: the client sends 'Control' messages, the
server streams 'Lattice.Event.Event's. The connection runs in single-step mode — each emitted event
blocks on a gate until the client releases it, so a solve animates at human pace. 'Step' releases one
event; 'Play' releases events repeatedly at a speed; 'Pause' stops releasing.
-}
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (TMVar, atomically, newEmptyTMVarIO, takeTMVar, tryPutTMVar)
import Control.Exception (handle)
import Control.Monad (forever, void, when)
import Data.Aeson (eitherDecodeStrict, encode)
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Lattice (parseGrid, toModel)
import Lattice.CP.Solver (solveTrace)
import Lattice.Event (Emit)
import Lattice.Protocol (Control (..))
import Network.Wai.Handler.Warp (run)
import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets qualified as WS
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

{- | One WebSocket connection: a step gate the emit blocks on, a flag the play loop watches, and a
reader loop that dispatches client control messages.
-}
wsApp :: WS.ServerApp
wsApp pending = do
  conn <- WS.acceptRequest pending
  gate <- newEmptyTMVarIO
  playing <- newIORef False
  handle (\(_ :: WS.ConnectionException) -> pure ()) $
    forever $ do
      raw <- WS.receiveData conn
      case eitherDecodeStrict raw of
        Left _ -> pure ()
        Right ctrl -> dispatch conn gate playing ctrl

-- | Act on one control message.
dispatch :: WS.Connection -> TMVar () -> IORef Bool -> Control -> IO ()
dispatch conn gate playing = go
 where
  go (Start puzzle _mode) = case parseGrid puzzle of
    Left _ -> pure ()
    Right g -> do
      atomicWriteIORef playing False
      void (forkIO (void (solveTrace (gatedEmit conn gate) (toModel g))))
  go Step = release gate
  go (Play speed) = do
    atomicWriteIORef playing True
    void (forkIO (playLoop gate playing (delayOf speed)))
  go Pause = atomicWriteIORef playing False
  go Restart = atomicWriteIORef playing False

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

-- | Microseconds between steps for a play speed (events per second), clamped to a sane range.
delayOf :: Double -> Int
delayOf speed = max 1000 (round (1000000 / max 0.1 speed))

-- | The trace emit: send the event as JSON, then block until the gate is released (one step).
gatedEmit :: WS.Connection -> TMVar () -> Emit IO
gatedEmit conn gate ev = do
  WS.sendTextData conn (encode ev)
  atomically (takeTMVar gate)
