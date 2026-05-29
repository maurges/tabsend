{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Main where

import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai as Wai
import qualified Servant.API as SApi
import qualified Servant.Server as SServer

import Data.Function ((&))
import Data.Text (Text)
import Servant.API ((:>), (:<|>) ((:<|>)))
import GHC.Generics (Generic)
import Data.Aeson (FromJSON, ToJSON)
import Data.Data (Proxy (Proxy))
import Control.Monad.IO.Class (liftIO)
import Servant.Server (Handler)

data TokenReq = TokenReq
    { username :: !Text
    , password :: !Text
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data TabInfo = TabInfo
    { url :: !Text
    , identity :: !Text -- ^ For disambiguation in grabbing
    , title :: !Text
    , favicon :: !(Maybe Text)
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)
data PeerInfo = PeerInfo
    { name :: !Text
    , tabs :: ![TabInfo]
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)
data PeersResp = PeersResp
    { peers :: ![PeerInfo]
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)
data PushedTab = PushedTab
    { url :: !Text
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data PushTabReq = PushTabReq
    { target :: !Text -- ^ Peer name
    , tab :: !TabInfo
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data GrabTabReq = GrabTabReq
    { target :: !Text -- ^ Peer name
    , tabId :: !Text
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data NotifyTabsReq = NotifyTabsReq
    { tabs :: ![TabInfo]
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)
data NotifyTabsResp = NotifyTabsResp
    { tabs :: ![PushedTab]
        -- ^ Tabs that other peers pushed to you
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype AuthToken = AuthToken Text
    deriving (Eq, Show)
    deriving newtype (SApi.FromHttpApiData)

-- | A required authentication header
type Authd = SApi.Header' '[SApi.Strict] "X-Tabsend-Auth" AuthToken
-- | Authorize this client
type TokenApi = "token" :> SApi.ReqBody '[SApi.JSON] TokenReq :> SApi.Post '[SApi.PlainText] Text
-- | Get info about all peers
type GetPeersApi = "get-peers" :> Authd :> SApi.Get '[SApi.JSON] PeersResp
-- | Send a tab to a peer
type PushTabApi = "push-tab" :> Authd :> SApi.ReqBody '[SApi.JSON] PushTabReq :> SApi.Post '[SApi.PlainText] Text
-- | Grab a tab from a peer
type GrabTabApi = "grab-tab" :> Authd :> SApi.ReqBody '[SApi.JSON] GrabTabReq :> SApi.Post '[SApi.PlainText] Text
-- | Notify of our tab state
type NotifyTabsApi = "update" :> Authd :> SApi.ReqBody '[SApi.JSON] NotifyTabsReq :> SApi.Post '[SApi.JSON] NotifyTabsResp

type Api = TokenApi :<|> GetPeersApi :<|> PushTabApi :<|> GrabTabApi :<|> NotifyTabsApi
api :: Proxy Api
api = Proxy

getToken :: TokenReq -> Handler Text
getToken req = do
    liftIO $ putStrLn $ "token | " <> show req
    pure "your-cool-token"

getPeers :: Maybe AuthToken -> Handler PeersResp
getPeers _token = do
    liftIO . putStrLn $ "getPeers"
    pure PeersResp
        { peers =
            [ PeerInfo
                { name = "The notebook"
                , tabs = map (\title -> TabInfo { url = "https://morj.men", title, identity = title, favicon = Nothing})
                    ["Search", "Blog", "Tab3", "Tab4", "A very long name that cuts off and looks ugly"]
                }
            , PeerInfo
                { name = "The Phone"
                , tabs = map (\title -> TabInfo { url = "https://morj.men", title, identity = title, favicon = Nothing})
                    ["Not Search", "Not Blog", "Not Tab3", "Not Tab4", "Not A very long name that cuts off and looks ugly"]
                }
            ]
        }

pushTab :: Maybe AuthToken -> PushTabReq -> Handler Text
pushTab _token req = do
    liftIO . putStrLn $ "pushTab | " <> show req
    pure "ok"

grabTab :: Maybe AuthToken -> GrabTabReq -> Handler Text
grabTab _token req = do
    liftIO . putStrLn $ "grabTab | " <> show req
    pure "ok"

notifyTabs :: Maybe AuthToken -> NotifyTabsReq -> Handler NotifyTabsResp
notifyTabs _token req = do
    liftIO . putStrLn $ "notify | " <> show req
    pure NotifyTabsResp { tabs = [] }

apiServer :: SServer.Server Api
apiServer = getToken :<|> getPeers :<|> pushTab :<|> grabTab :<|> notifyTabs

app :: Wai.Application
app = SServer.serve api apiServer

main :: IO ()
main = do
    let settings = Warp.defaultSettings
            & Warp.setPort 31337
            & Warp.setHost "127.0.0.1"
    putStrLn "Server starting.."
    Warp.runSettings settings app
