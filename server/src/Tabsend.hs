{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Tabsend where

import Prelude hiding (init)

import qualified Data.Aeson as Aeson
import qualified Data.Base64.Types as Base64
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.HashMap.Strict as HashMap
import qualified Data.IORef
import qualified Database.LMDB as Lmdb
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Servant
import qualified Servant.API as SApi
import qualified Servant.Server as SServer

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.ByteString (ByteString)
import Data.Data (Proxy (Proxy))
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.HashMap.Strict (HashMap, (!))
import Data.Hashable (Hashable)
import Data.IORef (IORef, newIORef)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import GHC.Generics (Generic)
import Servant.API ((:>), (:<|>) ((:<|>)))
import Servant.Server (Handler, err500)
import System.Environment (getArgs)
import System.Random (getStdRandom, genByteString)


hashMapVals :: HashMap k v -> [v]
hashMapVals = map snd . HashMap.toList

readIORef :: MonadIO m => IORef a -> m a
readIORef = liftIO . Data.IORef.readIORef
atomicModifyIORef_ :: MonadIO m => IORef a -> (a -> a) -> m ()
atomicModifyIORef_ ref f = liftIO $ Data.IORef.atomicModifyIORef' ref (\x -> (f x, ()))
atomicModifyIORef :: MonadIO m => IORef a -> (a -> a) -> m a
atomicModifyIORef ref f = liftIO $ Data.IORef.atomicModifyIORef' ref (\x -> (f x, f x))

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


----- Database access -----

-- We have the following tables:
-- 1. tokens :: AuthToken -> Username
-- 2. names :: AuthToken -> Text -- peer name
-- 3. tabs :: AuthToken -> [TabInfo]
-- 4. pushed :: AuthToken -> [PushedTab]
-- 5. grabbed :: AuthToken -> [GrabbedTab]
-- This uses the fact that the tokens are globally unique

type Db = Lmdb.Env

curIterate :: a -> (a -> (ByteString, ByteString) -> a) -> Lmdb.Cursor s -> IO a
curIterate init f c = Lmdb.cursorFirst c >>= \case
    Nothing -> pure init
    Just tup -> go $! f init tup
    where
        go acc = Lmdb.cursorNext c >>= \case
            Nothing -> pure acc
            Just tup -> go $! f acc tup

withAppDb :: FilePath -> (State -> Db -> IO ()) -> IO ()
withAppDb path run = Lmdb.withEnv path flags initAndRun where
    flags = Lmdb.defaultEnvFlags
        { Lmdb.envMapSize = 100 * 1024 * 1024
        , Lmdb.envMaxDbs = 5
        }
    initAndRun env = do
        (users, names, tabs, pushed, grabbed) <- Lmdb.withWriteTxn env $ \tx -> do
            tokens <- Lmdb.openDbi tx (Just "tokens") True
            tokenMap <- Lmdb.withCursor tx tokens $ curIterate HashMap.empty collectText

            names <- Lmdb.openDbi tx (Just "names") True
            nameMap <- Lmdb.withCursor tx names $ curIterate HashMap.empty collectText

            tabs <- Lmdb.openDbi tx (Just "tabs") True
            tabMap <- Lmdb.withCursor tx tabs $ curIterate HashMap.empty (collectJson @[TabInfo])
            pushed <- Lmdb.openDbi tx (Just "pushed") True
            pushedMap <- Lmdb.withCursor tx pushed $ curIterate HashMap.empty (collectJson @[PushedTab])
            grabbed <- Lmdb.openDbi tx (Just "grabbed") True
            grabbedMap <- Lmdb.withCursor tx grabbed $ curIterate HashMap.empty (collectJson @[GrabbedTab])

            pure (tokenMap, nameMap, tabMap, pushedMap, grabbedMap)

        tabs' <- traverse newIORef tabs
        pushed' <- traverse newIORef pushed
        grabbed' <- traverse newIORef grabbed
        let peers' = collect HashMap.empty users names tabs' pushed' grabbed' (HashMap.toList users)
        peers <- forM peers' $ \(ps, ifs) -> liftA2 (,) (newIORef ps) (newIORef ifs)

        let state = State {users, peers}
        run state env

    collectText :: HashMap AuthToken Text -> (ByteString, ByteString) -> HashMap AuthToken Text
    collectText !m (!k, !v) =
        let !k' = AuthToken $! decodeUtf8 k
            !v' = decodeUtf8 v
        in HashMap.insert k' v' m
    collectJson :: FromJSON a => HashMap AuthToken a -> (ByteString, ByteString) -> HashMap AuthToken a
    collectJson !m (!k, !v) =
        let !k' = AuthToken $! decodeUtf8 k
            !v' = case Aeson.eitherDecodeStrict v of
                    Left e -> error $ "Corrupt database: " <> e
                    Right x -> x
        in HashMap.insert k' v' m

    collect !acc users names tabs pushed grabbed = \case
        [] -> acc
        ((token, username):rest) ->
            let !name = names ! token
                !tabInfo = tabs ! token
                !push = pushed ! token
                !grab = grabbed ! token

                !peer = (name, tabInfo)
                !inFlight = (push, grab)

                !(userPeers, userInFlights) = HashMap.lookupDefault (HashMap.empty, HashMap.empty) username acc
                !userPeers' = HashMap.insert token peer userPeers
                !userInFlights' = HashMap.insert token inFlight userInFlights
                !acc' = HashMap.insert username (userPeers', userInFlights') acc
            in collect acc' users names tabs pushed grabbed rest
    -- TODO TEST THIS SHIT

addToken :: Db -> AuthToken -> Username -> Text -> IO ()
addToken env (AuthToken token') username peerName = Lmdb.withWriteTxn env $ \tx -> do
    let token = encodeUtf8 token'
    tokens <- Lmdb.openDbi tx (Just "tokens") False
    Lmdb.put tx tokens token (encodeUtf8 username)
    names <- Lmdb.openDbi tx (Just "names") False
    Lmdb.put tx names token (encodeUtf8 peerName)
    tabs <- Lmdb.openDbi tx (Just "tabs") False
    Lmdb.put tx tabs token "[]"
    pushed <- Lmdb.openDbi tx (Just "pushed") False
    Lmdb.put tx pushed token "[]"
    grabbed <- Lmdb.openDbi tx (Just "grabbed") False
    Lmdb.put tx grabbed token "[]"

saveTabs :: Db -> AuthToken -> [TabInfo] -> IO ()
saveTabs env (AuthToken token') tabs = Lmdb.withWriteTxn env $ \tx -> do
    let token = encodeUtf8 token'
    let tabsBs = LazyByteString.toStrict $ Aeson.encode tabs
    tabsDb <- Lmdb.openDbi tx (Just "tabs") False
    Lmdb.put tx tabsDb token tabsBs

savePush :: Db -> AuthToken -> [PushedTab] -> IO ()
savePush env (AuthToken token') tabs = Lmdb.withWriteTxn env $ \tx -> do
    let token = encodeUtf8 token'
    let tabsBs = LazyByteString.toStrict $ Aeson.encode tabs
    pushedDb <- Lmdb.openDbi tx (Just "pushed") False
    Lmdb.put tx pushedDb token tabsBs

saveGrab :: Db -> AuthToken -> [GrabbedTab] -> IO ()
saveGrab env (AuthToken token') tabs = Lmdb.withWriteTxn env $ \tx -> do
    let token = encodeUtf8 token'
    let tabsBs = LazyByteString.toStrict $ Aeson.encode tabs
    grabbedDb <- Lmdb.openDbi tx (Just "grabbed") False
    Lmdb.put tx grabbedDb token tabsBs


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

getToken :: StateVar -> Db -> TokenReq -> Handler AuthToken
getToken s db req = do
    liftIO $ putStrLn $ "token | " <> show req

    if req.username /= "admin" || req.password /= "qwe"
    then Servant.throwError Servant.err403
    else pure ()

    tokenBytes <- getStdRandom $ genByteString 32
    let token = AuthToken . Base64.extractBase64 . Base64.encodeBase64 $ tokenBytes

    (peers, inFlights) <- liftIO $ modifyMVar s $ \state ->
        case HashMap.lookup req.username state.peers of
            Just u -> do
                -- Associate this token to the user
                let users = HashMap.insert token req.username state.users
                pure (state {users}, u)
            Nothing -> do
                -- Create completely new state vars for this user
                tabs <- newIORef HashMap.empty
                inFlight <- newIORef HashMap.empty
                let u = (tabs, inFlight)
                let peers = HashMap.insert req.username u state.peers
                -- Also associate this token to the user
                let users = HashMap.insert token req.username state.users
                pure (state {users, peers}, u)

    -- Here we assume that tokens for one user never repeat, as they were generated with big entropy
    -- Create new state vars for this token
    peerTabs <- liftIO $ newIORef []
    let peer = (req.peerName, peerTabs)
    pushed <- liftIO $ newIORef []
    grabbed <- liftIO $ newIORef []
    atomicModifyIORef_ peers $ HashMap.insert token peer
    atomicModifyIORef_ inFlights $ HashMap.insert token (pushed, grabbed)

    liftIO $ addToken db token req.username req.peerName

    pure token

getPeers :: StateVar -> AuthToken -> Handler PeersResp
getPeers s token = do
    liftIO . putStrLn $ "getPeers"
    peerMap <- readIORef =<< getState s token fst
    peers <- forM (hashMapVals peerMap) $ \(name, tabRef) -> do
        tabs <- readIORef tabRef
        pure $ PeerInfo { name, tabs }

    pure PeersResp { peers }

pushTab :: StateVar -> Db -> AuthToken -> PushTabReq -> Handler Text
pushTab s db token req = do
    liftIO . putStrLn $ "pushTab | " <> show req
    let pushed = PushedTab { url = req.tab.url, tabId = req.tab.identity }
    (pushedRef, _grabbed) <-
        getState s token snd
        >>= readIORef
        >>= lookupToken
            Servant.err410 -- bad target
            (AuthToken req.target) -- TODO token smart constructor. Or put in in req struct
    tabs <- atomicModifyIORef pushedRef $ \ts -> pushed : ts

    liftIO $ savePush db token tabs

    pure "ok"

grabTab :: StateVar -> Db -> AuthToken -> GrabTabReq -> Handler Text
grabTab s db token req = do
    liftIO . putStrLn $ "grabTab | " <> show req
    let grabbed = GrabbedTab { tabId = req.tab.identity }
    (_pushed, grabbedRef) <-
        getState s token snd
        >>= readIORef
        >>= lookupToken
            Servant.err410 -- bad target
            (AuthToken req.target) -- TODO token smart constructor. Or put in in req struct
    tabs <- atomicModifyIORef grabbedRef $ \ts -> grabbed : ts

    liftIO $ saveGrab db token tabs

    pure "ok"

notifyTabs :: StateVar -> Db -> AuthToken -> NotifyTabsReq -> Handler NotifyTabsResp
notifyTabs s db token req = do
    liftIO . putStrLn $ "notify | " <> show req
    (peerRef, inFlightRef) <- getState s token id
    -- Set tabs from request
    readIORef peerRef >>= lookupToken err500 token >>= \(_name, tabsRef) ->
        atomicModifyIORef_ tabsRef $ const req.tabs
    liftIO $ saveTabs db token req.tabs
    -- Get tabs targeted to this device
    (pushedTabs, grabbedTabs) <- readIORef inFlightRef >>= lookupToken err500 token
        >>= \(pushedRef, grabbedRef) ->
            liftA2 (,) (readIORef pushedRef) (readIORef grabbedRef)
    pure NotifyTabsResp { pushedTabs, grabbedTabs }

acknowledge :: StateVar -> Db -> AuthToken -> AckReq -> Handler Text
acknowledge s db token req = do
    liftIO . putStrLn $ "acknowledge | " <> show req
    (pushedRef, grabbedRef) <-
        getState s token snd
        >>= readIORef
        >>= lookupToken err500 token
    -- Remove ids in req
    pushed <- atomicModifyIORef pushedRef $
        filter $ \pushed -> not $ pushed.tabId `elem` req.pushedTabs
    grabbed <- atomicModifyIORef grabbedRef $
        filter $ \grabbed -> not $ grabbed.tabId `elem` req.grabbedTabs

    liftIO $ savePush db token pushed
    liftIO $ saveGrab db token grabbed

    pure "ok"

apiServer :: StateVar -> Db -> SServer.Server Api
apiServer s db = getToken s db :<|> getPeers s :<|> pushTab s db :<|> grabTab s db :<|> notifyTabs s db :<|> acknowledge s db

app :: StateVar -> Db -> Wai.Application
app s db = SServer.serve api $ apiServer s db

main :: IO ()
main = do
    dbDir <- getArgs >>= \case
        [] -> pure "./database-dir"
        ["--db", path] -> pure path
        _other -> error "Usage: tabsend-server [--db PATH]"
    let settings = Warp.defaultSettings
            & Warp.setPort 31337
            & Warp.setHost "127.0.0.1"
    putStrLn "Server starting.."
    withAppDb dbDir $ \state db -> do
        stateVar <- newMVar state
        Warp.runSettings settings $ app stateVar db
