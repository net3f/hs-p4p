{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}

module P4P.Sim.IO where

-- external, pure
import qualified Data.Map.Strict                as M
import qualified Data.Set                       as S

import           Control.Clock                  (Clock (..), Clocked (..))
import           Control.Monad                  (forever, join, void, when)
import           Control.Monad.Extra            (whenJust)
import           Control.Op
import           Data.Either                    (fromRight, lefts)
import           Data.Foldable                  (for_, toList)
import           Data.List                      (intercalate)
import           Data.List.NonEmpty             (NonEmpty, fromList)
import           Data.Maybe                     (fromMaybe)
import           Data.Schedule                  (Tick)
import           Data.Traversable               (for)
import           P4P.Proc                       (GMsg (..), GMsgI, GMsgO, PAddr,
                                                 Process (..), Protocol (..),
                                                 RuntimeI (..))
import           Safe                           (readNote)
import           Text.Read                      (readEither)

-- external, IO
import           Control.Clock.IO               (Intv (..), interval, newClock)
import           Control.Concurrent.Async       (async, cancel, link, link2,
                                                 wait)
import           Control.Concurrent.Async.Extra (foreverInterleave)
import           Control.Concurrent.STM         (atomically)
import           Control.Concurrent.STM.TBQueue (newTBQueueIO, readTBQueue,
                                                 writeTBQueue)
import           Control.Concurrent.STM.TVar    (modifyTVar', newTVarIO,
                                                 readTVarIO)
import           Crypto.Random.Entropy          (getEntropy)
import           Crypto.Random.Extra            (ScrubbedBytes)
import           Data.Time                      (defaultTimeLocale, formatTime,
                                                 getZonedTime)
import           Foreign.C.Types                (CInt)
import           GHC.IO.Handle.FD               (fdToHandle)
import           System.Directory               (doesPathExist)
import           System.Exit                    (ExitCode (..))
import           System.IO                      (BufferMode (..), Handle,
                                                 IOMode (..), hClose, hGetLine,
                                                 hPutStrLn, hSetBuffering,
                                                 openFile, stderr)
import           System.IO.Error                (catchIOError, isEOFError)
import           UnliftIO.Exception             (bracket)

-- internal
import           P4P.Sim.Internal
import           P4P.Sim.Options                (SimIAction (..),
                                                 SimIOAction (..),
                                                 SimLogging (..),
                                                 SimOAction (..),
                                                 SimOptions (..))
import           P4P.Sim.Types

-- TODO: export to upstream extra
untilJustM :: Monad m => m (Maybe a) -> m a
untilJustM act = go
 where
  go = act >>= \case
    Just r  -> pure r
    Nothing -> go

hGetLineOrEOF :: Handle -> IO (Maybe String)
hGetLineOrEOF h = catchIOError
  (Just <$> hGetLine h)
  (\e -> if isEOFError e then pure Nothing else ioError e)

mkHandle :: Either CInt FilePath -> IO Handle
mkHandle fdOrFile = do
  h <- case fdOrFile of
    Right path -> openFile path AppendMode
    Left  fd   -> fdToHandle fd
  hSetBuffering h LineBuffering
  pure h

type DeferredIO a = Either String (IO a)

runDeferredIO :: Traversable t => t (DeferredIO a) -> IO (t a)
runDeferredIO res = case lefts (toList res) of
  -- check if there are any errors; only if none, then run all deferred IO at once
  []  -> for res $ fromRight $ error "unreachable"
  err -> fail $ "errors: " <> intercalate "; " err

readIfExist :: String -> FilePath -> IO (DeferredIO Handle)
readIfExist n p = doesPathExist p >$> \case
  True  -> Right $ openFile p ReadMode
  False -> Left $ "path " <> n <> ": does not exist for reading: " <> p

writeIfNonexist :: String -> FilePath -> IO (DeferredIO Handle)
writeIfNonexist n p = doesPathExist p >$> \case
  False -> Right $ openFile p WriteMode
  True  -> Left $ "path " <> n <> ": conflict exists for writing: " <> p

dOpenIAction
  :: String -> SimIAction FilePath -> IO (SimIAction (DeferredIO Handle))
dOpenIAction n SimIAction {..} =
  SimIAction
    <$> traverse (readIfExist $ n <> "/IActRead")      simIActRead
    <*> traverse (writeIfNonexist $ n <> "/IActWrite") simIActWrite

dOpenOAction
  :: String -> SimOAction FilePath -> IO (SimOAction (DeferredIO Handle))
dOpenOAction n SimOAction {..} =
  SimOAction
    <$> traverse (writeIfNonexist $ n <> "/OActWrite") simOActWrite
    <*> traverse (readIfExist $ n <> "/OActCompare")   simOActCompare

dOpenIOAction :: SimIOAction FilePath -> IO (SimIOAction (DeferredIO Handle))
dOpenIOAction SimIOAction {..} =
  SimIOAction
    <$> dOpenIAction "IState" simIState
    <*> dOpenIAction "IMsg"   simIMsg
    <*> dOpenOAction "OMsg"   simOMsg
    <*> dOpenOAction "OState" simOState

openIOAction :: SimIOAction FilePath -> IO (SimIOAction Handle)
openIOAction a = dOpenIOAction a >>= runDeferredIO

closeIOAction :: SimIOAction Handle -> IO ()
closeIOAction = void . traverse hClose

-- | Convenience type alias for being able to record and replay a simulation.
-- TODO: use ByteString/Generic-based thing, e.g. Serialise
type SimReRe pid ps
  = ( Show pid
    , Read pid
    , Show ps
    , Read ps
    , Show (UserI ps)
    , Read (UserI ps)
    , Show (UserO ps)
    , Read (UserO ps)
    , Show (PAddr ps)
    , Read (PAddr ps)
    , Show (PMsg ps)
    , Read (PMsg ps)
    , Ord (PAddr ps)
    )

type SimUserIO pid ps
  = (IO (Maybe (SimUserI pid ps)), SimUserO pid ps -> IO ())
type UserSimIO pid ps
  = (Maybe (SimUserI pid ps) -> IO (), IO (SimUserO pid ps))

data UserSimAsync pid ps = UserSimAsync
  { simWI         :: !(Maybe (SimUserI pid ps) -> IO ())
  , simRO         :: !(IO (SimUserO pid ps))
  , simCancel     :: !(IO ())
  , simWaitFinish :: !(IO (Either (NonEmpty SimError) ()))
  }

defaultSimUserIO :: SimReRe pid ps => IO (Maybe String) -> SimUserIO pid ps
defaultSimUserIO getInput =
  -- support special "pid :~ msg" syntax for SimProcUserI / SimProcUserO
  let i = untilJustM $ getInput >>= \case
        Nothing -> pure (Just Nothing) -- EOF, quit
        Just s  -> if null s
          then pure Nothing
          else case readEither s of
            Right (pid :~ ui) -> pure (Just (Just (SimProcUserI pid ui)))
            Left  _           -> case readEither s of
              Right r -> pure (Just (Just r))
              Left  e -> putStrLn e >> pure Nothing
      o = \case
        SimProcUserO pid uo -> print $ pid :~ uo
        x                   -> print x
  in  (i, o)

-- | SimUserIO that reads/writes from TBQueues.
tbQueueSimUserIO :: IO (UserSimIO pid ps, SimUserIO pid ps)
tbQueueSimUserIO = do
  qi <- newTBQueueIO 1
  qo <- newTBQueueIO 1
  let ri = atomically $ readTBQueue qi
      ro = atomically $ readTBQueue qo
      wi = atomically . writeTBQueue qi
      wo = atomically . writeTBQueue qo
  pure ((wi, ro), (ri, wo))

{- | Combine a bunch of 'SimUserIO' together.

The composed version will:

  * read from any input, preserving relative order of inputs
  * write to every output, in the same order as the given list

EOF ('Nothing') on any input stream will be interpreted as EOF for the whole
sim. An extra function is also returned, which the caller can use to close the
input stream proactively in a graceful way: the sim will see an explicit EOF
after consuming any outstanding unconsumed inputs.
-}
combineSimUserIO :: [SimUserIO pid ps] -> IO (SimUserIO pid ps, IO ())
combineSimUserIO ios = do
  let (is, os) = unzip ios
  (i, close) <- foreverInterleave is
  let o x = for_ os ($ x)
  pure ((join <$> i, o), close)

-- | Convert a 'runClocked' input to 'SimI' format, with 'Nothing' (EOF) lifted
-- to the top of the ADT structure.
c2i :: Either Tick (Maybe x) -> Maybe (GMsg (RuntimeI ()) x v a)
c2i (Right Nothing ) = Nothing
c2i (Left  t       ) = Just (MsgRT (RTTick t ()))
c2i (Right (Just a)) = Just (MsgUser a)

type SimLog pid ps
  = ( Show pid
    , Show ps
    , Show (PAddr ps)
    , Show (GMsgI ps)
    , Show (GMsgO ps)
    , Show (UserO ps)
    , Show (AuxO ps)
    )

defaultSimLog
  :: SimLog pid ps
  => (SimO pid ps -> Bool)
  -> String
  -> Handle
  -> (Tick, SimO pid ps)
  -> IO ()
defaultSimLog f tFmt h (t, evt) = when (f evt) $ do
  tstr <- formatTime defaultTimeLocale tFmt <$< getZonedTime
  hPutStrLn h $ tstr <> " | " <> show t <> " | " <> show evt

logAllNoUser :: GMsg r u p a -> Bool
logAllNoUser = \case
  MsgUser _ -> False
  _         -> True

logAllNoUserTicks :: GMsg r u p (SimAuxO pid ps) -> Bool
logAllNoUserTicks = \case
  MsgUser _ -> False
  MsgAux (SimProcEvent (SimMsgRecv _ (MsgRT (RTTick _ _)))) -> False
  _         -> True

compareOMsg :: (SimError -> IO ()) -> Tick -> Maybe String -> Handle -> IO ()
compareOMsg simError t om h = do
  om' <- hGetLineOrEOF h
  when (om /= om') $ simError $ do
    SimFailedReplayCompare "simOMsg" t (s om') (s om)
  where s = fromMaybe "<EOF>"

defaultRT
  :: forall pid ps
   . (SimLog pid ps, SimReRe pid ps)
  => SimOptions
  -> Tick
  -> SimUserIO pid ps
  -> SimIAction Handle
  -> SimOAction Handle
  -> IO (SimRT pid ps IO)
defaultRT opt initTick (simUserI, simUserO) simIMsg simOMsg = do
  let picosPerMs   = 1000000000
      picosPerTick = simMsTick * picosPerMs

      logFilter    = case simLogging of
        LogAll            -> const True
        LogAllNoUser      -> logAllNoUser
        LogAllNoUserTicks -> logAllNoUserTicks @_ @_ @_ @pid @ps
        LogNone           -> const False

  simLog <- case simLogging of
    LogNone -> pure (\_ -> pure ())
    _ ->
      mkHandle simLogOutput >$> defaultSimLog @pid @ps logFilter simLogTimeFmt

  (simI, simIClose) <- case simIActRead simIMsg of
    Nothing -> do
      simClock <- newClock initTick (interval picosPerTick Ps)
      clkEnvI  <- clockWith simClock simUserI
      pure (runClocked clkEnvI >$> c2i, finClocked clkEnvI)
    Just h -> do
      pure (hGetLineOrEOF h >$> fmap (readNote "simIMsg read"), pure ())

  simErrors <- newTVarIO []

  let
    simClose = simIClose
    simError e = atomically $ modifyTVar' simErrors $ \ee -> (: ee) $! e
    simStatus = readTVarIO simErrors >$> \case
      [] -> Right ()
      x  -> Left (fromList (reverse x))

    simRunI = do
      i <- simI
      whenJust (simIActWrite simIMsg) $ \h -> do
        whenJust i $ hPutStrLn h . show
      pure i

    simRunO (t, o) = do
      simLog (t, o)
      case o of
        MsgAux _ -> pure () -- ignore MsgAux messages

        _        -> do
          let om = show (t, o)
          case simOActWrite simOMsg of
            Nothing -> case o of
              MsgUser uo -> simUserO uo
              _          -> pure ()
            Just h -> hPutStrLn h om

          whenJust (simOActCompare simOMsg) $ compareOMsg simError t (Just om)

  pure SimRT { .. }
  where SimOptions {..} = opt

runSimIO
  :: forall pid p
   . Sim pid p IO
  => SimLog pid (State p)
  => SimReRe pid (State p)
  => SimOptions
  -> S.Set pid
  -> (pid -> IO (State p))
  -> SimUserIO pid (State p)
  -> IO (Either (NonEmpty SimError) ())
runSimIO opt initPids mkPState simUserIO =
  bracket (openIOAction simIOAction) closeIOAction $ \SimIOAction {..} -> do
    --print opt
    (iSimState, istate) <- case simIActRead simIState of
      Nothing -> do
        seed   <- getEntropy @ScrubbedBytes 64
        states <- M.traverseWithKey (const . mkPState)
          $ M.fromSet (const ()) initPids
        pure (newSimState seed simInitLatency initPids, states)
      Just h -> hGetLine h >$> readNote "simIState read"
    whenJust (simIActWrite simIState)
      $ flip hPutStrLn (show (iSimState, istate))

    let realNow = simNow iSimState
        mkRT    = defaultRT opt realNow simUserIO simIMsg simOMsg
    bracket mkRT simClose $ \rt@SimRT {..} -> do
      (SimFullState ostate oSimState) <- runSimulation1 @_ @p
        rt
        (SimFullState istate iSimState)

      let t = simNow oSimState
      whenJust (simOActCompare simOMsg) $ compareOMsg simError t Nothing

      let os = show (oSimState, ostate)
      whenJust (simOActWrite simOState) $ flip hPutStrLn os
      whenJust (simOActCompare simOState) $ \h -> do
        os' <- hGetLine h
        when (os /= os') $ simError $ do
          SimFailedReplayCompare "simOState" t os' os

      simStatus
  where SimOptions {..} = opt

handleSimResult :: Either (NonEmpty SimError) () -> IO ExitCode
handleSimResult = \case
  Right ()  -> pure ExitSuccess
  Left  err -> do
    hPutStrLn stderr $ "simulation gave errors: " <> show err
    pure (ExitFailure 1)

newSimAsync
  :: forall pid p
   . Maybe (SimUserO pid (State p) -> IO ())
  -> (SimUserIO pid (State p) -> IO (Either (NonEmpty SimError) ()))
  -> IO (UserSimAsync pid (State p))
newSimAsync maybeEat runSimIO' = do
  ((simWI, simRO), simUserIO) <- tbQueueSimUserIO @_ @(State p)
  aMain                       <- async $ runSimIO' simUserIO
  link aMain
  simCancel <- case maybeEat of
    Nothing  -> pure (cancel aMain)
    Just eat -> do
      aRead <- async $ forever $ simRO >>= eat
      link aRead
      link2 aMain aRead
      pure (cancel aMain >> cancel aRead)
  let simWaitFinish = wait aMain
  pure $ UserSimAsync { .. }