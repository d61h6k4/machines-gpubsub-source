{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

module Data.Machine.Source.Google.PubSub where

import Control.Concurrent (threadDelay)
import Control.Lens ((&), (?~), (.~), (^.))
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans (MonadTrans(lift))
import Control.Monad.Trans.Resource (MonadResource, ResourceT)
import Data.ByteString (ByteString)
import Data.Machine.Plan (PlanT)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Network.Google (HasEnv)
import Network.Google.Auth.Scope (AllowScopes, HasScope')

import qualified Data.ByteString.Base64 as Base64
import qualified Data.Machine as Machine
import qualified Network.Google as Google
import qualified Network.Google.PubSub as PubSub



fromPubSub :: ( HasScope' s '[ "https://www.googleapis.com/auth/cloud-platform",
                              "https://www.googleapis.com/auth/pubsub" ] ~ 'True
              , AllowScopes s
              , HasEnv s r
              , MonadResource m
              , MonadIO m
              , m ~ ResourceT IO
              ) => r -> Text -> PlanT k ByteString m ()
fromPubSub env subscriptionName =
  lift (getMessages env subscriptionName) >>= mapM Machine.yield >>
  liftIO (threadDelay (3 * 1000000)) >>
  fromPubSub env subscriptionName

getMessages :: ( HasScope' s '[ "https://www.googleapis.com/auth/cloud-platform",
                              "https://www.googleapis.com/auth/pubsub" ] ~ 'True
              , AllowScopes s
              , HasEnv s r
              , MonadResource m
              , MonadIO m
              , m ~ ResourceT IO
              ) => r -> Text -> m [ByteString]
getMessages env subscriptionName = do
  pr <-
    (Google.runGoogle
       env
       (Google.send
          (PubSub.projectsSubscriptionsPull
             (PubSub.pullRequest & PubSub.prReturnImmediately ?~ True &
              PubSub.prMaxMessages ?~
              128)
             subscriptionName)))
  msgsackIds <-
    mapM
      (\message -> do
         msg <-
           case message ^. PubSub.rmMessage of
             Just msg ->
               case Base64.decode (fromMaybe "" (msg ^. PubSub.pmData)) of
                 Left err -> pure ""
                 Right rawMsg -> pure rawMsg
             Nothing -> pure ""
         ackId <- return $ fromMaybe "" (message ^. PubSub.rmAckId)
         return (msg, ackId))
      (pr ^. PubSub.prReceivedMessages)
  let (msgs, ackIds) = unzip msgsackIds
  _ <-
    case ackIds of
      [] -> return ()
      ackIds' ->
        (Google.runGoogle
           env
           (Google.send
              (PubSub.projectsSubscriptionsAcknowledge
                 (PubSub.acknowledgeRequest & PubSub.arAckIds .~ ackIds')
                 subscriptionName))) >>
        return ()
  return msgs
