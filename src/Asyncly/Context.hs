{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE RecordWildCards           #-}

module Asyncly.Context
    ( ChildEvent(..)
    , Loggable
    , Log (..)
    , CtxLog (..)
    , LogEntry (..)
    , Context(..)
    , initContext
    , saveContext
    , restoreContext
    , composeContext
    , setContextMailBox
    , takeContextMailBox
    , Location(..)
    , getLocation
    , setLocation
    )
where

import           Control.Concurrent     (ThreadId)
import           Control.Concurrent.STM (TChan)
import           Control.Exception      (SomeException)
import           Control.Monad.State    (StateT, MonadPlus(..))
import qualified Control.Monad.Trans.State.Lazy as Lazy (get, gets, modify, put)
import           Data.Dynamic           (Typeable)
import           Data.IORef             (IORef)
import           Unsafe.Coerce          (unsafeCoerce)
import           GHC.Prim               (Any)

------------------------------------------------------------------------------
-- Log types
------------------------------------------------------------------------------

-- Logging is done using the 'logged' combinator. It remembers the last value
-- returned by a given computation and replays it the next time the computation
-- is resumed. However this could be problematic if we do not annotate all
-- impure computations. The program can take a different path due to a
-- non-logged computation returning a different value. In that case we may
-- replay a wrong value. To detect this we can use a unique id for each logging
-- site and abort if the id does not match on replay.

-- | Constraint type synonym for a value that can be logged.
type Loggable a = (Show a, Read a)

-- XXX remove the Maybe as we never log Nothing
data LogEntry =
      Executing             -- we are inside this computation, not yet done
    | Result (Maybe String) -- computation done, we have the result to replay
  deriving (Read, Show)

data Log = Log [LogEntry] deriving Show

-- log entries and replay entries
data CtxLog = CtxLog [LogEntry] [LogEntry] deriving (Read, Show)

------------------------------------------------------------------------------
-- Parent child thread communication types
------------------------------------------------------------------------------

data ChildEvent a = ChildDone ThreadId (Maybe SomeException)

------------------------------------------------------------------------------
-- State threaded around the monad
------------------------------------------------------------------------------

-- | Describes the context of a computation.
data Context = Context
  {
    ---------------------------------------------------------------------------
    -- Execution state
    ---------------------------------------------------------------------------

    mailBox       :: Maybe Any  -- untyped,
    -- ^ mailBox to send event data to the child thread

  , currentm     :: Any   -- untyped, the real type is: m a
    -- ^ The 'm' in an 'm >>= f' operation of the monad. This tells us where we
    -- are in the monadic computation at this point.

  , fstack       :: [Any] -- untyped, the real type is: [a -> m b]
    -- ^ The head of the list stores the 'f' corresponding to 'currentm' in an
    -- 'm >>= f' operation of the monad. This is stack because when a
    -- computation has nested binds we need to store the next 'f' for each
    -- layer of nesting.

  -- Logging is done by the 'logged' primitive in this journal only if logsRef
  -- exists.
  , journal :: CtxLog

  -- When we suspend we save the logs in this IORef and exit.
  , logsRef :: Maybe (IORef [Log])
  , location :: Location

    ---------------------------------------------------------------------------
    -- User state
    ---------------------------------------------------------------------------

    -- , mfData      :: M.Map TypeRep Any -- untyped, type coerced
    -- ^ State data accessed with get or put operations

    ---------------------------------------------------------------------------
    -- Thread creation, communication and cleanup
    ---------------------------------------------------------------------------
    -- When a new thread is created the parent records it in the
    -- 'pendingThreads' field and 'threadCredit' is decremented.  When a child
    -- thread is done it sends a done event to the parent on an unbounded
    -- channel and goes away.  Before starting a new thread the parent always
    -- processes the unbounded channel to clear up the pending zombies. This
    -- strategy ensures that the zombie queue will never grow more than the
    -- number of running threads.  Before exiting, the parent thread waits on
    -- the channel until all its children are cleaned up.
    ---------------------------------------------------------------------------

    -- XXX setup a cleanup computation to run rather than passing all these
    -- params.

  , childChannel    :: TChan (ChildEvent Any)
    -- ^ A channel for the immediate children to communicate to us when they
    -- die.  Each thread has its own dedicated channel for its children

    -- We always track the child threads, otherwise the programmer needs to
    -- worry about if some threads may remain hanging because they are stuck in
    -- an infinite loop or a forever blocked IO. Also, it is not clear whether
    -- there is a significant gain by disabling tracking. Instead of using
    -- threadIds we can also keep a count instead, that will allow us to wait
    -- for all children to drain but we cannot kill them.
    --
    -- We need these as IORefs since we need any changes to these to be
    -- reflected back in the calling code that waits for the children.

  , pendingThreads :: IORef [ThreadId]
    -- ^ Active immediate child threads spawned by this thread, modified only
    -- by this thread, therefore atomic modification is not needed.

    -- By default this limit is shared by the current tree of threads. But at
    -- any point the 'threads' primitive can be used to start a new limit for
    -- the computation under that primitive.
    --
    -- Shared across many threads, therefore atomic access is required.
    -- This is incremented by the child thread itelf before it exits.
    --
  , threadCredit   :: IORef Int
    -- ^ How many more threads are allowed to be created?
  } deriving Typeable

initContext
    :: m a
    -> TChan (ChildEvent a)
    -> IORef [ThreadId]
    -> IORef Int
    -> (b -> m a)
    -> Maybe (IORef [Log])
    -> Context
initContext x childChan pending credit finalizer lref =
  Context { mailBox         = Nothing
          , currentm        = unsafeCoerce x
          , fstack          = [unsafeCoerce finalizer]
          , journal         = CtxLog [] []
          , logsRef         = lref
          , location        = Worker
          -- , mfData          = mempty
          , childChannel    = unsafeCoerce childChan
          , pendingThreads  = pending
          , threadCredit    = credit }

------------------------------------------------------------------------------
-- Where is the computation running?
------------------------------------------------------------------------------

-- RemoteNode is used in the Alternative instance. We stop the computation when
-- the location is RemoteNode, we do not execute any alternatives.
--
-- WaitingParent is used in logging. When a parent forks a child and waits for
-- it, it is marked as WaitingParent and we log a "Wait" entry in the log.
--
data Location = Worker | WaitingParent | RemoteNode
  deriving (Typeable, Eq, Show)

getLocation :: Monad m => StateT Context m Location
getLocation = Lazy.gets location

setLocation :: Monad m => Location -> StateT Context m ()
setLocation loc = Lazy.modify $ \Context { .. } -> Context { location = loc, .. }

------------------------------------------------------------------------------
-- Saving and restoring the context of a computation. We perform the monadic
-- computation one step at a time storing the context of where we are in the
-- computation. At any point the remaining computation can be fully recovered
-- from this context.
------------------------------------------------------------------------------

-- Save the 'm' and 'f', in case we migrate to a new thread before the current
-- bind operation completes, we run the operation manually in the new thread
-- using this context.
saveContext :: Monad m => f a -> (a -> f b) -> StateT Context m ()
saveContext m f =
    Lazy.modify $ \Context { fstack = fs, .. } ->
        Context { currentm = unsafeCoerce m
                , fstack   = unsafeCoerce f : fs
                , .. }

-- pop the top function from the continuation stack, create the next closure,
-- set it as the current closure and return it.
restoreContext :: (MonadPlus m1, Monad m) => Maybe a -> StateT Context m (m1 b)
restoreContext x = do
    -- XXX fstack must be non-empty when this is called.
    ctx@Context { fstack = f:fs } <- Lazy.get
    let mnext = maybe mzero (unsafeCoerce f) x
    Lazy.put ctx { currentm = unsafeCoerce mnext, fstack = fs }
    return mnext

-- | We can retrieve a context at any point and resume that context at some
-- later point, upon resumption we start executing again from the same point
-- where the context was retrieved from.
--
-- This function composes the stored context to recover the computation.
--
composeContext :: Monad m => Context -> m a
composeContext Context { currentm     = m
                      , fstack       = fs
                      } =
    unsafeCoerce m >>= composefStack fs

    where

    -- Compose the stack of pending functions in fstack using the bind
    -- operation of the monad. The types don't match. We just coerce the types
    -- here, we know that they actually match.

    -- The last computation is always 'mzero' to stop the whole computation.
    -- Before returning we save the result of the computation in the context.

    -- composefStack :: Monad m => [a -> AsyncT m a] -> a -> AsyncT m b
    composefStack [] _     = error "Bug: this should never be reached"
    composefStack (f:ff) x = (unsafeCoerce f) x >>= composefStack ff

------------------------------------------------------------------------------
-- Mailbox
------------------------------------------------------------------------------

setContextMailBox :: Context -> a -> Context
setContextMailBox ctx mbdata = ctx { mailBox = Just $ unsafeCoerce mbdata }

takeContextMailBox :: Monad m => StateT Context m (Either Context a)
takeContextMailBox = do
      ctx <- Lazy.get
      case mailBox ctx of
        Nothing -> return $ Left ctx
        Just x -> do
            Lazy.put ctx { mailBox = Nothing }
            return $ Right (unsafeCoerce x)