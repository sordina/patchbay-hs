{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BlockArguments #-}

-- From: https://patchbay.pub
--
-- Normal Usage:
--   Shell 1: curl localhost:9000/test1
--   Shell 2: curl -s localhost:9000/test1 -X POST -T /dev/stdin
--
-- Pub-Sub Usage:
--   Shell 1: curl 'localhost:9000/test2?pubsub=true'
--   Shell 2: curl 'localhost:9000/test2?pubsub=true'
--   Shell 3: curl -s 'localhost:9000/test2?pubsub=true' -X POST -T /dev/stdin

module Main where

import Control.Arrow (first, second)
import Control.Monad (join, unless, when)
import Data.Bifunctor (Bifunctor (bimap))
import Data.ByteString (ByteString, drop, isPrefixOf, null)
import Data.ByteString.Builder (byteString)
import Data.CaseInsensitive (CI, mk)
import Data.Map (Map, empty, insert, lookup)
import Data.Maybe (fromMaybe)
import Network.HTTP.Types (Query, status200)
import Network.Wai
  ( Application,
    Request (queryString, rawPathInfo, requestMethod),
    getRequestBodyChunk,
    responseLBS,
    responseStream,
  )
import Network.Wai.Handler.Warp (run)
import Numeric.Natural (Natural)

import qualified Control.Concurrent.STM as STM
import qualified Data.ByteString.Char8 as C8

type Stream a = Q (Maybe a)
type Channels = Map ByteString (Stream ByteString)

data Q a = TQ (STM.TBQueue a) | TC (STM.TChan a)

main :: IO ()
main = do
  Prelude.putStrLn "Server Running on http://localhost:9000/"
  channels <- STM.newTVarIO Data.Map.empty
  run 9000 (handler channels)

handler :: STM.TVar Channels -> Application
handler channels req final = do
  let rpi = rawPathInfo req
  let qs  = queryString req

  Prelude.putStrLn "Path:"
  print rpi

  Prelude.putStrLn "Query:"
  print qs

  let pubsub     = (Just "true" ==) $ join $ Prelude.lookup "pubsub" qs
  let bufferSize = maybe 10 (fromIntegral . fst) (join (Prelude.lookup "buffer" qs) >>= C8.readInt)
  let headers    = mkHeaders qs

  when pubsub do Prelude.putStrLn "Pub-Sub Enabled!"

  channel' <- STM.atomically do
    cs <- STM.readTVar channels
    case Data.Map.lookup rpi cs of
      Just ch -> return ch
      Nothing -> do
        c <- if pubsub
                then newTChan              --- "Unbounded..."
                else newTBQueue bufferSize --- "Blocking..."
        STM.modifyTVar channels (Data.Map.insert rpi c)
        return c

  case requestMethod req of
    "GET"  -> do
      channel <- STM.atomically $ maybeDupQ channel'
      final do
        responseStream status200 (("Transfer-Encoding", "chunked") : headers) $ \send flush ->
          consumeStream channel $ \c -> do
            send (byteString c)
            flush

    "POST" -> do
      let channel = channel'
      consumeBody req $ \b -> STM.atomically $ writeQ channel (Just b)
      STM.atomically do writeQ channel Nothing
      final (responseLBS status200 [] "\n")

    _      -> error "Unsupported HTTP method"

consumeStream :: Stream a -> (a -> IO ()) -> IO ()
consumeStream c f = STM.atomically (readQ c) >>= maybe (return ()) (\x -> f x >> consumeStream c f)

consumeBody :: Request -> (ByteString -> IO ()) -> IO ()
consumeBody req f = do
  b <- getRequestBodyChunk req
  unless (Data.ByteString.null b) do f b >> consumeBody req f

newTBQueue :: Natural -> STM.STM (Q a)
newTBQueue n = TQ <$> STM.newTBQueue n

newTChan :: STM.STM (Q a)
newTChan = TC <$> STM.newTChan

readQ :: Q a -> STM.STM a
readQ (TQ tq) = STM.readTBQueue tq
readQ (TC tc) = STM.readTChan   tc

writeQ :: Q a -> a -> STM.STM ()
writeQ (TQ tq) = STM.writeTBQueue tq
writeQ (TC tc) = STM.writeTChan   tc

maybeDupQ :: Q a -> STM.STM (Q a)
maybeDupQ (TC tc) = TC <$> STM.dupTChan tc
maybeDupQ x = return x

mkHeaders :: Query -> [(CI ByteString, ByteString)]
mkHeaders qs = Prelude.map (bimap (Data.CaseInsensitive.mk . Data.ByteString.drop 7) (fromMaybe "")) $ Prelude.filter (Data.ByteString.isPrefixOf "header-" . fst) qs

