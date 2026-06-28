{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Main where

import qualified Data.HashMap.Strict as HashMap
import qualified Data.IORef
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai as Wai
import qualified Servant.API as SApi
import qualified Servant.Server as SServer
import qualified Servant

import Control.Monad.IO.Class (liftIO, MonadIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Data (Proxy (Proxy))
import Data.Hashable (Hashable)
import Data.Function ((&))
import Data.HashMap.Strict (HashMap)
import Data.IORef (IORef, newIORef)
import Data.Text (Text)
import GHC.Generics (Generic)
import Servant.API ((:>), (:<|>) ((:<|>)))
import Servant.Server (Handler, err500)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Data.Functor ((<&>))
import Control.Monad (forM)


hashMapVals :: HashMap k v -> [v]
hashMapVals = map snd . HashMap.toList

readIORef :: MonadIO m => IORef a -> m a
readIORef = liftIO . Data.IORef.readIORef
atomicModifyIORef_ :: MonadIO m => IORef a -> (a -> a) -> m ()
atomicModifyIORef_ ref f = liftIO $ Data.IORef.atomicModifyIORef' ref (\x -> (f x, ()))

-- | Lookup in case we know token must exist. Throws the provided http error if not found
lookupToken :: Servant.ServerError -> AuthToken -> HashMap AuthToken v -> Handler v
lookupToken e k m = case HashMap.lookup k m of
    Nothing -> Servant.throwError e
    Just x -> pure x


----- Api Definition -----


data TokenReq = TokenReq
    { username :: !Text
    , password :: !Text
    , peerName :: !Text
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
    , tabId :: !Text
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)
data GrabbedTab = GrabbedTab
    { tabId :: !Text
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
    , tab :: !TabInfo
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data NotifyTabsReq = NotifyTabsReq
    { tabs :: ![TabInfo]
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)
data NotifyTabsResp = NotifyTabsResp
    { pushedTabs :: ![PushedTab]
        -- ^ Tabs that other peers pushed to you
    , grabbedTabs :: ![GrabbedTab]
        -- ^ Tabs that other peers grabbed from you
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- | Acknowledge of the tab ids from 'NotifyTabsResp'
data AckReq = AckReq
    { pushedTabs :: ![Text]
    , grabbedTabs :: ![Text]
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

newtype AuthToken = AuthToken { tokenText :: Text }
    deriving (Eq, Show)
    deriving newtype (SApi.FromHttpApiData, Hashable, SApi.MimeRender SApi.PlainText)

-- | A required authentication header
-- TODO: return 403 instead of 400
type Authd = SApi.Header' '[SApi.Required, SApi.Strict] "X-Tabsend-Auth" AuthToken
-- | Authorize this client
type TokenApi = "token" :> SApi.ReqBody '[SApi.JSON] TokenReq :> SApi.Post '[SApi.PlainText] AuthToken
-- | Get info about all peers
type GetPeersApi = "get-peers" :> Authd :> SApi.Get '[SApi.JSON] PeersResp
-- | Send a tab to a peer
type PushTabApi = "push-tab" :> Authd :> SApi.ReqBody '[SApi.JSON] PushTabReq :> SApi.Post '[SApi.PlainText] Text
-- | Grab a tab from a peer
type GrabTabApi = "grab-tab" :> Authd :> SApi.ReqBody '[SApi.JSON] GrabTabReq :> SApi.Post '[SApi.PlainText] Text
-- | Notify of our tab state
type NotifyTabsApi = "update" :> Authd :> SApi.ReqBody '[SApi.JSON] NotifyTabsReq :> SApi.Post '[SApi.JSON] NotifyTabsResp
-- | Acknowledge the receipt of pushed tabs
type AcknowledgeApi = "acknowledge" :> Authd :> SApi.ReqBody '[SApi.JSON] AckReq :> SApi.Post '[SApi.PlainText] Text

type Api = TokenApi :<|> GetPeersApi :<|> PushTabApi :<|> GrabTabApi :<|> NotifyTabsApi :<|> AcknowledgeApi
api :: Proxy Api
api = Proxy


----- Data model -----


type Username = Text
-- | A token corresponds exactly to one peer and does not repeat between users
type PeerId = AuthToken

-- | Tabs as this peer has last reported them + peer name
type Peers = HashMap PeerId (Text, IORef [TabInfo])
-- | Tabs pushed and grabbed to this peer and not yet acked by them
type InFlight = HashMap PeerId (IORef [PushedTab], IORef [GrabbedTab])

data State = State
    { users :: !(HashMap AuthToken Username)
    , peers :: !(HashMap Username (IORef Peers, IORef InFlight))
    }
type StateVar = MVar State


----- Handlers -----


-- | A successful exit from this function means the token is valid
getState :: StateVar -> AuthToken -> ((IORef Peers, IORef InFlight) -> a) -> Handler a
getState s token which =
    liftIO (readMVar s) <&> (.users) <&> HashMap.lookup token >>= \case
        Nothing -> Servant.throwError Servant.err403 -- bad token
        Just username ->
            liftIO (readMVar s) <&> (.peers) <&> HashMap.lookup username >>= \case
                Nothing -> Servant.throwError Servant.err500 -- user data missing
                Just tuple -> pure $ which tuple

getToken :: StateVar -> TokenReq -> Handler AuthToken
getToken s req = do
    liftIO $ putStrLn $ "token | " <> show req
    let token = AuthToken "your-cool-token TODO"

    (peers, inFlights) <- liftIO $ modifyMVar s $ \state ->
        case HashMap.lookup req.username state.peers of
            Just u -> pure (state, u)
            Nothing -> do
                tabs <- newIORef HashMap.empty
                inFlight <- newIORef HashMap.empty
                let u = (tabs, inFlight)
                let peers = HashMap.insert req.username u state.peers
                let users = HashMap.insert token req.username state.users
                pure (state {users, peers}, u)

    -- Here we assume that tokens for one user never repeat, as they were generated with big entropy
    peerTabs <- liftIO $ newIORef []
    let peer = (req.peerName, peerTabs)
    pushed <- liftIO $ newIORef []
    grabbed <- liftIO $ newIORef []
    atomicModifyIORef_ peers $ HashMap.insert token peer
    atomicModifyIORef_ inFlights $ HashMap.insert token (pushed, grabbed)

    pure token

getPeers :: StateVar -> AuthToken -> Handler PeersResp
getPeers s token = do
    liftIO . putStrLn $ "getPeers"
    peerMap <- readIORef =<< getState s token fst
    peers <- forM (hashMapVals peerMap) $ \(name, tabRef) -> do
        tabs <- readIORef tabRef
        pure $ PeerInfo { name, tabs }

    pure PeersResp { peers }

pushTab :: StateVar -> AuthToken -> PushTabReq -> Handler Text
pushTab s token req = do
    liftIO . putStrLn $ "pushTab | " <> show req
    let pushed = PushedTab { url = req.tab.url, tabId = req.tab.identity }
    (pushedRef, _grabbed) <-
        getState s token snd
        >>= readIORef
        >>= lookupToken
            Servant.err410 -- bad target
            (AuthToken req.target) -- TODO token smart constructor. Or put in in req struct
    atomicModifyIORef_ pushedRef $ \ts -> pushed : ts

    pure "ok"

grabTab :: StateVar -> AuthToken -> GrabTabReq -> Handler Text
grabTab s token req = do
    liftIO . putStrLn $ "grabTab | " <> show req
    let grabbed = GrabbedTab { tabId = req.tab.identity }
    (_pushed, grabbedRef) <-
        getState s token snd
        >>= readIORef
        >>= lookupToken
            Servant.err410 -- bad target
            (AuthToken req.target) -- TODO token smart constructor. Or put in in req struct
    atomicModifyIORef_ grabbedRef $ \ts -> grabbed : ts
    pure "ok"

notifyTabs :: StateVar -> AuthToken -> NotifyTabsReq -> Handler NotifyTabsResp
notifyTabs s token req = do
    liftIO . putStrLn $ "notify | " <> show req
    (peerRef, inFlightRef) <- getState s token id
    -- Set tabs from request
    readIORef peerRef >>= lookupToken err500 token >>= \(_name, tabsRef) ->
        atomicModifyIORef_ tabsRef $ const req.tabs
    -- Get tabs targeted to this device
    (pushedTabs, grabbedTabs) <- readIORef inFlightRef >>= lookupToken err500 token
        >>= \(pushedRef, grabbedRef) ->
            liftA2 (,) (readIORef pushedRef) (readIORef grabbedRef)
    pure NotifyTabsResp { pushedTabs, grabbedTabs }

acknowledge :: StateVar -> AuthToken -> AckReq -> Handler Text
acknowledge s token req = do
    liftIO . putStrLn $ "acknowledge | " <> show req
    (pushedRef, grabbedRef) <-
        getState s token snd
        >>= readIORef
        >>= lookupToken err500 token
    -- Remove ids in req
    atomicModifyIORef_ pushedRef $
        filter $ \pushed -> not $ pushed.tabId `elem` req.pushedTabs
    atomicModifyIORef_ grabbedRef $
        filter $ \grabbed -> not $ grabbed.tabId `elem` req.grabbedTabs

    pure "ok"

apiServer :: StateVar -> SServer.Server Api
apiServer s = getToken s :<|> getPeers s :<|> pushTab s :<|> grabTab s :<|> notifyTabs s :<|> acknowledge s

app :: StateVar -> Wai.Application
app s = SServer.serve api $ apiServer s

main :: IO ()
main = do
    let settings = Warp.defaultSettings
            & Warp.setPort 31337
            & Warp.setHost "127.0.0.1"
    state <- newMVar State
        { users = HashMap.empty
        , peers = HashMap.empty
        }
    putStrLn "Server starting.."
    Warp.runSettings settings $ app state
