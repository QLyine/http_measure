{-# LANGUAGE OverloadedStrings #-}

import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync, waitCatch)
import Control.Exception
import Control.Monad      (forM_, forever, replicateM)
import Control.Monad.IO.Class
import Control.Monad.Reader

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
import System.Random (randomRIO)

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
  , interval  :: Int
  , cdns      :: [CDN]
  }deriving (Show)

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
    m .: "interval"  <*>
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

numberOfElements :: Int
numberOfElements = 10

pick :: [b] -> IO b
pick xs = randomRIO (0, (length xs - 1)) >>= return . (xs !!)

pickN :: Int -> [b] -> IO [b]
pickN n l = replicateM n $ pick l

tryAny :: IO a -> IO (Either SomeException a)
tryAny action = withAsync action waitCatch

catchAny :: IO a -> (SomeException -> IO a) -> IO a
catchAny action onE = tryAny action >>= either onE return

myCredentials :: Credentials
myCredentials = Credentials "root" "root"

myCred :: IO Credentials
myCred = return $ Credentials "root" "root"

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
  putStrLn $ "ERROR >>= " ++ (show e)
  errC <- shelly $ lastExitCode 
  return $ Left errC

runCmd :: Text -> IO (Either Int Text)
runCmd l = catchAny (action) (err)
  where 
    action  = (shelly (curl l)) >>= return . Right
    err     = treatException

treatResult :: MyConfig -> Config -> Text -> Either Int Text -> IO ()
treatResult mc c t (Right x) = insertToDB c table $ readHTTPReq x
  where table = T.concat [(continent mc), "_", t]
treatResult mc c t (Left e)  = insertToDB c table $ Error e
  where table = T.concat [(continent mc), "_", "error"]

runCDNTest :: MyConfig -> Config -> CDN -> IO ()
runCDNTest c cinf cdn = do
  sample <- pickN numberOfElements $ urls cdn
  r <- mapM runCmd sampln e
  mapM_ (treatResult c cinf (name cdn)) r

loop :: MyConfig -> Config -> IO ()
loop c cinf = forever $ do 
  mapM_ (runCDNTest c cinf) (cdns c)
  threadDelay ( (interval c) * 1000000 ) -- 5 seconds

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

getContinent :: ReaderT MyConfig IO Text
getContinent = do 
  a <- ask 
  return $ continent a

getServer :: ReaderT MyConfig IO InfluxDBServer
getServer = do 
  a <- ask
  return $ infserver a

loopp cif = do 
  forever $ do
    print cif 

-- buildConfig :: MonadIO m => m Credentials -> m IORef ServerPool -> m newManager -> m Config
buildConfig cred s m = do
  ccred <- cred
  ss    <- s
  mm    <- m
  return $ Config ccred ss mm

doS :: ReaderT MyConfig IO ()
doS = do 
  settings      <- getServer 
  server        <- return $ Server (infhost settings) (infport settings) False
  myPoolServer  <- return $ newServerPool server []
  myManager     <- return $ newManager defaultManagerSettings
  config        <- return $ (liftM3 Config) myCred myPoolServer myManager 
  liftIO $ print "r"

main :: IO ()
main = do 
  conf <- readMyConfig
  -- runReaderT doS conf
  print conf
  doRun conf
