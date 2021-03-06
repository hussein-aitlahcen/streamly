{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE UndecidableInstances      #-} -- XXX

-- |
-- Module      : Streamly.Core
-- Copyright   : (c) 2017 Harendra Kumar
--
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
--
module Streamly.Core
    (
      MonadParallel
    , MonadAsync      -- deprecated

    -- * Streams
    , Stream (..)

    -- * Construction
    , singleton
    , cons
    , repeat
    , nil

    -- * Semigroup Style Composition
    , splice
    , cosplice
    , coparallel
    , parallel

    -- * Alternative
    , alt

    -- * Transformers
    , withLocal
    , withCatchError

    -- * Concurrent Stream Vars (SVars)
    , SVar
    , SVarSched (..)
    , SVarTag (..)
    , SVarStyle (..)
    , newEmptySVar
    , newStreamVar1
    , newStreamVar2
    , joinStreamVar2
    , fromStreamVar
    , toStreamVar
    )
where

import           Control.Concurrent          (ThreadId, forkIO,
                                              myThreadId, threadDelay)
import           Control.Concurrent.MVar     (MVar, newEmptyMVar, tryTakeMVar,
                                              tryPutMVar, takeMVar)
import           Control.Exception           (SomeException (..))
import qualified Control.Exception.Lifted    as EL
import           Control.Monad               (when)
import           Control.Monad.Catch         (MonadThrow, throwM)
import           Control.Monad.Error.Class   (MonadError(..))
import           Control.Monad.IO.Class      (MonadIO(..))
import           Control.Monad.Reader.Class  (MonadReader(..))
import           Control.Monad.Trans.Class   (MonadTrans (lift))
import           Control.Monad.Trans.Control (MonadBaseControl, liftBaseWith)
import           Data.Atomics                (atomicModifyIORefCAS,
                                              atomicModifyIORefCAS_)
import           Data.Concurrent.Queue.MichaelScott (LinkedQueue, newQ, pushL,
                                                     tryPopR, nullQ)
import           Data.Functor                (void)
import           Data.IORef                  (IORef, modifyIORef, newIORef,
                                              readIORef)
import           Data.Maybe                  (isNothing)
import           Data.Semigroup              (Semigroup(..))
import           Data.Set                    (Set)
import qualified Data.Set                    as S
import           Prelude                     hiding (repeat)

------------------------------------------------------------------------------
-- Parent child thread communication type
------------------------------------------------------------------------------

-- | Events that a child thread may send to a parent thread.
data ChildEvent a =
      ChildYield a
    | ChildStop ThreadId (Maybe SomeException)

------------------------------------------------------------------------------
-- State threaded around the monad for thread management
------------------------------------------------------------------------------

-- | Conjunction is used for monadic/product style composition. Disjunction is
-- used for fold/sum style composition. We need to distinguish the two types of
-- SVars so that the scheduling of the two is independent.
data SVarTag = Conjunction | Disjunction deriving Eq

-- | For fairly interleaved parallel composition the sched policy is FIFO
-- whereas for left biased parallel composition it is LIFO.
data SVarSched = LIFO | FIFO deriving Eq

-- | Identify the type of the SVar. Two computations using the same style can
-- be scheduled on the same SVar.
data SVarStyle = SVarStyle SVarTag SVarSched deriving Eq

-- | An SVar or a Stream Var is a conduit to the output from multiple streams
-- running concurrently and asynchronously. An SVar can be thought of as an
-- asynchronous IO handle. We can write any number of streams to an SVar in a
-- non-blocking manner and then read them back at any time at any pace.  The
-- SVar would run the streams asynchronously and accumulate results. An SVar
-- may not really execute the stream completely and accumulate all the results.
-- However, it ensures that the reader can read the results at whatever paces
-- it wants to read. The SVar monitors and adapts to the consumer's pace.
--
-- An SVar is a mini scheduler, it has an associated runqueue that holds the
-- stream tasks to be picked and run by a pool of worker threads. It has an
-- associated output queue where the output stream elements are placed by the
-- worker threads. A doorBell is used by the worker threads to intimate the
-- consumer thread about availability of new results in the output queue. More
-- workers are added to the SVar by 'fromStreamVar' on demand if the output
-- produced is not keeping pace with the consumer. On bounded SVars, workers
-- block on the output queue to provide throttling of the producer  when the
-- consumer is not pulling fast enough.  The number of workers may even get
-- reduced depending on the consuming pace.
--
-- New work is enqueued either at the time of creation of the SVar or as a
-- result of executing the parallel combinators i.e. '<|' and '<|>' when the
-- already enqueued computations get evaluated. See 'joinStreamVar2'.
--
data SVar m a =
       SVar { outputQueue    :: IORef [ChildEvent a]
            , doorBell       :: MVar Bool -- wakeup mechanism for outQ
            , enqueue        :: Stream m a -> IO ()
            , runqueue       :: m ()
            , runningThreads :: IORef (Set ThreadId)
            , queueEmpty     :: m Bool
            , svarStyle      :: SVarStyle
            }

------------------------------------------------------------------------------
-- The stream type
------------------------------------------------------------------------------

-- | The type 'Stream m a' represents a monadic stream of values of type 'a'
-- constructed using actions in monad 'm'. It uses stop, singleton and yield
-- continuations equivalent to the following direct style type:
--
-- data Stream m a = Stop | Singleton a | Yield a (Stream m a)
--
-- To facilitate parallel composition we maintain a local state in an SVar that
-- is shared across and is used for synchronization of the streams being
-- composed.
--
-- The singleton case can be expressed in terms of stop and yield but we have
-- it as a separate case to optimize composition operations for streams with
-- single element.  We build singleton streams in the implementation of 'pure'
-- for Applicative and Monad, and in 'lift' for MonadTrans.
--
newtype Stream m a =
    Stream {
        runStream :: forall r.
               Maybe (SVar m a)          -- local state
            -> m r                       -- stop
            -> (a -> m r)                -- singleton
            -> (a -> Stream m a -> m r)  -- yield
            -> m r
    }

nil :: Stream m a
nil = Stream $ \_ stp _ _ -> stp

{-# INLINE singleton #-}
singleton :: a -> Stream m a
singleton a = Stream $ \_ _ single _ -> single a

cons :: a -> Stream m a -> Stream m a
cons a r = Stream $ \_ _ _ yld -> yld a r

repeat :: a -> Stream m a
repeat a = let x = cons a x in x

------------------------------------------------------------------------------
-- Semigroup
------------------------------------------------------------------------------

-- | Concatenates two streams sequentially i.e. the first stream is
-- exhausted completely before yielding any element from the second stream.
splice :: Stream m a -> Stream m a -> Stream m a
splice m1 m2 = go m1
    where
    go (Stream m) = Stream $ \_ stp sng yld ->
            let stop      = (runStream m2) Nothing stp sng yld
                single a  = yld a m2
                yield a r = yld a (go r)
            in m Nothing stop single yield

instance Semigroup (Stream m a) where
    (<>) = splice

------------------------------------------------------------------------------
-- Monoid
------------------------------------------------------------------------------

instance Monoid (Stream m a) where
    mempty = nil
    mappend = (<>)

------------------------------------------------------------------------------
-- Interleave
------------------------------------------------------------------------------

cosplice :: Stream m a -> Stream m a -> Stream m a
cosplice m1 m2 = Stream $ \_ stp sng yld -> do
    let stop      = (runStream m2) Nothing stp sng yld
        single a  = yld a m2
        yield a r = yld a (cosplice m2 r)
    (runStream m1) Nothing stop single yield

------------------------------------------------------------------------------
-- Spawning threads and collecting result in streamed fashion
------------------------------------------------------------------------------

-- | A monad that can perform concurrent or parallel IO operations. Streams
-- that can be composed concurrently require the underlying monad to be
-- 'MonadParallel'.
type MonadParallel m = (MonadIO m, MonadBaseControl IO m, MonadThrow m)

{-# DEPRECATED MonadAsync "Please use MonadParallel instead." #-}
type MonadAsync m = MonadParallel m

{-# INLINE doFork #-}
doFork :: MonadBaseControl IO m
    => m ()
    -> (SomeException -> m ())
    -> m ThreadId
doFork action exHandler =
    EL.mask $ \restore ->
        liftBaseWith $ \runInIO -> forkIO $ do
            -- XXX test the exception handling
            _ <- runInIO $ EL.catch (restore action) exHandler
            -- XXX restore state here?
            return ()

-- XXX exception safety of all atomic/MVar operations

{-# INLINE send #-}
send :: MonadIO m => SVar m a -> ChildEvent a -> m ()
send sv msg = liftIO $ do
    atomicModifyIORefCAS_ (outputQueue sv) $ \es -> msg : es
    -- XXX need a memory barrier? The wake up must happen only after the
    -- store has finished otherwise we can have lost wakeup problems.
    void $ tryPutMVar (doorBell sv) True

{-# INLINE sendStop #-}
sendStop :: MonadIO m => SVar m a -> m ()
sendStop sv = liftIO myThreadId >>= \tid -> send sv (ChildStop tid Nothing)

-- Note: Left associated compositions can grow this queue to a large size
{-# INLINE enqueueLIFO #-}
enqueueLIFO :: IORef [Stream m a] -> Stream m a -> IO ()
enqueueLIFO q m = atomicModifyIORefCAS_ q $ \ ms -> m : ms

runqueueLIFO :: MonadIO m => SVar m a -> IORef [Stream m a] -> m ()
runqueueLIFO sv q = run

    where

    run = do
        work <- dequeue
        case work of
            Nothing -> sendStop sv
            Just m -> (runStream m) (Just sv) run single yield

    sendit a = send sv (ChildYield a)
    single a = sendit a >> run
    yield a r = sendit a >> (runStream r) (Just sv) run single yield

    dequeue = liftIO $ atomicModifyIORefCAS q $ \case
                [] -> ([], Nothing)
                x : xs -> (xs, Just x)

{-# INLINE enqueueFIFO #-}
enqueueFIFO :: LinkedQueue (Stream m a) -> Stream m a -> IO ()
enqueueFIFO = pushL

runqueueFIFO :: MonadIO m => SVar m a -> LinkedQueue (Stream m a) -> m ()
runqueueFIFO sv q = run

    where

    run = do
        work <- dequeue
        case work of
            Nothing -> sendStop sv
            Just m -> (runStream m) (Just sv) run single yield

    dequeue = liftIO $ tryPopR q
    sendit a = send sv (ChildYield a)
    single a = sendit a >> run
    yield a r = sendit a >> liftIO (enqueueFIFO q r) >> run

-- Thread tracking is needed for two reasons:
--
-- 1) Killing threads on exceptions. Threads may not be allowed to go away by
-- themselves because they may run for significant times before going away or
-- worse they may be stuck in IO and never go away.
--
-- 2) To know when all threads are done.

{-# NOINLINE addThread #-}
addThread :: MonadIO m => SVar m a -> ThreadId -> m ()
addThread sv tid =
    liftIO $ modifyIORef (runningThreads sv) (S.insert tid)

{-# INLINE delThread #-}
delThread :: MonadIO m => SVar m a -> ThreadId -> m ()
delThread sv tid =
    liftIO $ modifyIORef (runningThreads sv) $ (\s -> S.delete tid s)

{-# INLINE allThreadsDone #-}
allThreadsDone :: MonadIO m => SVar m a -> m Bool
allThreadsDone sv = liftIO $ S.null <$> readIORef (runningThreads sv)

{-# NOINLINE handleChildException #-}
handleChildException :: MonadIO m => SVar m a -> SomeException -> m ()
handleChildException sv e = do
    tid <- liftIO myThreadId
    send sv (ChildStop tid (Just e))

{-# NOINLINE pushWorker #-}
pushWorker :: MonadParallel m => SVar m a -> m ()
pushWorker sv =
    doFork (runqueue sv) (handleChildException sv) >>= addThread sv

-- XXX When the queue is LIFO we can put a limit on the number of dispatches.
-- Also, if a worker blocks on the output queue we can decide if we want to
-- block or make it go away entirely, depending on the number of workers and
-- the type of the queue.
{-# INLINE sendWorkerWait #-}
sendWorkerWait :: MonadParallel m => SVar m a -> m ()
sendWorkerWait sv = do
    case svarStyle sv of
        SVarStyle _ LIFO -> liftIO $ threadDelay 200
        SVarStyle _ FIFO -> liftIO $ threadDelay 0

    output <- liftIO $ readIORef (outputQueue sv)
    when (null output) $ do
        done <- queueEmpty sv
        if not done
        then pushWorker sv >> sendWorkerWait sv
        else void (liftIO $ takeMVar (doorBell sv))

-- | Pull a stream from an SVar.
{-# NOINLINE fromStreamVar #-}
fromStreamVar :: MonadParallel m => SVar m a -> Stream m a
fromStreamVar sv = Stream $ \_ stp sng yld -> do
    -- XXX if reading the IORef is costly we can use a flag in the SVar to
    -- indicate we are done.
    done <- allThreadsDone sv
    if done
    then stp
    else do
        res <- liftIO $ tryTakeMVar (doorBell sv)
        when (isNothing res) $ sendWorkerWait sv
        list <- liftIO $ atomicModifyIORefCAS (outputQueue sv) $ \x -> ([], x)
        -- To avoid lock overhead we read all events at once instead of reading
        -- one at a time. We just reverse the list to process the events in the
        -- order they arrived. Maybe we can use a queue instead?
        (runStream $ processEvents (reverse list)) Nothing stp sng yld

    where

    handleException e tid = do
        delThread sv tid
        -- XXX implement kill async exception handling
        -- liftIO $ readIORef (runningThreads sv) >>= mapM_ killThread
        throwM e

    {-# INLINE processEvents #-}
    processEvents [] = Stream $ \_ stp sng yld -> do
        done <- allThreadsDone sv
        if not done
        then (runStream (fromStreamVar sv)) Nothing stp sng yld
        else stp

    processEvents (ev : es) = Stream $ \_ stp sng yld -> do
        let continue = (runStream (processEvents es)) Nothing stp sng yld
            yield a  = yld a (processEvents es)

        case ev of
            ChildYield a -> yield a
            ChildStop tid e ->
                case e of
                    Nothing -> delThread sv tid >> continue
                    Just ex -> handleException ex tid

getFifoSVar :: MonadIO m => SVarStyle -> IO (SVar m a)
getFifoSVar ctype = do
    outQ    <- newIORef []
    outQMv  <- newEmptyMVar
    running <- newIORef S.empty
    q       <- newQ
    let sv =
            SVar { outputQueue       = outQ
                    , doorBell       = outQMv
                    , runningThreads = running
                    , runqueue       = runqueueFIFO sv q
                    , enqueue        = pushL q
                    , queueEmpty     = liftIO $ nullQ q
                    , svarStyle       = ctype
                    }
     in return sv

getLifoSVar :: MonadIO m => SVarStyle -> IO (SVar m a)
getLifoSVar ctype = do
    outQ    <- newIORef []
    outQMv  <- newEmptyMVar
    running <- newIORef S.empty
    q <- newIORef []
    let checkEmpty = null <$> liftIO (readIORef q)
    let sv =
            SVar { outputQueue       = outQ
                    , doorBell       = outQMv
                    , runningThreads = running
                    , runqueue       = runqueueLIFO sv q
                    , enqueue        = enqueueLIFO q
                    , queueEmpty     = checkEmpty
                    , svarStyle      = ctype
                    }
     in return sv

-- | Create a new empty SVar.
newEmptySVar :: MonadParallel m => SVarStyle -> m (SVar m a)
newEmptySVar style = do
    liftIO $
        case style of
            SVarStyle _ FIFO -> getFifoSVar style
            SVarStyle _ LIFO -> getLifoSVar style

-- | Create a new SVar and enqueue one stream computation on it.
newStreamVar1 :: MonadParallel m => SVarStyle -> Stream m a -> m (SVar m a)
newStreamVar1 style m = do
    sv <- newEmptySVar style
    -- Note: We must have all the work on the queue before sending the
    -- pushworker, otherwise the pushworker may exit before we even get a
    -- chance to push.
    liftIO $ (enqueue sv) m
    pushWorker sv
    return sv

-- | Create a new SVar and enqueue two stream computations on it.
newStreamVar2 :: MonadParallel m
    => SVarStyle -> Stream m a -> Stream m a -> m (SVar m a)
newStreamVar2 style m1 m2 = do
    -- Note: We must have all the work on the queue before sending the
    -- pushworker, otherwise the pushworker may exit before we even get a
    -- chance to push.
    sv <- liftIO $
        case style of
            SVarStyle _ FIFO -> do
                c <- getFifoSVar style
                (enqueue c) m1 >> (enqueue c) m2
                return c
            SVarStyle _ LIFO -> do
                c <- getLifoSVar style
                (enqueue c) m2 >> (enqueue c) m1
                return c
    pushWorker sv
    return sv

-- | Write a stream to an 'SVar' in a non-blocking manner. The stream can then
-- be read back from the SVar using 'fromSVar'.
toStreamVar :: MonadParallel m => SVar m a -> Stream m a -> m ()
toStreamVar sv m = do
    liftIO $ (enqueue sv) m
    done <- allThreadsDone sv
    -- XXX there may be a race here unless we are running in the consumer
    -- thread. This is safe only when called from the consumer thread or when
    -- no consumer is present.
    when done $ pushWorker sv

------------------------------------------------------------------------------
-- Running streams concurrently
------------------------------------------------------------------------------

-- Concurrency rate control. Our objective is to create more threads on demand
-- if the consumer is running faster than us. As soon as we encounter an
-- Alternative composition we create a push pull pair of threads. We use a
-- channel for communication between the consumer pulling from the channel and
-- the producer who is pushing to the channel. The producer creates more threads
-- if no output is seen on the channel, that is the consumer is running faster.
-- However this mechanism can be problematic if the initial production latency
-- is high, we may end up creating too many threads. So we need some way to
-- monitor and use the latency as well.
--
-- TBD We may run computations at the lower level of the composition tree
-- serially even if they are composed using a parallel combinator. We can use
-- <> in place of <| and <=> in place of <|>. If we find that a parallel
-- channel immediately above a computation becomes empty we can switch to
-- parallelizing the computation.  For that we can use a state flag to fork the
-- rest of the computation at any point of time inside the Monad bind operation
-- if the consumer is running at a faster speed.
--
-- TBD the alternative composition allows us to dispatch a chunkSize of only 1.
-- If we have to dispatch in arbitrary chunksizes we will need to compose the
-- parallel actions using a data constructor (Free Alternative) instead so that
-- we can divide it in chunks of arbitrary size before dispatching. If the stream
-- is composed of hierarchically composed grains of different sizes then we can
-- always switch to a desired granularity depending on the consumer speed.
--
-- TBD for pure work (when we are not in the IO monad) we can divide it into
-- just the number of CPUs.

{-# NOINLINE withNewSVar2 #-}
withNewSVar2 :: MonadParallel m
    => SVarStyle -> Stream m a -> Stream m a -> Stream m a
withNewSVar2 style m1 m2 = Stream $ \_ stp sng yld -> do
    sv <- newStreamVar2 style m1 m2
    (runStream (fromStreamVar sv)) Nothing stp sng yld

-- | Join two computations on the currently running 'SVar' queue for concurrent
-- execution. The 'SVarStyle' required by the current composition context is
-- passed as one of the parameters. If the style does not match with the style
-- of the current 'SVar' we create a new 'SVar' and schedule the computations
-- on that. The newly created SVar joins as one of the computations on the
-- current SVar queue.
--
-- When we are using parallel composition, an SVar is passed around as a state
-- variable. We try to schedule a new parallel computation on the SVar passed
-- to us. The first time, when no SVar exists, a new SVar is created.
-- Subsequently, 'joinStreamVar2' may get called when a computation already
-- scheduled on the SVar is further evaluated. For example, when (a \<|> b) is
-- evaluated it calls a 'joinStreamVar2' to put 'a' and 'b' on the current scheduler
-- queue.  However, if the scheduling and composition style of the new
-- computation being scheduled is different than the style of the current SVar,
-- then we create a new SVar and schedule it on that.
--
-- For example:
--
-- * (x \<|> y) \<|> (t \<|> u) -- all of them get scheduled on the same SVar
-- * (x \<|> y) \<|> (t \<| u) -- @t@ and @u@ get scheduled on a new child SVar
--   because of the scheduling policy change.
-- * if we 'adapt' a stream of type 'AsyncT' to a stream of type
--   'ParallelT', we create a new SVar at the transitioning bind.
-- * When the stream is switching from disjunctive composition to conjunctive
--   composition and vice-versa we create a new SVar to isolate the scheduling
--   of the two.
--
{-# INLINE joinStreamVar2 #-}
joinStreamVar2 :: MonadParallel m
    => SVarStyle -> Stream m a -> Stream m a -> Stream m a
joinStreamVar2 style m1 m2 = Stream $ \svr stp sng yld ->
    case svr of
        Just sv | svarStyle sv == style ->
            liftIO ((enqueue sv) m2) >> (runStream m1) svr stp sng yld
        _ -> (runStream (withNewSVar2 style m1 m2)) Nothing stp sng yld

------------------------------------------------------------------------------
-- Semigroup and Monoid style compositions for parallel actions
------------------------------------------------------------------------------

{-# INLINE coparallel #-}
coparallel :: MonadParallel m => Stream m a -> Stream m a -> Stream m a
coparallel = joinStreamVar2 (SVarStyle Disjunction LIFO)

{-# INLINE parallel #-}
parallel :: MonadParallel m => Stream m a -> Stream m a -> Stream m a
parallel = joinStreamVar2 (SVarStyle Disjunction FIFO)

-------------------------------------------------------------------------------
-- Functor instace is the same for all types
-------------------------------------------------------------------------------

instance Monad m => Functor (Stream m) where
    fmap f m = Stream $ \_ stp sng yld ->
        let single    = sng . f
            yield a r = yld (f a) (fmap f r)
        in (runStream m) Nothing stp single yield

------------------------------------------------------------------------------
-- Alternative & MonadPlus
------------------------------------------------------------------------------

alt :: Stream m a -> Stream m a -> Stream m a
alt m1 m2 = Stream $ \_ stp sng yld ->
    let stop  = runStream m2 Nothing stp sng yld
    in runStream m1 Nothing stop sng yld

-------------------------------------------------------------------------------
-- Transformers
-------------------------------------------------------------------------------

instance MonadTrans Stream where
    lift mx = Stream $ \_ _ single _ -> mx >>= single

withLocal :: MonadReader r m => (r -> r) -> Stream m a -> Stream m a
withLocal f m =
    Stream $ \svr stp sng yld ->
        let single = local f . sng
            yield a r = local f $ yld a (withLocal f r)
        in (runStream m) svr (local f stp) single yield

-- XXX handle and test cross thread state transfer
withCatchError
    :: MonadError e m
    => Stream m a -> (e -> Stream m a) -> Stream m a
withCatchError m h =
    Stream $ \svr stp sng yld ->
        let run x = runStream x svr stp sng yield
            handle r = r `catchError` \e -> run $ h e
            yield a r = yld a (withCatchError r h)
        in handle $ run m
