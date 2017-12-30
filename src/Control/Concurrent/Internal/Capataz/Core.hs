{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RecordWildCards   #-}
module Control.Concurrent.Internal.Capataz.Core where

import Protolude

import Control.Concurrent.Async      (asyncWithUnmask)
import Control.Concurrent.MVar       (newEmptyMVar, takeMVar)
import Control.Concurrent.STM        (atomically)
import Control.Concurrent.STM.TQueue (newTQueueIO, readTQueue, writeTQueue)
import Control.Concurrent.STM.TVar   (newTVarIO)
import Control.Teardown              (newTeardown)
import Data.IORef                    (newIORef)
import Data.Time.Clock               (getCurrentTime)

import qualified Data.HashMap.Strict as HashMap
import qualified Data.UUID.V4        as UUID (nextRandom)

import qualified Control.Concurrent.Internal.Capataz.Worker   as Worker
import qualified Control.Concurrent.Internal.Capataz.Restart as Restart

import Control.Concurrent.Internal.Capataz.Types
import Control.Concurrent.Internal.Capataz.Util
    ( appendWorkerToMap
    , workerOptionsToSpec
    , fetchWorker
    , readCapatazStatus
    , readCapatazStatusSTM
    , resetWorkerMap
    , sendSyncControlMsg
    , capatazToEnv
    , writeCapatazStatus
    )

--------------------------------------------------------------------------------

haltCapataz :: CapatazEnv -> IO ()
haltCapataz env = do
  writeCapatazStatus   env                   Halting
  Worker.terminateWorkers "capataz shutdown" env
  resetWorkerMap           env                   (const HashMap.empty)
  writeCapatazStatus   env                   Halted

handleMonitorEvent :: CapatazEnv -> MonitorEvent -> IO Bool
handleMonitorEvent env monitorEv = do
  case monitorEv of
    WorkerForcedRestart{} ->
      -- We do nothing, as restart is being handled on restartWorkers
      -- sub-routine
      return ()

    WorkerCompleted { workerId, monitorEventTime } ->
      Restart.handleWorkerCompleted env workerId monitorEventTime

    WorkerFailed { workerId, workerError, workerRestartCount } ->
      Restart.handleWorkerFailed env workerId workerError workerRestartCount

    WorkerTerminated { workerId, workerRestartCount, workerTerminationReason } ->
      Restart.handleWorkerTerminated env
                                    workerId
                                    workerTerminationReason
                                    workerRestartCount


  return True

handleControlAction :: CapatazEnv -> ControlAction -> IO Bool
handleControlAction env controlAction = case controlAction of
  ForkWorker { workerSpec, returnWorkerId } -> do
    worker@Worker { workerId } <- Worker.forkWorker env workerSpec Nothing
    appendWorkerToMap env worker
    returnWorkerId workerId
    return True

  TerminateWorker { terminationReason, workerId, notifyWorkerTermination } -> do
    mWorker <- fetchWorker env workerId
    case mWorker of
      Nothing    -> return True
      Just worker -> do
        Worker.terminateWorker terminationReason env worker
        -- removeWorkerFromMap env workerId
        notifyWorkerTermination
        return True

  TerminateCapataz { notifyCapatazTermination } -> do
    haltCapataz env
    notifyCapatazTermination
    return False

handleCapatazMessage :: CapatazEnv -> CapatazMessage -> IO Bool
handleCapatazMessage env message = case message of
  ControlAction controlAction -> handleControlAction env controlAction
  MonitorEvent  monitorEvent  -> handleMonitorEvent env monitorEvent

handleCapatazException :: CapatazEnv -> SomeException -> IO ()
handleCapatazException env@CapatazEnv { capatazId, capatazName, notifyEvent } capatazError
  = do
    eventTime <- getCurrentTime
    notifyEvent CapatazFailed
      { capatazId
      , capatazName
      , capatazError
      , eventTime
      }
    haltCapataz env
    throwIO capatazError

runCapatazLoop :: (forall b . IO b -> IO b) -> CapatazEnv -> IO ()
runCapatazLoop unmask env@CapatazEnv { capatazId, capatazName, capatazStatusVar, capatazQueue, notifyEvent }
  = do
    loopResult <-
      unmask
      $   try
      $   atomically
      $   (,)
      <$> readCapatazStatusSTM capatazStatusVar
      <*> readTQueue capatazQueue

    case loopResult of
      Left  capatazError   -> handleCapatazException env capatazError

      Right (status, message) -> case status of
        Initializing -> do
          eventTime <- getCurrentTime
          notifyEvent InvalidCapatazStatusReached
            { capatazId
            , capatazName
            , eventTime
            }
          runCapatazLoop unmask env

        Running -> do
          eContinueLoop <- try $ unmask $ handleCapatazMessage env message
          case eContinueLoop of
            Left capatazError ->
              handleCapatazException env capatazError

            Right continueLoop
              | continueLoop -> runCapatazLoop unmask env
              | otherwise -> do
                eventTime <- getCurrentTime
                notifyEvent CapatazTerminated
                  { capatazId
                  , capatazName
                  , eventTime
                  }

        Halting ->
          -- Discard messages when halting
          return ()

        Halted -> panic "TODO: Pending halted state"

buildCapatazRuntime :: CapatazOptions -> IO CapatazRuntime
buildCapatazRuntime capatazOptions = do
  capatazId        <- UUID.nextRandom
  capatazQueue     <- newTQueueIO
  capatazStatusVar <- newTVarIO Initializing
  capatazWorkerMap  <- newIORef HashMap.empty
  return CapatazRuntime {..}

forkCapataz :: CapatazOptions -> IO Capataz
forkCapataz capatazOptions@CapatazOptions { capatazName, capatazWorkerSpecList, notifyEvent }
  = do
    capatazRuntime <- buildCapatazRuntime capatazOptions

    let capatazEnv@CapatazEnv { capatazId } =
          capatazToEnv capatazRuntime

    capatazAsync <- asyncWithUnmask
      $ \unmask -> runCapatazLoop unmask capatazEnv

    forM_
      capatazWorkerSpecList
      ( \workerSpec -> do
        worker <- Worker.forkWorker capatazEnv workerSpec Nothing
        appendWorkerToMap capatazEnv worker
      )

    writeCapatazStatus capatazEnv Running

    capatazTeardown <- newTeardown
      ("capataz[" <> capatazName <> "]")
      ( do
        status <- readCapatazStatus capatazEnv
        case status of
          Halted  -> return ()
          Halting -> return ()
          _       -> do
            eventTime <- getCurrentTime
            notifyEvent CapatazShutdownInvoked
              { capatazId
              , capatazName
              , eventTime
              }
            sendSyncControlMsg capatazEnv TerminateCapataz
      )

    return Capataz {..}

forkWorker :: WorkerOptions -> IO () -> Capataz -> IO WorkerId
forkWorker workerOptions workerAction Capataz { capatazEnv } = do
  let workerSpec = workerOptionsToSpec workerOptions workerAction
      CapatazEnv { capatazQueue } = capatazEnv

  workerIdVar <- newEmptyMVar
  atomically $ writeTQueue
    capatazQueue
    (ControlAction ForkWorker {workerSpec , returnWorkerId = putMVar workerIdVar})
  takeMVar workerIdVar

terminateWorker :: Text -> WorkerId -> Capataz -> IO ()
terminateWorker terminationReason workerId Capataz { capatazEnv } =
  sendSyncControlMsg
    capatazEnv
    ( \notifyWorkerTermination ->
      TerminateWorker {terminationReason , workerId , notifyWorkerTermination }
    )
