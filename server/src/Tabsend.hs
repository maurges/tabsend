{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}

module Tabsend where

import Prelude hiding (init)
import Types

import qualified Db
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

import Db (Db)
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
import System.Directory (createDirectoryIfMissing)
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


----- Api Definition -----


data TokenReq = TokenReq
    { username :: !Text
    , password :: !Text
    , peerName :: !PeerName
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data PeersResp = PeersResp
    { peers :: ![PeerInfo]
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data PushTabReq = PushTabReq
    { target :: !PeerName
    , tab :: !TabInfo
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data GrabTabReq = GrabTabReq
    { target :: !PeerName
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


----- Handlers -----


-- | A successful exit from this function means the token is valid
getState :: StateVar -> AuthToken -> ((IORef Peers, IORef InFlight) -> a) -> Handler a
getState s token which =
    liftIO (readMVar s) <&> (.users) <&> HashMap.lookup token >>= \case
        Nothing -> Servant.throwError Servant.err403 -- bad token
        Just (username, _) ->
            liftIO (readMVar s) <&> (.peers) <&> HashMap.lookup username >>= \case
                Nothing -> Servant.throwError err500 -- user data missing
                Just tuple -> pure $ which tuple

-- | Lookup in case we know token must exist. Throws the provided http error if not found
lookupName :: Servant.ServerError -> PeerName -> HashMap PeerName v -> Handler v
lookupName e k m = case HashMap.lookup k m of
    Nothing -> Servant.throwError e
    Just x -> pure x

-- | Lookup in case we know the token and the name exist
lookupPeer :: StateVar -> AuthToken -> PeerName -> Handler AuthToken
lookupPeer s token name = do
    state <- liftIO $ readMVar s
    (username, _selfName) <- case HashMap.lookup token state.users of
        Just x -> pure x
        Nothing -> Servant.throwError err500 -- precondition of token existing doesn't hold
    case HashMap.lookup (username, name) state.tokens of
        Just x -> pure x
        Nothing -> Servant.throwError err500 -- precondition of name existing doesn't hold

getToken :: StateVar -> Db -> TokenReq -> Handler AuthToken
getToken s db req = do
    --liftIO $ putStrLn $ "token | " <> show req

    if req.username /= "admin" || req.password /= "qwe"
    then Servant.throwError Servant.err403
    else pure ()

    tokenBytes <- getStdRandom $ genByteString 32
    let token = AuthToken . Base64.extractBase64 . Base64.encodeBase64 $ tokenBytes

    mbThisState <- liftIO $ modifyMVar s $ \state ->
        case HashMap.lookup req.username state.peers of
            Just u@(peersRef, _) -> do
                -- Check if this peer name is already taken, as the frontend
                -- assumes they are unique. Check is performed on the ref instead
                -- of devices to reduce the candidates; chose peers instead of
                -- inFlight arbitrary, they should be coherent anyway
                peers <- readIORef peersRef
                if req.peerName `HashMap.member` peers
                then pure (state, Nothing)
                else
                    -- Associate this token to the user
                    let pair = (req.username, req.peerName)
                        users = HashMap.insert token pair state.users
                        tokens = HashMap.insert pair token state.tokens
                    in pure (state {users, tokens}, Just u)
            Nothing -> do
                -- Create completely new state vars for this user
                tabs <- newIORef HashMap.empty
                inFlight <- newIORef HashMap.empty
                let u = (tabs, inFlight)
                let peers = HashMap.insert req.username u state.peers
                -- Also associate this token to the user
                let pair = (req.username, req.peerName)
                let users = HashMap.insert token pair state.users
                let tokens = HashMap.insert pair token state.tokens
                pure $ (state {users, peers}, Just u)

    (peers, inFlights) <- case mbThisState of
        Just x -> pure x
        Nothing -> Servant.throwError Servant.err409 -- Conflict, name repeat

    -- Here we assume that tokens for one user never repeat, as they were generated with big entropy
    -- Create new state vars for this token
    peerTabs <- liftIO $ newIORef []
    pushed <- liftIO $ newIORef []
    grabbed <- liftIO $ newIORef []
    atomicModifyIORef_ peers $ HashMap.insert req.peerName peerTabs
    atomicModifyIORef_ inFlights $ HashMap.insert req.peerName (pushed, grabbed)

    liftIO $ Db.addToken db token req.username req.peerName

    pure token

getPeers :: StateVar -> AuthToken -> Handler PeersResp
getPeers s token = do
    --liftIO . putStrLn $ "getPeers"
    (peerMapRef, inFlighMapRef) <- getState s token id
    peerName <- liftIO (readMVar s) <&> (.users) <&> HashMap.lookup token >>= \case
        Nothing -> Servant.throwError err500 -- Incoherent state
        Just (_username, peerName) -> pure peerName

    peerMap <- readIORef peerMapRef
    inFlightMap <- readIORef inFlighMapRef

    let otherPeers = filter ((/=) peerName . fst) . HashMap.toList $ peerMap
    peers <- forM otherPeers $ \(name, tabRef) -> do
        tabs' <- readIORef tabRef
        let inFlight = inFlightMap ! name
        pushed <- readIORef . fst $ inFlight
        grabbed <- readIORef . snd $ inFlight
        let tabs = map (grayOut grabbed) tabs' <> map tabOfPush pushed
        pure $ PeerInfo { name, tabs }

    pure PeersResp { peers }
    where
        tabOfPush t = TabInfo
            { url = t.url
            , identity = t.tabId
            , title = t.url
            , favicon = Nothing
            , inFlight = True
            }
        grayOut grabbed t
            | (GrabbedTab t.identity) `elem` grabbed  = t { inFlight = True }
            | otherwise  = t

pushTab :: StateVar -> Db -> AuthToken -> PushTabReq -> Handler Text
pushTab s db token req = do
    --liftIO . putStrLn $ "pushTab | " <> show req
    let pushed = PushedTab { url = req.tab.url, tabId = req.tab.identity }
    (pushedRef, _grabbed) <-
        getState s token snd
        >>= readIORef
        >>= lookupName
            Servant.err410 -- bad target
            req.target
    peerToken <- lookupPeer s token req.target

    tabs <- atomicModifyIORef pushedRef $ \ts -> pushed : ts
    liftIO $ Db.savePush db peerToken tabs

    pure "ok"

grabTab :: StateVar -> Db -> AuthToken -> GrabTabReq -> Handler Text
grabTab s db token req = do
    --liftIO . putStrLn $ "grabTab | " <> show req
    let grabbed = GrabbedTab { tabId = req.tabId }
    (_pushed, grabbedRef) <-
        getState s token snd
        >>= readIORef
        >>= lookupName
            Servant.err410 -- bad target
            req.target
    peerToken <- lookupPeer s token req.target

    tabs <- atomicModifyIORef grabbedRef $ \ts -> grabbed : ts
    liftIO $ Db.saveGrab db peerToken tabs

    pure "ok"

notifyTabs :: StateVar -> Db -> AuthToken -> NotifyTabsReq -> Handler NotifyTabsResp
notifyTabs s db token req = do
    --liftIO . putStrLn $ "notify | " <> show req
    (peerRef, inFlightRef) <- getState s token id
    peerName <- liftIO (readMVar s) <&> (.users) <&> HashMap.lookup token >>= \case
        Nothing -> Servant.throwError err500 -- Incoherent state
        Just (_username, peerName) -> pure peerName
    -- Set tabs from request
    readIORef peerRef >>= lookupName err500 peerName >>= \tabsRef ->
        atomicModifyIORef_ tabsRef $ const req.tabs
    liftIO $ Db.saveTabs db token req.tabs
    -- Get tabs targeted to this device
    (pushedTabs, grabbedTabs) <- readIORef inFlightRef >>= lookupName err500 peerName
        >>= \(pushedRef, grabbedRef) ->
            liftA2 (,) (readIORef pushedRef) (readIORef grabbedRef)
    pure NotifyTabsResp { pushedTabs, grabbedTabs }

acknowledge :: StateVar -> Db -> AuthToken -> AckReq -> Handler Text
acknowledge s db token req = do
    --liftIO . putStrLn $ "acknowledge | " <> show req
    peerName <- liftIO (readMVar s) <&> (.users) <&> HashMap.lookup token >>= \case
        Nothing -> Servant.throwError Servant.err403 -- bad token
        Just (_username, peerName) -> pure peerName
    (pushedRef, grabbedRef) <-
        getState s token snd
        >>= readIORef
        >>= lookupName err500 peerName
    -- Remove ids in req
    pushed <- atomicModifyIORef pushedRef $
        filter $ \pushed -> not $ pushed.tabId `elem` req.pushedTabs
    grabbed <- atomicModifyIORef grabbedRef $
        filter $ \grabbed -> not $ grabbed.tabId `elem` req.grabbedTabs

    liftIO $ Db.savePush db token pushed
    liftIO $ Db.saveGrab db token grabbed

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
    createDirectoryIfMissing True dbDir
    let settings = Warp.defaultSettings
            & Warp.setPort 31337
            & Warp.setHost "*"
    putStrLn "Server starting.."
    Db.withAppDb dbDir $ \state db -> do
        stateVar <- newMVar state
        Warp.runSettings settings $ app stateVar db
