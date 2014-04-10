module GraphDB.Server where

import GraphDB.Util.Prelude
import qualified Remotion.Server as R
import qualified GraphDB.Service.Protocol as P
import qualified GraphDB.Util.DIOVector as DV
import qualified GraphDB.Action as A
import qualified GraphDB.Model.Union as U


type Action n u = A.Action n (U.Value u) (U.Type u) (U.Index u)

type Command u = Maybe (P.Action u)

type Comm u = (Chan (Command u), MVar (P.Response u))

runCommandProcessor :: (MonadIO m) => Comm u -> Action n u m ()
runCommandProcessor (commandsChan, responseVar) = do
  refs <- liftIO $ DV.new
  let 
    newRef = liftIO . DV.append refs
    resolveRef = liftIO . DV.unsafeLookup refs
    respond = liftIO . putMVar responseVar
    loop = do 
      com <- liftIO $ readChan commandsChan
      case com of
        Nothing -> return ()
        Just ra -> case ra of
          P.NewNode v -> do
            n <- A.newNode v
            r <- newRef n
            respond $ P.Node r
          P.GetValue sr -> do
            sn <- resolveRef sr
            r <- A.getValue sn
            respond $ P.Value r
          _ -> $notImplemented
    in loop

processRequest :: Chan (Bool, Comm u) -> IORef (Maybe (Comm u)) -> P.Request u -> IO (P.Response u)
processRequest transactionsChan stateRef req = do
  -- Initialize the state if needed and determine whether it's the final request.
  state <- readIORef stateRef
  case req of
    P.Start write -> do
      when (isJust state) $ $bug "Transaction state is already filled"
      state <- (,) <$> newChan <*> newEmptyMVar
      writeChan transactionsChan $ (write, state)
      writeIORef stateRef $ Just $ state
      return $ P.Unit
    P.Finish -> do
      case state of
        Nothing -> $bug "No transaction state"
        Just (commandsChan, _) -> do
          writeChan commandsChan Nothing
          writeIORef stateRef $ Nothing
          return $ P.Unit
    P.Action act -> do
      case state of
        Nothing -> $bug "No transaction state"
        Just (commandsChan, responseVar) -> do
          writeChan commandsChan $ Just act
          takeMVar responseVar
 
-- * Serve
-------------------------

-- |
-- A monad transformer for running the server.
-- 
-- Can only be executed inside a 'Session' using 'serve'.
newtype Serve m r = 
  Serve (R.Server m r)
  deriving (Functor, Applicative, Monad, MonadIO, MonadTrans)

instance MonadTransControl Serve where
  newtype StT Serve r = ServeStT (StT R.Server r)
  liftWith runInInner = do
    Serve $ liftWith $ \runServer -> runInInner $ \(Serve s) -> liftM ServeStT $ runServer s
  restoreT inner = do
    Serve $ do
      ServeStT r <- lift $ inner
      restoreT $ return $ r

instance (MonadBase IO m) => MonadBase IO (Serve m) where
  liftBase = Serve . liftBase

instance (MonadBaseControl IO m) => MonadBaseControl IO (Serve m) where
  newtype StM (Serve m) a = ServeStM { unServeStM :: ComposeSt Serve m a }
  liftBaseWith = defaultLiftBaseWith ServeStM
  restoreM = defaultRestoreM unServeStM

-- |
-- Block the calling thread until the server stops (which should never happen).
block :: MonadIO m => Serve m ()
block = Serve $ R.wait
