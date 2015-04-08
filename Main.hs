{-# LANGUAGE OverloadedStrings #-}

import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Exception
import Control.Monad      (forM_, forever)

import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Read 

import Data.IORef

import Database.InfluxDB hiding((.:))
import Database.InfluxDB.Encode

import Network.HTTP.Client

import qualified Data.Vector as V

import Prelude hiding (FilePath)

import Shelly

import Data.Yaml

default (Text)

data Event = Event Int 
  deriving (Show)

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

instance ToSeriesData Event where
  toSeriesColumns _ = V.fromList ["count"]
  toSeriesPoints (Event i) = V.fromList [toValue i]

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

myServer :: Server
myServer =  Server "127.0.0.1" 8086 False

poolServer :: IO (IORef ServerPool) 
poolServer = newServerPool myServer []

myCredentials :: Credentials
myCredentials = Credentials "root" "root"

myDB :: Text 
myDB = "data"

myEvent :: Int -> IO Event
myEvent i = return $ Event i

curlFormat :: [Text]
curlFormat = ["-w", "@curl-format.txt"]

curlNull :: [Text]
curlNull = ["-o", "/dev/null"]

curl :: Text -> Sh Text
-- curl url = run "curl" ["-w", "@curl-format.txt", "-o",  "/dev/null", "-s", url]
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

--insertToDB :: ToSeriesData r => Text -> r -> IO ()
insertToDB :: ToSeriesData r => Config -> Text -> r -> IO ()
insertToDB conf t http = do 
  post conf myDB $ writeSeries t $ http

--insertToDB t http = do 
--  myPoolServer <- poolServer
--  myManager <- newManager defaultManagerSettings
--  let config = Config myCredentials myPoolServer myManager
--      series = writeSeries t $ http
--  post config myDB series

runCmd :: Text -> Sh (Either Int Text)
runCmd l = do
  c <- curl l
  e <- lastExitCode
  let r = case e of
            0 -> Right c
            _ -> Left e
  return r

treatResult :: Config -> Text -> Either Int Text -> IO ()
treatResult c t (Right x) = insertToDB c t        $ readHTTPReq x
treatResult c t (Left e)  = insertToDB c "error"  $ Error e

--request :: Control.Monad.IO.Class.MonadIO m => Text -> m (Either Int Text)
request url = shelly $ errExit False $ runCmd url

-- runCMDTest :: InfluxDBServer -> CDN -> IO [Either Int Text]
runCDNTest cinf cdn = do
  r <- mapM request (urls cdn)
  -- return $ r
  mapM_ (treatResult cinf (name cdn)) r

loop c cinf = forever $ do 
  -- mapM (runCDNTest cinf) (cdns c)
  mapM_ (runCDNTest cinf) (cdns c)
  threadDelay 5000000 -- 5 seconds

doRun cfg = do
  let settings    = infserver cfg
      server      = Server (infhost settings) (infport settings) False
  myPoolServer  <- newServerPool server []
  myManager     <- newManager defaultManagerSettings
  loop cfg $ Config myCredentials myPoolServer myManager

--main = forever $ do
--  r <- shelly $ errExit False $ runCmd "http://pool.img.aptoide.com/imgs/d/9/8/d980fe54d4d0bda21091af8ca6cee334_cat_graphic.png"
--  case r of 
--    Right x -> insertToDB "test"  $ readHTTPReq x
--    Left e  -> insertToDB "error" $ Error e
--  threadDelay 5000000 -- 5 seconds

readMyConfig :: IO MyConfig
readMyConfig =
    either (error . show) id <$>
        decodeFileEither "cfg.yaml"

main = do 
  conf <- readMyConfig
  print conf
  doRun conf
