{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
--
-- Copyright (c) 2009-2012   Stefan Wehr - http://www.stefanwehr.de
--
-- This library is free software; you can redistribute it and/or
-- modify it under the terms of the GNU Lesser General Public
-- License as published by the Free Software Foundation; either
-- version 2.1 of the License, or (at your option) any later version.
--
-- This library is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
-- Lesser General Public License for more details.
--
-- You should have received a copy of the GNU Lesser General Public
-- License along with this library; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA
--

{- |

This module defines the commandline options of the test driver provided by HTF.

-}
module Test.Framework.CmdlineOptions (

    CmdlineOptions(..), defaultCmdlineOptions, parseTestArgs, helpString,
    testConfigFromCmdlineOptions

) where

import Test.Framework.TestReporter
import Test.Framework.TestTypes
import Test.Framework.Utils

#if !MIN_VERSION_base(4,6,0)
import Prelude hiding ( catch )
#endif
import Control.Exception

import Data.Char (toLower)
import Data.Maybe

import System.IO
import System.Environment
import System.Directory
import System.Console.GetOpt
import qualified Text.Regex as R

#ifndef mingw32_HOST_OS
import System.Posix.Terminal
import System.Posix.IO (stdOutput)
import System.Posix.Env (getEnv)
#endif

#ifdef __GLASGOW_HASKELL__
import GHC.Conc ( numCapabilities )
#endif

import qualified Data.ByteString as BS

--
-- CmdlineOptions
--

-- | Commandline options for running tests.
data CmdlineOptions = CmdlineOptions {
      opts_quiet :: Bool                -- ^ Be quiet or not.
    , opts_filter :: TestFilter         -- ^ Run only tests matching this filter.
    , opts_help :: Bool                 -- ^ If 'True', display a help message and exit.
    , opts_negated :: [String]          -- ^ Regular expressions matching test names which should /not/ run.
    , opts_threads :: Maybe Int         -- ^ Use @Just i@ for parallel execution with @i@ threads, @Nothing@ for sequential execution.
    , opts_shuffle :: Bool              -- ^ If 'True', shuffle tests when running them in parallel. Default: 'False'
    , opts_machineOutput :: Bool        -- ^ Format output for machines (JSON format) or humans. See 'Test.Framework.JsonOutput' for a definition of the JSON format.
    , opts_machineOutputXml :: Maybe FilePath -- ^ Output file for junit-style XML output. See 'Test.Framework.XmlOutput' for a definition of the XML format.
    , opts_useColors :: Maybe Bool      -- ^ Use @Just b@ to enable/disable use of colors, @Nothing@ infers the use of colors.
    , opts_outputFile :: Maybe FilePath -- ^ The output file, defaults to stdout
    , opts_listTests :: Bool            -- ^ If 'True', lists all tests available and exits.
    , opts_split :: Bool                -- ^ If 'True', each message is sent to a new ouput file (derived by appending an index to 'opts_outputFile').
    , opts_historyFile :: Maybe FilePath -- ^ History file, default: @./.HTF/<ProgramName>.history@
    , opts_failFast :: Bool             -- ^ Fail and terminate test run as soon as the first test fails. Default: 'False'
    , opts_sortByPrevTime :: Bool       -- ^ Sort tests by their previous run times (ascending). Default: 'True'
    , opts_maxPrevTimeMs :: Maybe Milliseconds -- ^ Ignore tests that with a runtime greater than given in a previous test run
    , opts_maxCurTimeMs :: Maybe Milliseconds  -- ^ Abort tests (but don't fail) that run more than the given milliseconds.
    }

{- |
The default 'CmdlineOptions'.
-}
defaultCmdlineOptions :: CmdlineOptions
defaultCmdlineOptions = CmdlineOptions {
      opts_quiet = False
    , opts_filter = const True
    , opts_help = False
    , opts_negated = []
    , opts_threads = Nothing
    , opts_shuffle = False
    , opts_machineOutput = False
    , opts_machineOutputXml = Nothing
    , opts_useColors = Nothing
    , opts_outputFile = Nothing
    , opts_listTests = False
    , opts_split = False
    , opts_historyFile = Nothing
    }

processorCount :: Int
#ifdef __GLASGOW_HASKELL__
processorCount = numCapabilities
#else
processorCount = 1
#endif

optionDescriptions :: [OptDescr (CmdlineOptions -> CmdlineOptions)]
optionDescriptions =
    [ Option ['q']     ["quiet"]   (NoArg (\o -> o { opts_quiet = True })) "only display errors"
    , Option ['n']     ["not"]     (ReqArg (\s o -> o { opts_negated = s : (opts_negated o) })
                                           "PATTERN") "tests to exclude"
    , Option ['l']     ["list"]   (NoArg (\o -> o { opts_listTests = True })) "list all matching tests"
    , Option ['j']     ["threads"]   (OptArg (\ms o -> o { opts_threads = Just (parseThreads ms) }) "N")
                                      ("run N tests in parallel, default N=" ++ show processorCount)
    , Option []        ["deterministic"] (NoArg (\o -> o { opts_shuffle = False })) "do not shuffle tests when executing them in parallel."
    , Option ['o']     ["output-file"] (ReqArg (\s o -> o { opts_outputFile = Just s })
                                               "FILE") "name of output file"
    , Option []        ["json"] (NoArg (\o -> o { opts_machineOutput = True }))
                               "output results in machine-readable JSON format (incremental)"
    , Option []        ["xml"] (ReqArg (\s o -> o { opts_machineOutputXml = Just s }) "FILE")
                               "output results in junit-style XML format"
    , Option []        ["split"] (NoArg (\o -> o { opts_split = True }))
                               "splits results in separate files to avoid file locking (requires -o/--output-file)"
    , Option []        ["colors"]  (ReqArg (\s o -> o { opts_useColors = Just (parseBool s) })
                                           "BOOL") "use colors or not"
    , Option []        ["history"] (ReqArg (\s o -> o { opts_historyFile = Just s }) "FILE")
             "Path to the history file. Default: ./.HTF/<ProgramName>.history"
    , Option []        ["fail-fast"] (NoArg (\o -> o { opts_failFast = True }))
             "Fail and abort test run as soon as the first test fails"
    , Option []        ["sort-by-prev-time"] (ReqArg (\s o -> o { opts_sortByPrevTime = parseBool s }) "BOOL")
             "Sort tests ascending by their execution of the previous test run (if available). Default: true"
    , Option []        ["max-prev-ms"] (ReqArg (\s o -> o { opts_maxPrevTimeMs = parseInt "--max-prev-ms" s }) "MILLISECONDS")
             "Do not try to execute tests that had a execution time greater thatn MILLISECONDS in a previous test run"
    , Option []        ["max-cur-ms"] (ReqArg (\s o -> o { opts_maxCurTimeMs = parseInt "--max-cur-ms" s }) "MILLISECONDS")
             "Abort (but don't fail) a test that runs more than MILLISECONDS"
    , Option ['h']     ["help"]    (NoArg (\o -> o { opts_help = True })) "display this message"
    ]
    where
      parseThreads Nothing = processorCount
      parseThreads (Just s) =
          case readM s of
            Just i -> i
            Nothing -> error ("invalid number of threads: " ++ s)
      parseBool s =
          if map toLower s `elem` ["1", "true", "yes", "on"] then True else False
      parseMilliseconds opt s =
          case readM of
            Just i -> i
            Nothign -> error ("invalid value for option " ++ opt ++ ": " ++ s)

{- |

Parse commandline arguments into 'CmdlineOptions'. Here's a synopsis
of the format of the commandline arguments:

FIXME

> USAGE: COMMAND [OPTION ...] PATTERN ...
>
>   where PATTERN is a posix regular expression matching
>   the names of the tests to run.
>
>   -q          --quiet             only display errors
>   -n PATTERN  --not=PATTERN       tests to exclude
>   -l          --list              list all matching tests
>   -j[N]       --threads[=N]       run N tests in parallel, default N=4
>               --deterministic     do not shuffle tests when executing them in parallel.
>   -o FILE     --output-file=FILE  name of output file
>               --json              output results in machine-readable JSON format (incremental)
>               --xml=FILE          output results in junit-style XML format
>               --split             splits results in separate files to avoid file locking (requires -o/--output-file)
>               --colors=BOOL       use colors or not
>   -h          --help              display this message

-}

parseTestArgs :: [String] -> Either String CmdlineOptions
parseTestArgs args =
    case getOpt Permute optionDescriptions args of
      (optTrans, tests, []  ) ->
          let posStrs = tests
              negStrs = opts_negated opts
              pos = map mkRegex posStrs
              neg = map mkRegex negStrs
              pred (FlatTest _ path _ _) =
                  let flat = flatName path
                  in if (any (\s -> s `matches` flat) neg)
                        then False
                        else null pos || any (\s -> s `matches` flat) pos
              opts = (foldr ($) defaultCmdlineOptions optTrans) { opts_filter = pred }
          in case (opts_outputFile opts, opts_split opts) of
               (Nothing, True) -> Left ("Option --split requires -o or --output-file\n\n" ++
                                        usageInfo usageHeader optionDescriptions)
               _ -> Right opts
      (_,_,errs) ->
          Left (concat errs ++ usageInfo usageHeader optionDescriptions)
    where
      matches r s = isJust $ R.matchRegex r s
      mkRegex s = R.mkRegexWithOpts s True False

usageHeader :: String
usageHeader = ("USAGE: COMMAND [OPTION ...] PATTERN ...\n\n" ++
               "  where PATTERN is a posix regular expression matching\n" ++
               "  the names of the tests to run.\n")

-- | The string displayed for the @--help@ option.
helpString :: String
helpString = usageInfo usageHeader optionDescriptions

--
-- TestConfig
--

-- | Turn the 'CmdlineOptions' into a 'TestConfig'.
testConfigFromCmdlineOptions :: CmdlineOptions -> IO TestConfig
testConfigFromCmdlineOptions opts =
    do (output, colors) <-
           case (opts_outputFile opts, opts_split opts) of
             (Just fname, True) -> return (TestOutputSplitted fname, False)
             _ -> do (outputHandle, closeOutput, mOutputFd) <- openOutputFile
                     colors <- checkColors mOutputFd
                     return (TestOutputHandle outputHandle closeOutput, colors)
       let threads = opts_threads opts
           reporters = defaultTestReporters (isParallelFromBool $ isJust threads)
                                            (if opts_machineOutput opts then JsonOutput else NoJsonOutput)
                                            (if isJust (opts_machineOutputXml opts) then XmlOutput else NoXmlOutput)
       historyFile <- getHistoryFile
       history <- getHistory
       return $ TestConfig { tc_quiet = opts_quiet opts
                           , tc_threads = threads
                           , tc_shuffle = opts_shuffle opts
                           , tc_output = output
                           , tc_outputXml = opts_machineOutputXml opts
                           , tc_reporters = reporters
                           , tc_filter = opts_filter opts `mergeFilter` (historicFilter history)
                           , tc_useColors = colors
                           , tc_historyFile = historyFile
                           , tc_history = history
                           }
    where
#ifdef mingw32_HOST_OS
      openOutputFile =
          case opts_outputFile opts of
            Nothing -> return (stdout, False, Nothing)
            Just fname ->
                do f <- openFile fname WriteMode
                   return (f, True, Nothing)
      checkColors mOutputFd =
          case opts_useColors opts of
            Just b -> return b
            Nothing -> return False
#else
      openOutputFile =
          case opts_outputFile opts of
            Nothing -> return (stdout, False, Just stdOutput)
            Just fname ->
                do f <- openFile fname WriteMode
                   return (f, True, Nothing)
      checkColors mOutputFd =
          case opts_useColors opts of
            Just b -> return b
            Nothing ->
                do mterm <- getEnv "TERM"
                   case mterm of
                     Nothing -> return False
                     Just s | map toLower s == "dumb" -> return False
                     _ -> do mx <- getEnv "HTF_NO_COLORS"
                             case mx of
                               Just s | map toLower s `elem` ["", "1", "y", "yes", "true"] -> return False
                               _ -> case mOutputFd of
                                      Just fd -> queryTerminal fd
                                      _ -> return False
#endif
      getHistoryFile =
          case opts_historyFile opts of
            Just fp -> return fp
            Nothing ->
                do x <- getProgName
                   createDirectoryIfMissing False ".HTF"
                   return (".HTF/" ++ x ++ ".history")
      getHistory fp =
          do b <- doesFileExist fp
             if not b
             then return emptyHistory
             else do bs < BS.readFile fp
                     case deserializeHistory bs of
                       Right history -> return history
                       Left err ->
                           do hPutStrLn stderr ("Error deserializing content of history file " ++ fp ++ ": " ++ err)
                              return emptyHistory
                  `catch` (\(e::IOException) ->
                               do hPutStrLn stderr ("Error reading history file " ++ fp ++ ": " ++ show e)
                                  return emptyHistory
      mergeFilters f1 f2 t =
          f1 t && f1 t
      historicFilter history t =
          case opts_maxPrevTimeMs opts of
            Nothing -> True
            Just ms ->
                case findHistoricTestResult (T.pack (flatName t)) history of
                  Nothing -> True
                  Just res -> htr_timeMs res <= ms
