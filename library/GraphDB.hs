-- |
-- The API is based on multiple monads and monad transformers:
-- 
-- * 'Session'. 
-- A class of monad transformers, 
-- which execute transactions and run the server.
-- 
-- * 'Read' and 'Write' transactions.
-- Monads,
-- which execute granular updates or reads on the database with ACID guarantees.
-- 
-- The library provides three types of sessions:
-- 
-- * A 'Nonpersistent.NonpersistentSession' over an in-memory data structure.
-- 
-- * A 'Persistent.PersistentSession' over an in-memory data structure. 
-- 
-- * A 'Client.ClientSession', 
-- which is a networking interface for communication with server.
-- 
-- The API of this library is free of exceptions and resource management.
-- This is achieved using monad transformers.
-- All the IO failures are encoded in the results of monad transformers.
-- All the resources are acquired and released automatically.
module GraphDB
(
  -- * Sessions
  Session,
  -- ** Nonpersistent
  Nonpersistent.NonpersistentSession,
  runNonpersistentSession,
  -- ** Persistent
  Persistent.PersistentSession,
  PersistentSettings,
  Persistent.StoragePath,
  Persistent.PersistenceBuffering,
  Persistent.PersistenceFailure(..),
  runPersistentSession,
  -- ** Client
  Client.ClientSession,
  ClientSettings,
  ClientModelVersion,
  URL(..),
  RemotionClient.Credentials,
  ClientFailure(..),
  runClientSession,
  -- * Transactions
  Read,
  Write,
  ReadOrWrite,
  Node,
  read,
  write,
  -- ** Operations
  newNode,
  getValue,
  setValue,
  getRoot,
  getTargets,
  addTarget,
  removeTarget,
  remove,
  getStats,
  -- * Modeling
  Model.Edge(..),
  Graph.Setup,
  Model.PolyValue,
  Model.PolyIndex,
  Macros.deriveSetup,
  -- * Server
  ServerSettings,
  ServerModelVersion,
  ListeningMode(..),
  RemotionServer.Authenticate,
  RemotionServer.Timeout,
  RemotionServer.MaxClients,
  RemotionServer.Log,
  ServerFailure(..),
  serve,
  -- ** Monad-transformer
  Server.Serve,
  Server.block,

)
where

import GraphDB.Util.Prelude hiding (write, read, Write, Read, block)
import qualified GraphDB.Model as Model
import qualified GraphDB.Macros as Macros
import qualified GraphDB.Action as Action
import qualified GraphDB.Graph as Graph
import qualified GraphDB.Client as Client
import qualified GraphDB.Persistent as Persistent
import qualified GraphDB.Nonpersistent as Nonpersistent
import qualified GraphDB.Server as Server
import qualified Remotion.Client as RemotionClient
import qualified Remotion.Server as RemotionServer



-- * Sessions
-------------------------

-- |
-- A class of monad transformers, 
-- which can execute transactions and run a server.
class Session s where
  type SessionNode s u
  runTransaction :: 
    (MonadIO m, MonadBaseControl IO m, Graph.Setup u) => 
    Bool -> SessionAction s u m r -> s u m r

type Action n u = Action.Action n (Graph.Value u) (Graph.Index u)
type SessionAction s u = Action (SessionNode s u) u



-- ** Nonpersistent
-------------------------

instance Session Nonpersistent.NonpersistentSession where
  type SessionNode Nonpersistent.NonpersistentSession u = Nonpersistent.Node u
  runTransaction w a = Nonpersistent.runTransaction w $ Nonpersistent.runAction $ a

-- |
-- Run a nonpersistent session, 
-- while providing an initial value for the root node.
runNonpersistentSession :: (Model.PolyValue u u, MonadIO m) => u -> Nonpersistent.NonpersistentSession u m r -> m r
runNonpersistentSession v s = do
  n <- liftIO $ Graph.new $ Model.packValue $ v
  Nonpersistent.runSession n s



-- ** Persistent
-------------------------

instance Session Persistent.PersistentSession where
  type SessionNode Persistent.PersistentSession u = Persistent.Node u
  runTransaction w a = Persistent.runTransaction w $ Persistent.runAction $ a

-- |
-- Settings of a persistent session.
-- 
-- The first parameter is an initial value for the root node.
-- It will only be used if the graph has not been previously persisted,
-- i.e. on the first run of the DB.
type PersistentSettings v = (v, Persistent.StoragePath, Persistent.PersistenceBuffering)

-- |
-- Run a persistent session with settings.
runPersistentSession :: 
  (MonadIO m, MonadBaseControl IO m, Model.PolyValue u u) => 
  PersistentSettings u -> Persistent.PersistentSession u m r -> m (Either Persistent.PersistenceFailure r)
runPersistentSession (v, p, e) s = do
  Persistent.runSession (Model.packValue $ v, p, e) s



-- ** Client
-------------------------

instance Session Client.ClientSession where
  type SessionNode Client.ClientSession u = Int
  runTransaction w a = Client.runTransaction w $ Client.runAction $ a

-- | 
-- Settings of a client session.
type ClientSettings = (ClientModelVersion, URL)

-- |
-- Version of the graph model, 
-- which is used to check the client and server compatibility during handshake.
type ClientModelVersion = Int

-- |
-- Location of the server.
data URL =
  -- | Path to the socket-file.
  URL_Socket FilePath |
  -- | Host name, port and credentials.
  URL_Host Text Int RemotionClient.Credentials

data ClientFailure =
  -- |
  -- Unable to connect to the provided url.
  UnreachableURL |
  -- |
  -- The server has too many connections already.
  -- It's suggested to retry later.
  ServerIsBusy |
  -- |
  -- Incorrect credentials.
  Unauthenticated |
  -- |
  -- Either the connection got interrupted for some reason or
  -- a communication timeout has been reached.
  ConnectionFailure |
  -- | 
  -- Either the graph model does not match the one on the server or
  -- the server runs an incompatible version of \"graph-db\".
  Incompatible |
  -- | 
  -- The server was unable to deserialize the request.
  -- This is only expected to happen when the same 'ClientModelVersion' 
  -- was used for incompatible models.
  CorruptRequest Text
  deriving (Show, Eq)

-- |
-- Run a client session with settings.
runClientSession :: 
  (MonadIO m, MonadBaseControl IO m, Graph.Setup u) =>
  ClientSettings -> Client.ClientSession u m r -> m (Either ClientFailure r)
runClientSession (v, url) (ses) = 
  fmap (fmapL adaptRemotionFailure) $ Client.runSession (rv, rurl) $ ses
  where
    adaptRemotionFailure = \case
      RemotionClient.UnreachableURL -> UnreachableURL
      RemotionClient.ServerIsBusy -> ServerIsBusy
      RemotionClient.ProtocolVersionMismatch _ _ -> Incompatible
      RemotionClient.UserProtocolSignatureMismatch _ _ -> Incompatible
      RemotionClient.Unauthenticated -> Unauthenticated
      RemotionClient.ConnectionInterrupted -> ConnectionFailure
      RemotionClient.TimeoutReached _ -> ConnectionFailure
      RemotionClient.CorruptRequest t -> CorruptRequest t
    rv = fromString $ show $ v
    rurl = case url of
      URL_Socket f -> RemotionClient.Socket f
      URL_Host n p c -> RemotionClient.Host n p c

-- * Transactions
-------------------------

-- | 
-- A read-only transaction. 
-- 
-- Gets executed concurrently.
newtype Read s u t r = 
  Read (SessionAction s u Identity r)
  deriving (Functor, Applicative, Monad)

-- | 
-- A write and read transaction.
-- 
-- Does not allow concurrency, 
-- so all concurrent transactions are put on hold for the time of its execution.
newtype Write s u t r = 
  Write (SessionAction s u Identity r)
  deriving (Functor, Applicative, Monad)

-- |
-- Transactions of this type can be composed with both 'Read' and 'Write'.
type ReadOrWrite s u t r = 
  forall tr. (Transaction tr, Monad (tr s u t), Applicative (tr s u t)) => 
  tr s u t r

class Transaction tr where 
  liftAction :: SessionAction s u Identity r -> tr s u t r
instance Transaction Read where liftAction = Read
instance Transaction Write where liftAction = Write

-- | 
-- A transaction-local reference to an actual node of the graph.
-- 
-- @t@ is the so called \"state thread\".
-- It is an uninstantiated type-variable,
-- which makes it impossible to return a node from transaction,
-- when it is executed using 'write' or 'read'.
-- Much inspired by the implementation of 'ST'.
newtype Node s u t v = Node (SessionNode s u)

-- |
-- Execute a read-only transaction.
-- Gets executed concurrently.
-- 
-- Concerning the \"forall\" part refer to 'Node'.
read :: (Graph.Setup u, Session s, MonadBaseControl IO m, MonadIO m) => (forall t. Read s u t r) -> s u m r
read (Read a) = runTransaction False $ hoistFreeT (return . runIdentity) $ a

-- |
-- Execute a writing transaction.
-- 
-- Does not allow concurrent transactions, 
-- so all concurrent transactions are put on hold for the time of execution.
-- 
-- Concerning the \"forall\" part refer to 'Node'.
write :: (Graph.Setup u, Session s, MonadBaseControl IO m, MonadIO m) => (forall t. Write s u t r) -> s u m r
write (Write a) = runTransaction True $ hoistFreeT (return . runIdentity) $ a



-- ** Operations
-------------------------

-- |
-- Create a new node. 
-- 
-- This node won't get stored if you don't insert at least a single edge 
-- from another stored node to it.
newNode :: (Model.PolyValue u v) => v -> Write s u t (Node s u t v)
newNode v = fmap Node $ liftAction $ Action.newNode $ Model.packValue v

-- | 
-- Get a value of the node.
getValue :: (Model.PolyValue u v) => Node s u t v -> ReadOrWrite s u t v
getValue (Node n) = 
  fmap (fromMaybe ($bug "Unexpected packed value") . Model.unpackValue) $ 
  liftAction $ Action.getValue n

-- | 
-- Replace the value of the specified node.
setValue :: (Model.PolyValue u v) => Node s u t v -> v -> Write s u t ()
setValue (Node n) v = Write $ Action.setValue n (Model.packValue v)

-- |
-- Get the root node.
getRoot :: ReadOrWrite s u t (Node s u t u)
getRoot = fmap Node $ liftAction $ Action.getRoot

-- |
-- Get target nodes reachable by the provided index.
getTargets :: 
  (Model.PolyIndex u i, i ~ Model.Index v v') => 
  Node s u t v -> i -> ReadOrWrite s u t [Node s u t v']
getTargets (Node n) i = 
  fmap (map Node) $ liftAction $ Action.getTargets n $ Model.packIndex i

-- |
-- Add a link to the provided target node /v'/, 
-- while automatically generating all the indexes.
-- 
-- The result signals, whether the operation has actually been performed.
-- If the node is already there it will return 'False'.
addTarget :: (Model.Edge v v') => Node s u t v -> Node s u t v' -> Write s u t ()
addTarget (Node s) (Node t) = Write $ Action.addTarget s t

-- |
-- Remove the target node /v'/ and all its indexes from the source node /v/.
-- 
-- The result signals, whether the operation has actually been performed.
-- If the node is not found it will return 'False'.
removeTarget :: (Model.Edge v v') => Node s u t v -> Node s u t v' -> Write s u t ()
removeTarget (Node s) (Node t) = Write $ Action.removeTarget s t

-- |
-- Remove a node and all edges to it from other nodes.
remove :: Node s u t v -> Write s u t ()
remove (Node n) = Write $ Action.remove n

-- |
-- Count the total amounts of distinct nodes, edges and indexes in the graph.
-- 
-- Requires a traversal of the whole graph, so beware.
getStats :: ReadOrWrite s u t (Int, Int, Int)
getStats = liftAction $ Action.getStats



-- * Server
-------------------------

-- |
-- Settings of server.
type ServerSettings = 
  (
    ServerModelVersion, 
    ListeningMode, 
    RemotionServer.Timeout,
    RemotionServer.MaxClients,
    RemotionServer.Log
  )

-- |
-- Version of the graph model, 
-- which is used to check the client and server compatibility during handshake.
type ServerModelVersion = Int

-- | Defines how to listen for connections.
data ListeningMode =
  -- | 
  -- Listen on a port with an authentication function.
  ListeningMode_Host Int RemotionServer.Authenticate |
  -- | 
  -- Listen on a socket file.
  -- Since sockets are local no authentication is needed.
  -- Works only on UNIX systems.
  ListeningMode_Socket FilePath

-- | 
-- A server failure.
data ServerFailure =
  ListeningSocketIsBusy

-- |
-- Run a server on this session.
serve :: 
  (Session s, MonadIO (s u m), MonadBaseControl IO (s u m), MonadTrans (s u),
   MonadBaseControl IO m, MonadIO m, Graph.Setup u) => 
  ServerSettings -> Server.Serve m r -> s u m (Either ServerFailure r)
serve (v, lm, to, mc, log) (Server.Serve rs) = do
  transactionsChan <- liftIO $ newChan
  let
    ups = fromString $ show $ v
    pur = Server.processRequest transactionsChan
    settings = (ups, convertListeningMode lm, to, mc, log, pur)
  r <- RemotionServer.run settings $ do
    r <- liftWith $ \runRS -> do
      worker <- asyncRethrowing $ forever $ do
        (w, comm) <- liftIO $ readChan transactionsChan
        asyncRethrowing $ runTransaction w $ Server.runCommandProcessor comm
      r <- lift $ runRS $ rs
      cancel worker
      return r
    restoreT $ return r
  return $ fmapL adaptRemotionFailure $ r
  where
    adaptRemotionFailure = \case
      RemotionServer.ListeningSocketIsBusy -> ListeningSocketIsBusy
    convertListeningMode = \case
      ListeningMode_Host p a -> RemotionServer.Host p a
      ListeningMode_Socket f -> RemotionServer.Socket f
