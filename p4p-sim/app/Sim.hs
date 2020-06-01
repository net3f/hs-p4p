{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

-- external
import           Control.Op
import           Data.Dependent.Sum        (DSum (..))
import           P4P.Proc                  (Proc, Protocol (..))

-- external, kademlia
import           P4P.Protocol.DHT.Kademlia (KState, defaultParams,
                                            newRandomState)

-- external, IO
import           System.Environment        (getArgs)
import           System.Exit               (ExitCode (..), exitWith)

-- internal
import           P4P.Sim
import           P4P.Sim.EchoProcess       (EchoState (..))
import           P4P.Sim.Options           (simParseOptions)
import           P4P.Sim.Util              (ChaChaDRGInsecure, PMut', Pid,
                                            getEntropy, mkInitPids)
import           P4P.Sim.Util.IO           (maybeTerminalGetInput)


data SProt ps where
  SEcho :: SProt EchoState
  SKad :: SProt (KState ChaChaDRGInsecure)

withSProt
  :: SProt ps
  -> ((Read (UserI ps), Show (UserO ps), Read ps, Show ps) => a)
  -> a
withSProt prot a = case prot of
  SEcho -> a
  SKad  -> a

type SimC ps
  = (SimProcess Pid (PMut' ps), SimLog Pid ps (), SimReRe Pid ps (), Proc ps)

withSimProto
  :: SimOptions
  -> (forall ps . SimC ps => SProt ps -> (Pid -> IO ps) -> IO a)
  -> IO a
withSimProto opt f = case simProto of
  ProtoEcho -> f SEcho $ \p -> pure (EState [p] 0)
  ProtoKad  -> f SKad $ \p -> do
    let params = defaultParams $ fromIntegral $ 1000 `div` simMsTick
        addr   = "addr:" <> show p
    newRandomState @ChaChaDRGInsecure getEntropy [addr] params
  where SimOptions {..} = opt

-- run via stdin/stdout
runStd :: SimOptions -> IO ExitCode
runStd opt = withSimProto opt $ \(p :: SProt ps) mkPS -> withSProt p $ do
  getInput <- maybeTerminalGetInput "p4p"
                                    ".sim_history"
                                    ("p4p " <> drop 5 (show simProto) <> "> ")
  let initPids  = mkInitPids opt
  let simUserIO = defaultSimUserIO @_ @ps @() getInput
  runSimIO @_ @(PMut' ps) opt initPids mkPS simUserIO >>= handleSimResult
  where SimOptions {..} = opt

newtype UserSimAsync' pid ps = UserSimAsync' (UserSimAsync pid ps ())

-- run via tb-queues, can be loaded from GHCI
runTB :: SimOptions -> IO (DSum SProt (UserSimAsync' Pid))
runTB opt = withSimProto opt $ \(p :: SProt ps) mkPS -> withSProt p $ do
  let runSimIO' = runSimIO @_ @(PMut' ps) opt (mkInitPids opt) mkPS
  handles <- newSimAsync @_ @(PMut' ps) (Just print) runSimIO'
  pure $ p :=> UserSimAsync' handles

main :: IO ()
main =
  getArgs
    >>= simParseOptions
    -- "if True" avoids "unused" warnings for runTB
    >>= (if True then runStd else runTB >=> const (pure ExitSuccess))
    >>= exitWith
