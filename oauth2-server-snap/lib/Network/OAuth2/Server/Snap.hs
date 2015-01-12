{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- | Description: Run an OAuth2 server as a Snaplet.
module Network.OAuth2.Server.Snap where

import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as B
import Data.Monoid
import qualified Data.Text.Encoding as T
import Data.Time.Clock
import Snap

import Network.OAuth2.Server

-- | Snaplet state for OAuth2 server.
data OAuth2 m b = OAuth2 { oauth2Configuration :: OAuth2Server m }

-- | Implement an 'OAuth2Server' configuration in Snap.
initOAuth2Server
    :: OAuth2Server IO
    -> SnapletInit b (OAuth2 IO b)
initOAuth2Server cfg = makeSnaplet "oauth2" "" Nothing $ do
    addRoutes [ ("authorize", authorizeEndpoint)
              , ("token", tokenEndpoint)
              , ("check", checkEndpoint)
              ]
    return $ OAuth2 cfg

-- | OAuth2 authorization endpoint
--
-- This endpoint is "used by the client to obtain authorization from the
-- resource owner via user-agent redirection."
--
-- http://tools.ietf.org/html/rfc6749#section-3.1
authorizeEndpoint
    :: Handler b (OAuth2 IO b) ()
authorizeEndpoint = writeText "U AM U?"

-- | OAuth2 token endpoint
--
-- This endpoint is "used by the client to exchange an authorization grant for
-- an access token, typically with client authentication"
--
-- http://tools.ietf.org/html/rfc6749#section-3.2
tokenEndpoint
    :: Handler b (OAuth2 IO b) ()
tokenEndpoint = do
    grant_type' <- getParam "grant_type"
    request <- case grant_type' of
        Just gt' -> do
            let gt = grantType . T.decodeUtf8 $ gt'
            case gt of
                -- Resource Owner Password Credentials Grant
                GrantPassword -> do
                    client_id <- fmap T.decodeUtf8 <$> getParam "client_id"
                    client_secret <- fmap T.decodeUtf8 <$> getParam "client_secret"
                    username <- fmap T.decodeUtf8 <$> getParam "username" >>=
                        maybe (missingParam "username") return
                    password <- fmap T.decodeUtf8 <$> getParam "password" >>=
                        maybe (missingParam "password") return
                    return RequestPassword
                        { requestClientID = client_id
                        , requestClientSecret = client_secret
                        , requestUsername = username
                        , requestPassword = password
                        , requestScope = Nothing }
                -- Client Credentials Grant
                GrantClient -> do
                    client_id' <- getParam "client_id"
                    client_id <- case client_id' of
                        Just client_id -> return $ T.decodeUtf8 client_id
                        _ -> missingParam "client_id"
                    client_secret' <- getParam "client_secret"
                    client_secret <- case client_secret' of
                        Just client_secret -> return $ T.decodeUtf8 client_secret
                        _ -> missingParam "client_secret"
                    return RequestClient
                        { requestClientIDReq = client_id
                        , requestClientSecretReq = client_secret
                        , requestScope = Nothing }
                _ -> oauth2Error $ UnsupportedGrantType "This grant_type is not supported."
        _ -> missingParam "grant_type"
    OAuth2 cfg <- get
    valid <- liftIO $ oauth2CheckCredentials cfg request
    if valid
        then createAndServeToken request
        else oauth2Error $ InvalidRequest "Cannot issue a token with those credentials."

-- | Send an 'OAuth2Error' response about a missing request parameter.
--
-- This terminates request handling.
missingParam
    :: MonadSnap m
    => BS.ByteString
    -> m a
missingParam p = oauth2Error . InvalidRequest . T.decodeUtf8 $
    "Missing parameter \"" <> p <> "\""

-- | Send an 'OAuth2Error' to the client and terminate the request.
--
-- The response is formatted as specified in RFC 6749 section 5.2:
--
-- http://tools.ietf.org/html/rfc6749#section-5.2
oauth2Error
    :: (MonadSnap m)
    => OAuth2Error
    -> m a
oauth2Error err = do
    modifyResponse $ setResponseStatus 400 "Bad Request"
                   . setContentType "application/json"
    writeBS . B.toStrict . encode $ err
    r <- getResponse
    finishWith r

-- | Create an access token and send it to the client.
createAndServeToken
    :: AccessRequest
    -> Handler b (OAuth2 IO b) ()
createAndServeToken request = do
    OAuth2 Configuration{..} <- get
    grant <- createGrant request
    liftIO $ tokenStoreSave oauth2Store grant
    serveToken $ grantResponse grant

-- | Send an access token to the client.
serveToken
    :: AccessResponse
    -> Handler b (OAuth2 m b) ()
serveToken token = do
    modifyResponse $ setContentType "application/json"
    writeBS . B.toStrict . encode $ token

-- | Endpoint: /check
--
-- Check that the supplied token is valid for the specified scope.
--
-- TODO: Move the actual check of this operation into the oauth2-server
-- package.
checkEndpoint
    :: Handler b (OAuth2 IO b) ()
checkEndpoint = do
    OAuth2 Configuration{..} <- get
    -- Get the token and scope parameters.
    token <- fmap (Token . T.decodeUtf8) <$> getParam "token" >>=
        maybe (missingParam "token") return
    _scope <- fmap T.decodeUtf8 <$> getParam "scope" >>=
        maybe (missingParam "scope") return
    -- Load the grant.
    tokenGrant <- liftIO $ tokenStoreLoad oauth2Store token
    -- Check the token is valid.
    res <- case tokenGrant of
        Nothing -> return False
        Just TokenGrant{..} -> do
            t <- liftIO getCurrentTime
            return $ t > grantExpires
    if res
        then do
            modifyResponse $ setResponseStatus 200 "OK"
            r <- getResponse
            finishWith r
        else do
            modifyResponse $ setResponseStatus 401 "Invalid Token"
            r <- getResponse
            finishWith r
