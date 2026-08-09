{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveAnyClass #-}
module Types where

import qualified Servant.API as SApi

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Hashable (Hashable)
import GHC.Generics (Generic)
import Data.HashMap.Strict (HashMap)
import Data.IORef (IORef)
import Control.Concurrent.MVar (MVar)

-- | A token corresponds exactly to one peer and does not repeat between users
newtype AuthToken = AuthToken { tokenText :: Text }
    deriving (Eq, Show)
    deriving newtype (SApi.FromHttpApiData, Hashable, SApi.MimeRender SApi.PlainText)

type Username = Text

-- | A peer name corresponds exactly to one device of a user
newtype PeerName = PeerName { nameText :: Text }
    deriving (Eq, Show)
    deriving newtype (SApi.FromHttpApiData, Hashable, SApi.MimeRender SApi.PlainText, FromJSON, ToJSON)


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
