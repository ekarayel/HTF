module Test.Framework.History (

    TestHistory, HistoryTestResult(..)
  , serializeTestHistory, deserializeTestHistory
  , findHistoricTestResult

) where

import Test.Framework.TestTypes

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V

data TestHistory
    = TestHistory
      { th_runs :: !(V.Vector TestRunHistory) -- reverse chronologically sorted
      , th_map :: !(Map T.Text HistoryTestResult)
      }

data TestRunHistory
    = TestRunHistory
      { trh_startTime :: !UTCTime
      , trh_tests :: !(V.Vector HistoricTestResult)
      }

data HistoricTestResult
    = HistoricTestResult
      { htr_testId :: !T.Text
      , htr_result :: !TestResult
      , htr_timeMs :: !Milliseconds
      }

findHistoricTestResult :: T.Text -> TestHistory -> Maybe HistoricTestResult
findHistoricTestResult = undefined

serializeTestHistory :: TestHistory -> BS.ByteString
serializeTestHistory = undefined

deserializeTestHistory :: BS.ByteString -> Either String TestHistory
deserializeTestHistory = undefined
