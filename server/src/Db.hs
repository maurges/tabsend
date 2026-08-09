module Db where

import Types

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
import Data.IORef (IORef, newIORef, readIORef)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import GHC.Generics (Generic)
import Servant.API ((:>), (:<|>) ((:<|>)))
import Servant.Server (Handler, err500)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Random (getStdRandom, genByteString)

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

data Pair a b = !a :*: !b
