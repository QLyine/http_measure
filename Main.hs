{-# LANGUAGE OverloadedStrings #-}

import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync, waitCatch)
import Control.Exception
import Control.Monad      (forM_, forever)
import Control.Monad.IO.Class

import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Read 
import Data.IORef
import Database.InfluxDB hiding((.:))
import Database.InfluxDB.Encode
import Data.Yaml
import qualified Data.Vector as V

import Network.HTTP.Client

import Prelude hiding (FilePath)

import Shelly

default (Text)

data Error = Error Int
  deriving (Show)

data HTTPReq = HTTPReq 
  { timeNameLookUp  :: Double
  , timeConnect     :: Double
  , timeAppConnect  :: Double
  , timePreTransfer :: Double
  , timeRedirect    :: Double
  , timeStartTrans  :: Double
  , timeTotal       :: Double
  , speedDownload   :: Double
  }
  deriving (Show)

data MyConfig = MyConfig 
  { continent :: Text 
  , infserver :: InfluxDBServer
  , cdns      :: [CDN]
  }
  deriving (Show)

data CDN = CDN 
  { name :: Text
  , urls :: [Text]
  }
  deriving (Show)

data InfluxDBServer = InfluxDBServer 
  { infhost :: Text
  , infport :: Int
  } deriving (Show)

instance ToSeriesData HTTPReq where
  toSeriesColumns _ = V.fromList ["timeNameLookUp", "timeConnect", "timeAppConnect", "timePreTransfer", "timeRedirect", "timeStartTrans", "timeTotal", "speedDownload"]
  toSeriesPoints (HTTPReq v1 v2 v3 v4 v5 v6 v7 v8) = V.fromList [toValue v1, toValue v2, toValue v3, toValue v4, toValue v5, toValue v6, toValue v7, toValue v8]

instance ToSeriesData Error where
  toSeriesColumns _ = V.fromList ["code"]
  toSeriesPoints (Error i) = V.fromList [toValue i]

instance FromJSON MyConfig where
  parseJSON (Object m) = MyConfig <$>
    m .: "continent" <*>
    m .: "infserver" <*>
    m .: "cdns"
  parseJSON x = fail ("not an object: " ++ show x)

instance FromJSON CDN where
  parseJSON (Object m) = CDN <$>
    m .: "name" <*>
    m .: "urls"
  parseJSON x = fail ("not an object: " ++ show x)

instance FromJSON InfluxDBServer where
  parseJSON (Object m) = InfluxDBServer <$>
    m .: "infhost" <*>
    m .: "infport"
  parseJSON x = fail ("not an object: " ++ show x)

tryAny :: IO a -> IO (Either SomeException a)
tryAny action = withAsync action waitCatch

catchAny :: IO a -> (SomeException -> IO a) -> IO a
catchAny action onE = tryAny action >>= either onE return

myCredentials :: Credentials
myCredentials = Credentials "root" "root"

myDB :: Text 
myDB = "data"

curlFormat :: [Text]
curlFormat = ["-w", "@curl-format.txt"]

curlNull :: [Text]
curlNull = ["-o", "/dev/null"]

curl :: Text -> Sh Text
curl url = run "curl" $ curlNull ++ curlFormat ++ ["-s"] ++ [url]

readValue :: [Text] -> Double
readValue (_:v:xs) = 
  case double v of 
    Right (x,x')  -> x
    Left e        -> error e

extractValues :: [Double] -> HTTPReq
extractValues (v1:v2:v3:v4:v5:v6:v7:v8:[]) = HTTPReq v1 v2 v3 v4 v5 v6 v7 v8

readHTTPReq :: Text -> HTTPReq
readHTTPReq t = extractValues values
  where 
    values = map readValue $ map T.words (T.lines t)

insertToDB :: ToSeriesData r => Config -> Text -> r -> IO ()
insertToDB conf t http = 
   catchAny (post conf myDB $ writeSeries t $ http) (\e -> print e)

treatException e = do
  print e
  errC <- shelly $ lastExitCode 
  return $ Left errC

runCmd :: Text -> IO (Either Int Text)
runCmd l = catchAny (action) (err)
  where 
    action  = (shelly (curl l)) >>= return . Right
    err     = treatException

treatResult :: Config -> Text -> Either Int Text -> IO ()
treatResult c t (Right x) = insertToDB c t        $ readHTTPReq x
treatResult c t (Left e)  = insertToDB c "error"  $ Error e

runCDNTest :: Config -> CDN -> IO ()
runCDNTest cinf cdn = do
  r <- mapM runCmd (urls cdn)
  mapM_ (treatResult cinf (name cdn)) r

loop :: MyConfig -> Config -> IO ()
loop c cinf = forever $ do 
  mapM_ (runCDNTest cinf) (cdns c)
  threadDelay 5000000 -- 5 seconds

doRun :: MyConfig -> IO ()
doRun cfg = do
  myPoolServer  <- newServerPool server []
  myManager     <- newManager defaultManagerSettings
  loop cfg $ Config myCredentials myPoolServer myManager
  where
    settings  = infserver cfg
    server    = Server (infhost settings) (infport settings) False

readMyConfig :: IO MyConfig
readMyConfig =
    either (error . show) id <$>
        decodeFileEither "cfg.yaml"

main :: IO ()
main = do 
  conf <- readMyConfig
  print conf
  doRun conf
