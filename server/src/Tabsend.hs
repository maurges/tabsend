{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}

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

data Pair a b = !a :*: !b


----- Api Definition -----


-- | A token corresponds exactly to one peer and does not repeat between users
newtype AuthToken = AuthToken { tokenText :: Text }
    deriving (Eq, Show)
    deriving newtype (SApi.FromHttpApiData, Hashable, SApi.MimeRender SApi.PlainText)

type Username = Text

-- | A peer name corresponds exactly to one device of a user
newtype PeerName = PeerName { nameText :: Text }
    deriving (Eq, Show)
    deriving newtype (SApi.FromHttpApiData, Hashable, SApi.MimeRender SApi.PlainText, FromJSON, ToJSON)

data TokenReq = TokenReq
    { username :: !Text
    , password :: !Text
    , peerName :: !PeerName
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

data TabInfo = TabInfo
    { url :: !Text
    , identity :: !Text -- ^ For disambiguation in grabbing
    , title :: !Text
    , favicon :: !(Maybe Text)
    , inFlight :: !Bool
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)
data PeerInfo = PeerInfo
    { name :: !PeerName
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


----- Data model -----


-- | Tabs as this peer has last reported them + peer name
type Peers = HashMap PeerName (IORef [TabInfo])
-- | Tabs pushed and grabbed to this peer and not yet acked by them
type InFlight = HashMap PeerName (IORef [PushedTab], IORef [GrabbedTab])

-- Apparently there is no better solution for a bidirectional map than keeping two maps
data State = State
    { users :: !(HashMap AuthToken (Username, PeerName))
    , tokens :: !(HashMap (Username, PeerName) AuthToken)
    , peers :: !(HashMap Username (IORef Peers, IORef InFlight))
    }
type StateVar = MVar State


----- Database access -----

-- We have the following tables:
-- 1. tokens :: AuthToken -> Username
-- 2. names :: AuthToken -> PeerName
-- 3. tabs :: AuthToken -> [TabInfo]
-- 4. pushed :: AuthToken -> [PushedTab]
-- 5. grabbed :: AuthToken -> [GrabbedTab]
-- This uses the fact that the tokens are globally unique. Some other functions
-- assume that the peer name is unique to a user

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
        (users', names, tabs, pushed, grabbed) <- Lmdb.withWriteTxn env $ \tx -> do
            tokens <- Lmdb.openDbi tx (Just "tokens") True
            tokenMap <- Lmdb.withCursor tx tokens $ curIterate HashMap.empty (collectText id)

            names <- Lmdb.openDbi tx (Just "names") True
            nameMap <- Lmdb.withCursor tx names $ curIterate HashMap.empty (collectText PeerName)

            tabs <- Lmdb.openDbi tx (Just "tabs") True
            tabMap <- Lmdb.withCursor tx tabs $ curIterate HashMap.empty (collectJson @[TabInfo])
            pushed <- Lmdb.openDbi tx (Just "pushed") True
            pushedMap <- Lmdb.withCursor tx pushed $ curIterate HashMap.empty (collectJson @[PushedTab])
            grabbed <- Lmdb.openDbi tx (Just "grabbed") True
            grabbedMap <- Lmdb.withCursor tx grabbed $ curIterate HashMap.empty (collectJson @[GrabbedTab])
            putStrLn $ "Collected grabbed: " <> show grabbedMap

            pure (tokenMap, nameMap, tabMap, pushedMap, grabbedMap)

        tabs' <- traverse newIORef tabs
        pushed' <- traverse newIORef pushed
        grabbed' <- traverse newIORef grabbed
        let peers' = collect HashMap.empty users' names tabs' pushed' grabbed' (HashMap.toList users')
        peers <- forM peers' $ \(ps, ifs) -> liftA2 (,) (newIORef ps) (newIORef ifs)
        let (users :*: tokens) = unionUser users' names

        grabsDbg <- traverse (\(_, ifl) -> traverse (readIORef . snd) ifl) peers'
        putStrLn $ "Read grabs: " <> show grabsDbg

        let state = State {users, tokens, peers}
        run state env

    collectText :: (Text -> a) -> HashMap AuthToken a -> (ByteString, ByteString) -> HashMap AuthToken a
    collectText into !m (!k, !v) =
        let !k' = AuthToken $! decodeUtf8 k
            !v' = into $! decodeUtf8 v
        in HashMap.insert k' v' m
    collectJson :: FromJSON a => HashMap AuthToken a -> (ByteString, ByteString) -> HashMap AuthToken a
    collectJson !m (!k, !v) =
        let !k' = AuthToken $! decodeUtf8 k
            !v' = case Aeson.eitherDecodeStrict v of
                    Left e -> error $ "Corrupt database: " <> e
                    Right x -> x
        in HashMap.insert k' v' m

    -- Collect the full peers state from the database records and the list of usernames
    collect !acc users names tabs pushed grabbed = \case
        [] -> acc
        ((token, username):rest) ->
            let !name = names ! token
                !tabInfo = tabs ! token
                !push = pushed ! token
                !grab = grabbed ! token

                !inFlight = (push, grab)

                !(userPeers, userInFlights) = HashMap.lookupDefault (HashMap.empty, HashMap.empty) username acc
                !userPeers' = HashMap.insert name tabInfo userPeers
                !userInFlights' = HashMap.insert name inFlight userInFlights
                !acc' = HashMap.insert username (userPeers', userInFlights') acc
            in collect acc' users names tabs pushed grabbed rest

    -- Union the tokens and names table into the 'users' and 'tokens' state
    unionUser users names =
        let step (users :*: tokens) token username =
                let !peerName = names ! token
                    !p = (username, peerName)
                    !users' = HashMap.insert token p users
                    !tokens' = HashMap.insert p token tokens
                in users' :*: tokens'
        in HashMap.foldlWithKey' step (HashMap.empty :*: HashMap.empty) users

addToken :: Db -> AuthToken -> Username -> PeerName -> IO ()
addToken env (AuthToken token') username peerName = Lmdb.withWriteTxn env $ \tx -> do
    let token = encodeUtf8 token'
    tokens <- Lmdb.openDbi tx (Just "tokens") False
    Lmdb.put tx tokens token (encodeUtf8 username)
    names <- Lmdb.openDbi tx (Just "names") False
    Lmdb.put tx names token (encodeUtf8 peerName.nameText)
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

    liftIO $ addToken db token req.username req.peerName

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
    liftIO $ savePush db peerToken tabs

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
    liftIO $ saveGrab db peerToken tabs

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
    liftIO $ saveTabs db token req.tabs
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
    createDirectoryIfMissing True dbDir
    let settings = Warp.defaultSettings
            & Warp.setPort 31337
            & Warp.setHost "*"
    putStrLn "Server starting.."
    withAppDb dbDir $ \state db -> do
        stateVar <- newMVar state
        Warp.runSettings settings $ app stateVar db
