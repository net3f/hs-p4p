{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DeriveTraversable   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module P4P.Sim.Options where

-- external
import           Control.Op
import           Foreign.C.Types                (CInt)
import           GHC.Generics                   (Generic)
import           Options.Applicative
import           Options.Applicative.Help.Chunk

-- internal
import           P4P.Sim.Types


showOptions :: forall a . (Show a, Enum a, Bounded a) => String
showOptions = "one of: " <> show (allOptions :: [a])

allOptions :: forall a . (Enum a, Bounded a) => [a]
allOptions = enumFrom minBound

helps :: [String] -> Mod f a
helps strs = helpDoc $ Just $ extractChunk $ vsepChunks $ fmap paragraph strs

data SimProto = ProtoEcho | ProtoKad
 deriving (Eq, Ord, Show, Read, Generic, Bounded, Enum)

data SimLogging =
    LogNone
    -- ^ Log nothing
  | LogAllNoUserTicks
    -- ^ Log all except user output & ticks, which are predictable.
  | LogAllNoUser
    -- ^ Log all except user output, which is likely already output elsewhere.
  | LogAll
    -- ^ Log everything, pretty spammy.
 deriving (Eq, Ord, Show, Read, Generic, Bounded, Enum)

loggerFromInt :: Int -> SimLogging
loggerFromInt i | i > 2     = LogAll
                | i == 2    = LogAllNoUser
                | i == 1    = LogAllNoUserTicks
                | otherwise = LogNone

loggerFromIntStrDesc :: String
loggerFromIntStrDesc = "0 -> LogNone, 1 -> LogAllNoTicks, 2+ -> LogAll."

data SimIAction p = SimIAction
  { simIActRead  :: !(Maybe p)
    -- ^ Take input by reading from the given path.
    --
    -- The path must exist already. If 'Nothing' is given then the input will
    -- be read in some default way, dependent on the context.
  , simIActWrite :: !(Maybe p)
    -- ^ For all input, write it into the given path.
    --
    -- The path must not exist.
  }
  deriving (Eq, Ord, Show, Read, Generic, Functor, Foldable, Traversable)

data SimOAction p = SimOAction
  { simOActWrite   :: !(Maybe p)
    -- ^ For all output, write it into the given path.
    --
    -- The path must not exist.
  , simOActCompare :: !(Maybe p)
    -- ^ For all output, compare with the pre-recorded path.
    --
    -- The path must exist already.
  }
  deriving (Eq, Ord, Show, Read, Generic, Functor, Foldable, Traversable)

data SimIOAction p = SimIOAction
  { simIState :: !(SimIAction p)
    -- ^ How we should take input state.
    --
    -- If no source is given, we use a default "null initial" state.
  , simIMsg   :: !(SimIAction p)
    -- ^ How we should take input messages.
    --
    -- If no source is given, we use standard input.
  , simOMsg   :: !(SimOAction p)
    -- ^ What to do with output messages.
  , simOState :: !(SimOAction p)
  }
  deriving (Eq, Ord, Show, Read, Generic, Functor, Foldable, Traversable)

actionOptions :: Parser (SimIOAction FilePath)
actionOptions =
  SimIOAction
    <$> (   SimIAction
        <$> optional
              (  strOption
              <| long "istate-r"
              <> metavar "FILE"
              <> help
                   "Read input state from this file. If given, the file must exist. If this not given, then a default empty initial state will be used, specific to the protocol chosen."
              )
        <*> optional
              (strOption <| long "istate-w" <> metavar "FILE" <> help
                "Write input state to this file, which must not exist."
              )
        )
    <*> (   SimIAction
        <$> optional
              (  strOption
              <| long "imsg-r"
              <> metavar "FILE"
              <> help
                   "Read input messages from this file. If given, the file must exist. If not given, then messages will be taken from stdin. "
              )
        <*> optional
              (strOption <| long "imsg-w" <> metavar "FILE" <> help
                "Write input messages to this file, which must not exist."
              )
        )
    <*> (   SimOAction
        <$> optional
              (strOption <| long "omsg-w" <> metavar "FILE" <> help
                "Write output messages to this file, which must not exist."
              )
        <*> optional
              (strOption <| long "omsg-c" <> metavar "FILE" <> help
                "Compare output messages with this file, which must exist."
              )
        )
    <*> (   SimOAction
        <$> optional
              (strOption <| long "ostate-w" <> metavar "FILE" <> help
                "Write output state to this file, which must not exist."
              )
        <*> optional
              (strOption <| long "ostate-c" <> metavar "FILE" <> help
                "Compare output state with this file, which must exist."
              )
        )

filespecReader :: ReadM (FilePath, FilePath, FilePath)
filespecReader = eitherReader $ \s -> case span (/= ':') (reverse s) of
  (rx@(_ : _), ':' : 'i' : '.' : residue) -> case span (/= ':') residue of
    (ri@(_ : _), ':' : 's' : '.' : rs@(_ : _)) ->
      Right (reverse rs, reverse ri, reverse rx)
    _ -> Left "FILESPEC syntax error"
  _ -> Left "FILESPEC syntax error"

succString :: String -> String
succString x =
  let r      = reverse x
      (d, s) = span (`elem` "0123456789") r
      l      = length d
  in  if l == 0
        then x <> "+"
        else
          let n  = read (reverse d) :: Integer
              d' = show (succ n)
              l' = length d'
              p  = if l' < l then replicate (l - l') '0' else []
          in  reverse s <> p <> d'

initMode :: (FilePath, FilePath, FilePath) -> SimIOAction FilePath
initMode (s, i, x) =
  let s' = s <> ".s"
      is = SimIAction Nothing (Just s')
      im = SimIAction (Just "/dev/null") Nothing -- TODO: cross-platform
      om = SimOAction Nothing Nothing
      os = SimOAction Nothing Nothing
  in  SimIOAction is im om os

recordMode :: (FilePath, FilePath, FilePath) -> SimIOAction FilePath
recordMode (s, i, x) =
  let s' = s <> ".s"
      i' = s' <> ":" <> i <> ".i"
      is = SimIAction (Just s') Nothing
      im = SimIAction Nothing (Just i')
      om = SimOAction (Just $ i' <> ":" <> x <> ".o") Nothing
      os = SimOAction (Just $ i' <> ":" <> x <> ".s") Nothing
  in  SimIOAction is im om os

replayMode :: (FilePath, FilePath, FilePath) -> SimIOAction FilePath
replayMode (s, i, x) =
  let s' = s <> ".s"
      i' = s' <> ":" <> i <> ".i"
      is = SimIAction (Just s') Nothing
      im = SimIAction (Just i') Nothing
      om = SimOAction Nothing (Just $ i' <> ":" <> x <> ".o")
      os = SimOAction Nothing (Just $ i' <> ":" <> x <> ".s")
  in  SimIOAction is im om os

rereMode :: (FilePath, FilePath, FilePath) -> SimIOAction FilePath
rereMode (s, i, x) =
  let s'  = s <> ".s"
      i'  = s' <> ":" <> i <> ".i"
      i'' = i' <> ":"
      y   = succString x
      is  = SimIAction (Just s') Nothing
      im  = SimIAction (Just i') Nothing
      om  = SimOAction (Just $ i'' <> y <> ".o") (Just $ i'' <> x <> ".o")
      os  = SimOAction (Just $ i'' <> y <> ".s") (Just $ i'' <> x <> ".s")
  in  SimIOAction is im om os

-- TODO: ideally we'd group the option help text together but
-- https://github.com/pcapriotti/optparse-applicative/issues/270
allActionOptions :: Parser (SimIOAction FilePath)
allActionOptions =
  actionOptions
    <|> (   initMode
        <$< option filespecReader
        <|  long "init"
        <>  metavar "FILESPEC"
        <>  helps
              [ "Init mode for a FILESPEC $S.s:$I.i:$X will:"
              , "1. write a default empty input state into $S.s"
              , "2. exit immediately"
              , "It is mutually exclusive with --re* and the --[io]{state,msg}-* options."
              ]
        )
    <|> (   recordMode
        <$< option filespecReader
        <|  long "record"
        <>  metavar "FILESPEC"
        <>  helps
              [ "Record mode for a FILESPEC $S.s:$I.i:$X will:"
              , "1. read input state from    $S.s"
              , "2. write input  messages to $S.s:$I.i, reading them from stdin"
              , "3. write output messages to $S.s:$I.i:$X.o"
              , "4. write output state    to $S.s:$I.i:$X.s"
              , "It is mutually exclusive with --init, --re* and the --[io]{state,msg}-* options."
              ]
        )
    <|> (   replayMode
        <$< option filespecReader
        <|  long "replay"
        <>  metavar "FILESPEC"
        <>  helps
              [ "Replay mode for a FILESPEC $S.s:$I.i:$X will:"
              , "1. read input state        from $S.s"
              , "2. read input messages     from $S.s:$I.i"
              , "3. compare output messages with $S.s:$I.i:$X.o"
              , "4. compare output state    with $S.s:$I.i:$X.s"
              , "It is mutually exclusive with --init, --re* and the --[io]{state,msg}-* options."
              ]
        )
    <|> (   rereMode
        <$< option filespecReader
        <|  long "rere"
        <>  metavar "FILESPEC"
        <>  helps
              [ "Rere (record-and-replay) mode for a FILESPEC $S.s:$I.i:$X will:"
              , "1. read input state    from $S.s"
              , "2. read input messages from $S.s:$I.i"
              , "3. write output messages to $S.s:$I.i:$((X + 1)).o and compare them with $S.s:$I.i:$X.o"
              , "4. write output state    to $S.s:$I.i:$((X + 1)).s and compare them with $S.s:$I.i:$X.s"
              , "It is mutually exclusive with --init, --re* and the --[io]{state,msg}-* options."
              ]
        )

data SimOptions = SimOptions
  { simProto       :: !SimProto
  -- protocol selector
  -- this is the only thing that needs to be given in replay mode
  , simInitNodes   :: !Int
  , simInitLatency :: !SimLatency
  , simMsTick      :: !Integer
  -- execution config, ignored during replay
  , simIOAction    :: !(SimIOAction FilePath)
  -- IO options, inc. record/replay
  , simLogging     :: !SimLogging
  , simLogOutput   :: !(Either CInt FilePath)
  , simLogTimeFmt  :: !String
  -- logging options
  }
  deriving (Eq, Ord, Show, Read, Generic)

protoOptions :: Parser SimProto
protoOptions =
  option auto
    <| long "protocol"
    <> short 'p'
    <> metavar "Proto"
    <> help ("Protocol to simulate, " <> showOptions @SimProto)
    <> completeWith (show <$> allOptions @SimProto)
    <> value ProtoEcho
    <> showDefault

simOptions :: Parser SimProto -> Parser SimOptions
simOptions proto =
  SimOptions
    <$> proto
    <*> (  option auto
        <| long "num-nodes"
        <> short 'n'
        <> metavar "NUM"
        <> help
             "Initial number of nodes to launch. Ignored if reading from an existing input state, i.e. if --istate-r or --re* is given."
        <> value 1
        <> showDefault
        )
    <*> (   SLatAddrIndep
        <$< option auto
        <|  long "latency"
        <>  metavar "LAT"
        <>  help
              "Initial latency distribution, units in tick-delta. Ignored if reading from an existing input state, i.e. if --istate-r or --re* is given."
        <>  value (DistConstant 150)
        <>  showDefault
        )
    <*> (  option auto
        <| long "ms-per-tick"
        <> short 't'
        <> metavar "MS"
        <> help
             "Milliseconds in a tick. Ignored if reading from existing input messages, i.e. if --imsg-r or --replay or --rere is given."
        <> value 1
        <> showDefault
        )

    <*> allActionOptions

    <*> (   (  option auto
            <| long "logging"
            <> metavar "Logger"
            <> help ("Logging profile, " <> showOptions @SimLogging)
            <> completeWith (show <$> allOptions @SimLogging)
            <> value LogNone
            <> showDefault
            )
        <|> (   loggerFromInt
            <$< length
            <$< many
            <|  flag' ()
            <|  short 'v'
            <>  help
                  (  "Logging profile, occurence-counted flag. "
                  <> loggerFromIntStrDesc
                  )
            )
        )
    <*> (   (   Left
            <$< option auto
            <|  long "log-fd"
            <>  metavar "FD"
            <>  help "Log to a file descriptor."
            <>  value 2
            <>  showDefault
            )
        <|> (   Right
            <$< strOption
            <|  long "log-file"
            <>  short 'f'
            <>  metavar "FILE"
            <>  help "Log to a file."
            <>  action "file"
            )
        )
    <*> (  strOption
        <| long "log-time-fmt"
        <> metavar "FMT"
        <> help "Logging timestamp format-string."
        <> value "%Y-%m-%d %H:%M:%S.%3q %z"
        <> showDefault
        )

parserInfo :: String -> String -> Parser SimOptions -> ParserInfo SimOptions
parserInfo summary desc parser = info
  (helper <*> parser)
  (fullDesc <> header summary <> progDesc desc <> failureCode 2)

parseArgsIO :: ParserInfo SimOptions -> [String] -> IO SimOptions
parseArgsIO parser args =
  execParserPure defaultPrefs parser args |> handleParseResult

simParseOptions :: [String] -> IO SimOptions
simParseOptions = parseArgsIO $ parserInfo
  "sim - a simulator for p4p protocols"
  (  "Simulate a p4p protocol. Commands are given on stdin and replies "
  <> "are given on stdout. The syntax is $pid :~ $command where $pid "
  <> "and $command are Haskell Show/Read instance expressions, e.g. 0 :~ "
  <> "\"Hello, world!\". Give -v for more detailed output."
  )
  (simOptions protoOptions)
