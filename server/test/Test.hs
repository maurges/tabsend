{-# LANGUAGE OverloadedLists #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

import qualified Tabsend
import Data.HashMap.Strict ((!))
import Path (fromAbsDir)
import Test.Syd (describe, it, sydTest, shouldBe)
import Test.Syd.Path (tempDirSpec)
import Data.IORef (readIORef)

main = sydTest $ do
    describe "database" $ tempDirSpec "tabsend-db" $ do

        it "saves tokens" $ \tempDir' -> do
            let tempDir = fromAbsDir tempDir'
            let [t1, t2, t3] = map Tabsend.AuthToken ["token1", "token2", "token3"]
            Tabsend.withAppDb tempDir $ \_state db -> do
                Tabsend.addToken db t1 "user1" "device1"
                Tabsend.addToken db t2 "user1" "device2"
                Tabsend.addToken db t3 "user2" "device3"
            Tabsend.withAppDb tempDir $ \state _db -> do
                state.users `shouldBe` [(t1, "user1"), (t2, "user1"), (t3, "user2")]

        it "saves tabs" $ \tempDir' -> do
            let tempDir = fromAbsDir tempDir'
            let [t1, t2] = map Tabsend.AuthToken ["token1", "token2"]
            let tabs1 = [Tabsend.TabInfo "u1" "i1" "t1" Nothing, Tabsend.TabInfo "u2" "i2" "t2" Nothing]
            let tabs2 = [Tabsend.TabInfo "u3" "i3" "t3" (Just "fav")]
            Tabsend.withAppDb tempDir $ \_state db -> do
                Tabsend.addToken db t1 "user1" "device1"
                Tabsend.addToken db t2 "user1" "device2"
                Tabsend.saveTabs db t1 tabs2 -- save a dummy value, overwrite it later
                Tabsend.saveTabs db t2 tabs2
                Tabsend.saveTabs db t1 tabs1
            Tabsend.withAppDb tempDir $ \state _db -> do
                user1 <- readIORef . fst $ state.peers ! "user1"
                tabs1' <- readIORef . snd $ user1 ! t1
                tabs2' <- readIORef . snd $ user1 ! t2
                tabs1' `shouldBe` tabs1
                tabs2' `shouldBe` tabs2

        it "saves inFlight" $ \tempDir' -> do
            let tempDir = fromAbsDir tempDir'
            let [t1, t2] = map Tabsend.AuthToken ["token1", "token2"]
            let pushedTabs1 = [Tabsend.PushedTab "u1" "i1", Tabsend.PushedTab "u2" "i2"]
            let pushedTabs2 = [Tabsend.PushedTab "u3" "i3"]
            let grabbedTabs1 = [Tabsend.GrabbedTab "i1", Tabsend.GrabbedTab "i2"]
            let grabbedTabs2 = [Tabsend.GrabbedTab "i3"]
            Tabsend.withAppDb tempDir $ \_state db -> do
                Tabsend.addToken db t1 "user1" "device1"
                Tabsend.addToken db t2 "user1" "device2"

                Tabsend.savePush db t1 pushedTabs2 -- save a dummy value, overwrite it later
                Tabsend.savePush db t2 pushedTabs2
                Tabsend.savePush db t1 pushedTabs1

                Tabsend.saveGrab db t1 grabbedTabs2 -- save a dummy value, overwrite it later
                Tabsend.saveGrab db t2 grabbedTabs2
                Tabsend.saveGrab db t1 grabbedTabs1
            Tabsend.withAppDb tempDir $ \state _db -> do
                user1 <- readIORef . snd $ state.peers ! "user1"
                pushedTabs1' <- readIORef . fst $ user1 ! t1
                pushedTabs2' <- readIORef . fst $ user1 ! t2
                pushedTabs1' `shouldBe` pushedTabs1
                pushedTabs2' `shouldBe` pushedTabs2

                grabbedTabs1' <- readIORef . snd $ user1 ! t1
                grabbedTabs2' <- readIORef . snd $ user1 ! t2
                grabbedTabs1' `shouldBe` grabbedTabs1
                grabbedTabs2' `shouldBe` grabbedTabs2
