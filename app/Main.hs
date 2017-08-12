{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Main where

import           Control.Monad (forever, when, void)
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.Async (async, waitAnyCancel)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as ByteString
import           Data.Default.Class (def)
import           Data.Time.Clock (diffUTCTime)
import qualified Network.HTTP2 as HTTP2
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLS
import           Options.Applicative
import           Data.Monoid ((<>))

import Network.HTTP2.Client
import Network.HTTP2.Client.Helpers

type Path = ByteString
type Verb = ByteString

data QueryArgs = QueryArgs {
    _host                    :: !HostName
  , _port                    :: !PortNumber
  , _verb                    :: !Verb
  , _path                    :: !Path
  , _extraHeaders            :: ![(ByteString, ByteString)]
  , _interPingDelay          :: !Int
  , _pingTimeout             :: !Int
  , _interFlowControlUpdates :: !Int
  , _settingsMaxConcurrency  :: !Int
  , _settingsMaxFrameSize       :: !Int
  , _settingsMaxHeaderBlockSize :: !Int
  , _settingsInitialWindowSize  :: !Int
  }

clientArgs :: Parser QueryArgs
clientArgs =
    QueryArgs
        <$> host
        <*> port
        <*> verb
        <*> path
        <*> extraHeaders
        <*> milliseconds "inter-ping-delay-ms" 0
        <*> milliseconds "ping-timeout-ms" 5000
        <*> milliseconds "inter-flow-control-updates-ms" 1000
        <*> concurrency
        <*> frameBytes
        <*> headersBytes
        <*> initialWindowBytes
  where
    bstrOption = fmap ByteString.pack . strOption
    milliseconds what base = fmap (*1000) $ option auto (long what <> value base)
    keyval kv = let (k,v1) = ByteString.break (== ':') kv in (k, ByteString.drop 1 v1)

    host = strOption (long "host" <> value "127.0.0.1")
    path = bstrOption (long "path" <> value "/")
    port = option auto (long "port" <> value 443)
    verb = bstrOption (long "verb" <> value "GET")
    extraHeaders = many (fmap keyval $ bstrOption (short 'H'))
    concurrency = option auto (long "max-concurrency" <> value 100)
    frameBytes = option auto (long "max-frame-size" <> value 1048576)
    headersBytes = option auto (long "max-headers-list-size" <> value 1048576)
    initialWindowBytes = option auto (long "initial-window-size" <> value 10485760)

main :: IO ()
main = execParser opts >>= client
  where
    opts = info (helper <*> clientArgs) (mconcat [
        fullDesc
      , header "http2-client-exe: a CLI HTTP2 client written in Haskell"
      ])

client :: QueryArgs -> IO ()
client QueryArgs{..} = do
    let headersPairs    = [ (":method", _verb)
                          , (":scheme", "https")
                          , (":path", _path)
                          , (":authority", ByteString.pack _host)
                          ] <> _extraHeaders

    let onPushPromise _ stream streamFlowControl _ = void $ forkIO $ do
            putStrLn "push stream started"
            sinkAllPromisedData stream streamFlowControl >>= print
            putStrLn "push stream ended"

    conn <- newHttp2Client _host _port tlsParams onPushPromise

    _ <- forkIO $ forever $ do
            threadDelay _interFlowControlUpdates
            updated <- _updateWindow $ _incomingFlowControl conn
            when updated $ putStrLn "sending flow-control update"

    _settings conn [ (HTTP2.SettingsMaxFrameSize, _settingsMaxFrameSize)
                   , (HTTP2.SettingsMaxConcurrentStreams, _settingsMaxConcurrency)
                   , (HTTP2.SettingsMaxHeaderBlockSize, _settingsMaxHeaderBlockSize)
                   , (HTTP2.SettingsInitialWindowSize, _settingsInitialWindowSize)
                   ]

    _ <- forkIO $ when (_interPingDelay > 0) $ forever $ do
        threadDelay _interPingDelay
        (t0, t1, pingReply) <- ping _pingTimeout "pingpong" conn
        print $ ("ping-reply:" :: String, pingReply, diffUTCTime t1 t0)

    let go = -- forever $ do
            (_startStream conn $ \stream ->
                let initStream = _headers stream headersPairs id
                    handler incomingStreamFlowControl _ = do
                        sendData conn stream HTTP2.setEndStream (ByteString.replicate 1024 'p')
                        _waitHeaders stream >>= print
                        godata
                        -- print "stream ended"
                          where
                            godata = do
                                (fh, x) <- _waitData stream
                                print ("data" :: String, fmap (\bs -> (ByteString.length bs, ByteString.take 64 bs)) x)
                                when (not $ HTTP2.testEndStream (HTTP2.flags fh)) $ do
                                    _ <- _updateWindow $ incomingStreamFlowControl
                                    godata
                in StreamDefinition initStream handler)
    _ <- waitAnyCancel =<< traverse async (replicate 1 go)
    threadDelay 5000000
    _gtfo conn HTTP2.NoError "thx <(=O.O=)>"
    return ()
  where
    tlsParams = TLS.ClientParams {
          TLS.clientWantSessionResume    = Nothing
        , TLS.clientUseMaxFragmentLength = Nothing
        , TLS.clientServerIdentification = ("127.0.0.1", "")
        , TLS.clientUseServerNameIndication = True
        , TLS.clientShared               = def
        , TLS.clientHooks                = def { TLS.onServerCertificate = \_ _ _ _ -> return []
                                               }
        , TLS.clientSupported            = def { TLS.supportedCiphers = TLS.ciphersuite_default }
        , TLS.clientDebug                = def
        }
