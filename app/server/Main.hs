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
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM (TMVar, atomically, newEmptyTMVarIO, takeTMVar, tryPutTMVar)
import Control.Exception (handle)
import Control.Monad (forever, void, when)
import Data.Aeson (Value (Object), eitherDecodeStrict, encode, toJSON)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Lattice (
  CNF,
  graphCNF,
  graphModel,
  nonogramModel,
  parseDimacs,
  parseGraph,
  parseGrid,
  parseNonogram,
  queensModel,
  toModel,
 )
import Lattice.CP.Solver (solveTrace)
import Lattice.Core.Types (Model)
import Lattice.Event (Emit, Event)
import Lattice.Protocol (Control (..))
import Lattice.SAT.Solver (solveSatTrace)
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

{- | The per-connection mutable state. The 'ThreadId' refs let a new @Start@/@Play@ supersede the
in-flight one rather than racing it: without them, two @Play@ messages start two 'playLoop's that both
release the same gate (events drain at double the speed), and a second @Start@ leaves the old solve
thread blocked on the gate so two solves interleave their events onto one socket. The race forks TWO
solves (CP and SAT) over one socket, so it needs a second solve ref ('sessSolveB') tracked exactly like
'sessSolve' — a new @Start@/@Restart@ supersedes both, never leaving the second thread blocked on the gate.

Two race-correctness fields (CR-01). 'sessWrite' is a per-connection write lock every
'WS.sendTextData' goes through: the @websockets@ library does NOT serialize concurrent sends on one
'WS.Connection', so the race's two solve threads could otherwise interleave their frame bytes and
corrupt the stream. 'sessGateB' is the SECOND engine's step gate: in a race each engine blocks on its
OWN gate ('sessGate' for CP, 'sessGateB' for SAT) and the play loop releases BOTH per tick, so a tick
advances both engines in step — sharing one gate halved the pacing (one release unblocked only one of
the two waiters). Single-engine solves use 'sessGate' alone and never touch 'sessGateB'.
-}
data Session = Session
  { sessConn :: WS.Connection
  -- ^ the socket the events stream to.
  , sessWrite :: MVar ()
  -- ^ the write lock serializing every 'WS.sendTextData' so the race's two threads never interleave a frame.
  , sessGate :: TMVar ()
  -- ^ the step gate each emitted event blocks on until released (CP, or the single engine).
  , sessGateB :: TMVar ()
  -- ^ the SECOND engine's step gate in a race (the SAT side); unused by a single-engine solve.
  , sessPlaying :: IORef Bool
  -- ^ whether playback is releasing the gate on a timer.
  , sessPlayLoop :: IORef (Maybe ThreadId)
  -- ^ the live 'playLoop' thread, if any, so a new @Play@ supersedes it.
  , sessSolve :: IORef (Maybe ThreadId)
  -- ^ the live primary solve thread (CP, or SAT in single-engine mode), so a new @Start@ supersedes it.
  , sessSolveB :: IORef (Maybe ThreadId)
  -- ^ the live second solve thread in a race (the SAT side); 'Nothing' for a single-engine solve.
  }

{- | One WebSocket connection: a step gate the emit blocks on, a flag the play loop watches, the live
play-loop and solve thread ids, and a reader loop that dispatches client control messages.
-}
wsApp :: WS.ServerApp
wsApp pending = do
  conn <- WS.acceptRequest pending
  writeLock <- newMVar ()
  gate <- newEmptyTMVarIO
  gateB <- newEmptyTMVarIO
  playing <- newIORef False
  playLoopId <- newIORef Nothing
  solveId <- newIORef Nothing
  solveIdB <- newIORef Nothing
  let sess = Session conn writeLock gate gateB playing playLoopId solveId solveIdB
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
  lock = sessWrite sess
  gate = sessGate sess
  gateB = sessGateB sess
  playing = sessPlaying sess
  -- Route the start on the @engine@ field. @"sat"@ builds a CNF (the dimacs arm or the graph->CNF
  -- dual encoder) and runs the CDCL trace; @"cp"@ (the default for an unknown engine) runs the CP
  -- trace; @"race"@ runs BOTH over this one socket on the same dual-encoded instance, each emit tagged
  -- with its engine so the client can split the interleaved streams into two panels. The single-engine
  -- paths stamp the engine too so the wire is uniform. Every build is a total 'Either', so a malformed
  -- puzzle is a @Left@ the branch ignores (@Left _ -> pure ()@) and never crashes a forked solve thread.
  go (Start kind puzzle _mode engine) = case normalizeEngine engine of
    "sat" -> case buildCNF kind puzzle of
      Left _ -> pure ()
      Right cnf -> startSolve (\emit -> void (solveSatTrace emit cnf)) "sat"
    -- The race forks two trace solves on the SAME instance (the CP model and its dual CNF), each
    -- engine-tagged, both tracked for supersession. It runs in PLAY mode, not single-step. Each engine
    -- now blocks on its OWN gate (CP on 'sessGate', SAT on 'sessGateB') and the play loop releases BOTH
    -- per tick, so a tick advances both engines in step (CR-01: one shared gate released once unblocked
    -- only ONE waiter, halving the pacing). Every send goes through the 'sessWrite' lock so the two
    -- threads never interleave a frame. Precise single-stepping stays a single-engine feature; the race
    -- 'Step' releases both gates so it at least advances both rather than an arbitrary one.
    "race" -> case (buildModel kind puzzle, buildCNF kind puzzle) of
      (Right m, Right cnf) -> do
        stopAll
        cpTid <- forkIO (void (solveTrace (taggedEmit lock conn gate "cp") m))
        satTid <- forkIO (void (solveSatTrace (taggedEmit lock conn gateB "sat") cnf))
        writeIORef (sessSolve sess) (Just cpTid)
        writeIORef (sessSolveB sess) (Just satTid)
      -- A Left from either encoder (a kind with no dual encoding, or a malformed definition) ignores
      -- the race the same way the single-engine arms ignore a bad build — never a crash.
      _ -> pure ()
    -- The default arm covers "cp" and any unknown engine value (validated to a cp fallback, never a
    -- crash) — the kind/queens-N bounded-validator posture applied to the engine field.
    _ -> case buildModel kind puzzle of
      Left _ -> pure ()
      Right m -> startSolve (\emit -> void (solveTrace emit m)) "cp"
   where
    -- Fork a single-engine solve: stop everything in flight first (so no old thread keeps draining the
    -- gate), then fork the engine-tagged solve and track it as the primary thread for supersession. It
    -- uses 'sessGate' only ('sessGateB' is the race's second gate) and the write lock like every send.
    startSolve runSolve eng = do
      stopAll
      tid <- forkIO (runSolve (taggedEmit lock conn gate eng))
      writeIORef (sessSolve sess) (Just tid)
    -- Stop in-flight playback and BOTH solve threads. The second ref matters for the race: a new start
    -- (single-engine or another race) must supersede both, never leave the SAT thread blocked on the gate.
    stopAll = do
      atomicWriteIORef playing False
      stopThread (sessPlayLoop sess)
      stopThread (sessSolve sess)
      stopThread (sessSolveB sess)
  -- One step. In a race (the SAT side is live) release BOTH gates so a single step advances both
  -- engines, not an arbitrary STM winner; otherwise release only the single engine's gate, leaving the
  -- single-engine step semantics exactly as before.
  go Step = releaseStep
  go (Play speed) =
    -- Check-and-set: only the transition from not-playing to playing forks a loop, so a second
    -- @Play@ (a speed change or a double-click) replaces the loop instead of running two at once. The
    -- loop releases via 'releaseStep', so in a race each tick advances both engines together.
    do
      stopThread (sessPlayLoop sess)
      atomicWriteIORef playing True
      tid <- forkIO (playLoop releaseStep playing (delayOf speed))
      writeIORef (sessPlayLoop sess) (Just tid)
  go Pause = stopPlayback
  go Restart = do
    -- Restart stops playback and BOTH solve threads (the CP and SAT sides of a race included) so the
    -- next @Start@ begins from a clean gate with no thread left blocked on a stale permit.
    stopPlayback
    stopThread (sessSolve sess)
    stopThread (sessSolveB sess)
  stopPlayback = do
    atomicWriteIORef playing False
    stopThread (sessPlayLoop sess)
  -- Release one step. A race (the SAT side is live in 'sessSolveB') releases BOTH gates so the tick
  -- advances both engines; a single-engine solve releases only 'sessGate', unchanged from before.
  releaseStep = do
    racing <- readIORef (sessSolveB sess)
    release gate
    when (isJust racing) (release gateB)

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

{- | Route a @start@ definition to a 'CNF' for the SAT engine. Like 'buildModel', every arm is a total
'Either', so a malformed definition is a 'Left' the 'Start' branch ignores and never a crash on the
forked solve thread. The @dimacs@ arm carries raw CNF text and is parsed by the total 'parseDimacs'
(the Phase 4 partial-function-on-untrusted-input bug class is what this guards) — 'parseDimacs' already
bounds @nVars@/@nClauses@ and rejects an out-of-range literal magnitude, so a malformed CNF is a @Left@.
The @graph@ arm reuses the dual encoder 'graphCNF' over the same 'parseGraph' the CP @graph@ model uses,
so SAT and CP solve the genuinely same instance.
-}
buildCNF :: Text -> Text -> Either String CNF
buildCNF kind puzzle = case kind of
  "dimacs" -> parseDimacs puzzle
  "graph" -> graphCNF <$> parseGraph puzzle
  _ -> Left ("kind " <> T.unpack kind <> " has no CNF encoding for the SAT engine")

{- | Validate the client-supplied @engine@ value to the known set @{cp,sat,race}@, defaulting an
unknown value to @"cp"@. Untrusted text must never route to a partial branch or crash; an unrecognized
engine falls back to CP exactly as the queens @N@ bounds to @4..20@ — the safe-default boundary posture.
-}
normalizeEngine :: Text -> Text
normalizeEngine engine
  | engine `elem` ["cp", "sat", "race"] = engine
  | otherwise = "cp"

-- | Release the step gate (permit one event); a no-op if a permit is already pending.
release :: TMVar () -> IO ()
release gate = void (atomically (tryPutTMVar gate ()))

{- | Run the @releaseOne@ step action every @d@ microseconds while playback stays active. The action is
'releaseStep', which releases one gate (single engine) or both (a race), so the play cadence is one
step per tick for the single engine and one synchronized step for both race engines.
-}
playLoop :: IO () -> IORef Bool -> Int -> IO ()
playLoop releaseOne playing d = loop
 where
  loop = do
    active <- readIORef playing
    when active (releaseOne >> threadDelay d >> loop)

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

{- | The engine-tagged trace emit: stamp the @engine@ field (@"cp"@/@"sat"@) onto the event's JSON
object, send it UNDER THE WRITE LOCK, then block until the gate is released (one step). The client reads
this tag to split a race's interleaved CP and SAT streams into two panels; the single-engine paths stamp
it too so the wire is uniform (the protocol declares @engine?@ optional on every event, additive and
still v1). The event always encodes to a JSON object, so the @Object@ case always matches; a non-object
encoding (impossible for an 'Event') is sent unstamped rather than dropped.

The 'withMVar' lock (CR-01) serializes the send: @websockets@ does not synchronize concurrent sends on
one 'WS.Connection', so the race's two solve threads could interleave their frame bytes mid-frame and
corrupt the stream without it. The lock wraps ONLY the send, not the gate wait, so a thread paused on
its step gate does not hold the socket and block the other engine's sends. Each engine waits on its own
@gate@ ('sessGate' for CP, 'sessGateB' for SAT), so a play tick that releases both advances both.
-}
taggedEmit :: MVar () -> WS.Connection -> TMVar () -> Text -> Emit IO
taggedEmit lock conn gate engine ev = do
  withMVar lock (\_ -> WS.sendTextData conn (encode (stampEngine engine ev)))
  atomically (takeTMVar gate)

{- | Insert @"engine": <engine>@ into an event's JSON object. Re-encoding the event to a 'Value' and
inserting the key keeps the tagging uniform across every event constructor (no per-constructor wiring),
the same additive discipline the protocol's optional @engine?@ tag declares.
-}
stampEngine :: Text -> Event -> Value
stampEngine engine ev = case toJSON ev of
  Object o -> Object (KeyMap.insert (Key.fromString "engine") (toJSON engine) o)
  other -> other
