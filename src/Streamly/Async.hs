{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE UndecidableInstances       #-}

-- |
-- Module      : Streamly.Streams
-- Copyright   : (c) 2017 Harendra Kumar
--
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
--
module Streamly.Async
    (
      Streaming (..)
    , MonadAsync

    -- * SVars
    , adapt
    , asyncly
    , parallely
    , zippingAsync

    -- * Running Streams
    , runAsyncT
    , runParallelT
    , runZipAsync

    -- * Zipping
    , zipWith
    , zipAsyncWith

    -- * Stream Styles
    , AsyncT
    , ParallelT
    , ZipAsync

    -- * Adapter
    , async

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

    -- * Concurrent Streams
    , parAlt
    , parLeft

    , (<|)

    )
where
import           Control.Applicative                (Alternative (..))
import           Control.Concurrent                 (ThreadId, forkIO,
                                                     myThreadId, threadDelay)
import           Control.Concurrent.MVar            (MVar, newEmptyMVar,
                                                     takeMVar, tryPutMVar,
                                                     tryTakeMVar)
import           Control.Exception                  (SomeException (..))
import qualified Control.Exception.Lifted           as EL
import           Control.Monad                      (MonadPlus (..), ap, mzero,
                                                     when)
import           Control.Monad.Base                 (MonadBase (..),
                                                     liftBaseDefault)
import           Control.Monad.Catch                (MonadThrow, throwM)
import           Control.Monad.Error.Class          (MonadError (..))
import           Control.Monad.IO.Class             (MonadIO (..))
import           Control.Monad.Reader.Class         (MonadReader (..))
import           Control.Monad.State.Class          (MonadState (..))
import           Control.Monad.Trans.Class          (MonadTrans (lift))
import           Control.Monad.Trans.Control        (MonadBaseControl,
                                                     liftBaseWith)
import           Data.Atomics                       (atomicModifyIORefCAS,
                                                     atomicModifyIORefCAS_)
import           Data.Bifunctor                     (bimap)
import           Data.Concurrent.Queue.MichaelScott (LinkedQueue, newQ, nullQ,
                                                     pushL, tryPopR)
import           Data.Functor                       (void)
import           Data.IORef                         (IORef, modifyIORef,
                                                     newIORef, readIORef)
import           Data.Maybe                         (isNothing)
import           Data.Semigroup                     (Semigroup (..))
import           Data.Set                           (Set)
import qualified Data.Set                           as S
import           Prelude                            hiding (concat, zipWith)

import           Control.Applicative                (Alternative (..), liftA2)
import           Control.Monad                      (MonadPlus (..), ap)
import           Control.Monad.Base                 (MonadBase (..))
import           Control.Monad.Catch                (MonadThrow)
import           Control.Monad.Error.Class          (MonadError (..))
import           Control.Monad.IO.Class             (MonadIO (..))
import           Control.Monad.Reader.Class         (MonadReader (..))
import           Control.Monad.State.Class          (MonadState (..))
import           Control.Monad.Trans.Class          (MonadTrans)
import           Data.Semigroup                     (Semigroup (..))
import           Prelude                            hiding (concat, zipWith)
import           Streamly.Core
import           Streamly.Streams


instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t) => Functor (t m) where
  fmap f = go
    where
      go t = fromStream $ Stream $ \_ stp yld ->
        let yield a Nothing  = yld (f a) Nothing
            yield a (Just r) = yld (f a) (Just (toStream (go (fromStream r))))
        in (runStream $ toStream t) Nothing stp yield

instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t) => Applicative (t m) where
    pure = point
    (<*>) = ap

instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t) => Monad (t m) where
    return = pure
    s >>= f = joinAsync . toStream $ fmap (toStream . f) s

------------------------------------------------------------------------------
-- Alternative & MonadPlus
------------------------------------------------------------------------------

-- | `empty` represents an action that takes non-zero time to complete.  Since
-- all actions take non-zero time, an `Alternative` composition ('<|>') is a
-- monoidal composition executing all actions in parallel, it is similar to
-- '<>' except that it runs all the actions in parallel and interleaves their
-- results fairly.

instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t) => Alternative (t m) where
    empty = mempty
    a <|> b = fromStream $ parAlt (toStream a) (toStream b)

instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t) => MonadPlus (t m) where
    mzero = empty
    mplus = (<|>)

instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t, Num a) => Num (t m a) where
    fromInteger n = pure (fromInteger n)

    negate = fmap negate
    abs    = fmap abs
    signum = fmap signum

    (+) = liftA2 (+)
    (*) = liftA2 (*)
    (-) = liftA2 (-)

instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t, Fractional a) => Fractional (t m a) where
    fromRational n = pure (fromRational n)

    recip = fmap recip

    (/) = liftA2 (/)

instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t, Floating a) => Floating (t m a) where
    pi = pure pi

    exp  = fmap exp
    sqrt = fmap sqrt
    log  = fmap log
    sin  = fmap sin
    tan  = fmap tan
    cos  = fmap cos
    asin = fmap asin
    atan = fmap atan
    acos = fmap acos
    sinh = fmap sinh
    tanh = fmap tanh
    cosh = fmap cosh
    asinh = fmap asinh
    atanh = fmap atanh
    acosh = fmap acosh

    (**)    = liftA2 (**)
    logBase = liftA2 logBase

-------------------------------------------------------------------------------
-- Transformer
-------------------------------------------------------------------------------

instance {-# INCOHERENT #-} (AsyncStreaming t, Streaming t) => MonadTrans t where
    lift mx = fromStream $ Stream $ \_ _ yld -> mx >>= (\a -> (yld a Nothing))

instance {-# INCOHERENT #-} (MonadBase b m, MonadAsync m, AsyncStreaming t, Streaming t) => MonadBase b (t m) where
    liftBase = liftBaseDefault

------------------------------------------------------------------------------
-- Standard transformer instances
------------------------------------------------------------------------------

instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t) => MonadIO (t m) where
    liftIO = lift . liftIO

instance {-# INCOHERENT #-} (MonadAsync m, AsyncStreaming t, Streaming t) => MonadThrow (t m) where
    throwM = lift . throwM

-- XXX handle and test cross thread state transfer
instance {-# INCOHERENT #-} (MonadAsync m, MonadError e m, AsyncStreaming t, Streaming t) => MonadError e (t m) where
    throwError     = lift . throwError

    catchError m h = fromStream $ Stream $ \st stp yld ->
        let handle r = r `catchError` \e -> (runStream (toStream $ h e)) st stp yld
            yield a Nothing  = yld a Nothing
            yield a (Just r) = yld a (Just $ toStream $ catchError (fromStream r) h)
        in handle $ (runStream (toStream m)) st stp yield

instance {-# INCOHERENT #-} (MonadAsync m, MonadReader r m, AsyncStreaming t, Streaming t) => MonadReader r (t m) where
    ask = lift ask

    local f m = fromStream $ Stream $ \st stp yld ->
        let yield a Nothing  = local f $ yld a Nothing
            yield a (Just r) = local f $ yld a (Just $ local f r)
        in (runStream $ toStream m) st (local f stp) yield

instance {-# INCOHERENT #-} (MonadAsync m, MonadState s m, AsyncStreaming t, Streaming t) => MonadState s (t m) where
    get     = lift get
    put     = lift . put
    state   = lift . state

-- | Read an SVar to get a stream.
fromSVar :: (MonadAsync m, Streaming t) => SVar m a -> t m a
fromSVar sv = fromStream $ fromStreamVar sv

-- | Write a stream to an 'SVar' in a non-blocking manner. The stream can then
-- be read back from the SVar using 'fromSVar'.
toSVar :: (Streaming t, MonadAsync m) => SVar m a -> t m a -> m ()
toSVar sv m = toStreamVar sv (toStream m)


-- XXX Get rid of this?
-- | Make a stream asynchronous, triggers the computation and returns a stream
-- in the underlying monad representing the output generated by the original
-- computation. The returned action is exhaustible and must be drained once. If
-- not drained fully we may have a thread blocked forever and once exhausted it
-- will always return 'empty'.
async :: (Streaming t, MonadAsync m) => t m a -> m (t m a)
async m = fromSVar <$> newStreamVar1 (SVarStyle Disjunction LIFO) (toStream m)


-- | Zip two streams asyncly (i.e. both the elements being zipped are generated
-- concurrently) using a pure zipping function.
zipAsyncWith :: (Streaming t, MonadAsync m)
    => (a -> b -> c) -> t m a -> t m b -> t m c
zipAsyncWith f m1 m2 = fromStream $ Stream $ \_ stp yld -> do
    ma <- async m1
    mb <- async m2
    (runStream (toStream (zipWith f ma mb))) Nothing stp yld

------------------------------------------------------------------------------
-- Spawning threads and collecting result in streamed fashion
------------------------------------------------------------------------------

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
            Just m  -> (runStream m) (Just sv) run yield

    sendit a = send sv (ChildYield a)
    yield a Nothing  = sendit a >> run
    yield a (Just r) = sendit a >> (runStream r) (Just sv) run yield

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
            Just m  -> (runStream m) (Just sv) run yield

    dequeue = liftIO $ tryPopR q
    sendit a = send sv (ChildYield a)
    yield a Nothing  = sendit a >> run
    yield a (Just r) = sendit a >> liftIO (enqueueFIFO q r) >> run

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
    liftIO $ modifyIORef (runningThreads sv) (\s -> S.delete tid s)

{-# INLINE allThreadsDone #-}
allThreadsDone :: MonadIO m => SVar m a -> m Bool
allThreadsDone sv = liftIO $ S.null <$> readIORef (runningThreads sv)

{-# NOINLINE handleChildException #-}
handleChildException :: MonadIO m => SVar m a -> SomeException -> m ()
handleChildException sv e = do
    tid <- liftIO myThreadId
    send sv (ChildStop tid (Just e))

{-# NOINLINE pushWorker #-}
pushWorker :: MonadAsync m => SVar m a -> m ()
pushWorker sv =
    doFork (runqueue sv) (handleChildException sv) >>= addThread sv

-- XXX When the queue is LIFO we can put a limit on the number of dispatches.
-- Also, if a worker blocks on the output queue we can decide if we want to
-- block or make it go away entirely, depending on the number of workers and
-- the type of the queue.
{-# INLINE sendWorkerWait #-}
sendWorkerWait :: MonadAsync m => SVar m a -> m ()
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
fromStreamVar :: MonadAsync m => SVar m a -> Stream m a
fromStreamVar sv = Stream $ \_ stp yld -> do
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
        (runStream $ processEvents (reverse list)) Nothing stp yld

    where

    handleException e tid = do
        delThread sv tid
        -- XXX implement kill async exception handling
        -- liftIO $ readIORef (runningThreads sv) >>= mapM_ killThread
        throwM e

    {-# INLINE processEvents #-}
    processEvents [] = Stream $ \_ stp yld -> do
        done <- allThreadsDone sv
        if not done
        then (runStream (fromStreamVar sv)) Nothing stp yld
        else stp

    processEvents (ev : es) = Stream $ \_ stp yld -> do
        let continue = (runStream (processEvents es)) Nothing stp yld
            yield a  = yld a (Just (processEvents es))

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
newEmptySVar :: MonadAsync m => SVarStyle -> m (SVar m a)
newEmptySVar style = do
    liftIO $
        case style of
            SVarStyle _ FIFO -> getFifoSVar style
            SVarStyle _ LIFO -> getLifoSVar style

-- | Create a new SVar and enqueue one stream computation on it.
newStreamVar1 :: MonadAsync m => SVarStyle -> Stream m a -> m (SVar m a)
newStreamVar1 style m = do
    sv <- newEmptySVar style
    -- Note: We must have all the work on the queue before sending the
    -- pushworker, otherwise the pushworker may exit before we even get a
    -- chance to push.
    liftIO $ (enqueue sv) m
    pushWorker sv
    return sv

-- | Create a new SVar and enqueue two stream computations on it.
newStreamVar2 :: MonadAsync m
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
toStreamVar :: MonadAsync m => SVar m a -> Stream m a -> m ()
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
-- the producer who pushing to the channel. The producer creates more threads
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
-- we can divide it in chunks of arbitrary size before dispatch. If the stream
-- is composed of hierarchically composed grains of different sizes then we can
-- always switch to a desired granularity depending on the consumer speed.
--
-- TBD for pure work (when we are not in the IO monad) we can divide it into
-- just the number of CPUs.

{-# NOINLINE withNewSVar2 #-}
withNewSVar2 :: MonadAsync m
    => SVarStyle -> Stream m a -> Stream m a -> Stream m a
withNewSVar2 style m1 m2 = Stream $ \_ stp yld -> do
    sv <- newStreamVar2 style m1 m2
    (runStream (fromStreamVar sv)) Nothing stp yld

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
joinStreamVar2 :: MonadAsync m
    => SVarStyle -> Stream m a -> Stream m a -> Stream m a
joinStreamVar2 style m1 m2 = Stream $ \st stp yld ->
    case st of
        Just sv | svarStyle sv == style ->
            liftIO ((enqueue sv) m2) >> (runStream m1) st stp yld
        _ -> (runStream (withNewSVar2 style m1 m2)) Nothing stp yld

------------------------------------------------------------------------------
-- Semigroup and Monoid style compositions for parallel actions
------------------------------------------------------------------------------

{-
-- | Same as '<>|'.
parAhead :: Stream m a -> Stream m a -> Stream m a
parAhead = undefined

-- | Sequential composition similar to '<>' except that it can execute the
-- action on the right in parallel ahead of time. Returns the results in
-- sequential order like '<>' from left to right.
(<>|) :: Stream m a -> Stream m a -> Stream m a
(<>|) = parAhead
-}

-- | Same as '<|>'. Since this schedules all the composed streams fairly you
-- cannot fold infinite number of streams using this operation.
{-# INLINE parAlt #-}
parAlt :: MonadAsync m => Stream m a -> Stream m a -> Stream m a
parAlt = joinStreamVar2 (SVarStyle Disjunction FIFO)

-- | Same as '<|'. Since this schedules the left side computation first you can
-- right fold an infinite container using this operator. However a left fold
-- will not work well as it first unpeels the whole structure before scheduling
-- a computation requiring an amount of memory proportional to the size of the
-- structure.
{-# INLINE parLeft #-}
parLeft :: MonadAsync m => Stream m a -> Stream m a -> Stream m a
parLeft = joinStreamVar2 (SVarStyle Disjunction LIFO)

------------------------------------------------------------------------------
-- AsyncT
------------------------------------------------------------------------------

-- | Like 'StreamT' but /may/ run each iteration concurrently using demand
-- driven concurrency.  More concurrent iterations are started only if the
-- previous iterations are not able to produce enough output for the consumer.
--
-- @
-- import "Streamly"
-- import Control.Concurrent
--
-- main = 'runAsyncT' $ do
--     n <- return 3 \<\> return 2 \<\> return 1
--     liftIO $ do
--          threadDelay (n * 1000000)
--          myThreadId >>= \\tid -> putStrLn (show tid ++ ": Delay " ++ show n)
-- @
-- @
-- ThreadId 40: Delay 1
-- ThreadId 39: Delay 2
-- ThreadId 38: Delay 3
-- @
--
-- All iterations may run in the same thread if they do not block.
newtype AsyncT m a = AsyncT {getAsyncT :: Stream m a}

instance AsyncStreaming AsyncT where
    joinAsync = AsyncT . sjoin . sfold (joinStreamVar2 (SVarStyle Conjunction LIFO)) snil

instance SyncStreaming AsyncT where
    joinSync = AsyncT . sjoin . sfold interleave snil

instance Streaming AsyncT where
    toStream = getAsyncT
    fromStream = AsyncT
    point = AsyncT . singleton

------------------------------------------------------------------------------
-- ParallelT
------------------------------------------------------------------------------

-- | Like 'StreamT' but runs /all/ iterations fairly concurrently using a round
-- robin scheduling.
--
-- @
-- import "Streamly"
-- import Control.Concurrent
--
-- main = 'runParallelT' $ do
--     n <- return 3 \<\> return 2 \<\> return 1
--     liftIO $ do
--          threadDelay (n * 1000000)
--          myThreadId >>= \\tid -> putStrLn (show tid ++ ": Delay " ++ show n)
-- @
-- @
-- ThreadId 40: Delay 1
-- ThreadId 39: Delay 2
-- ThreadId 38: Delay 3
-- @
--
-- Unlike 'AsyncT' all iterations are guaranteed to run fairly concurrently,
-- unconditionally.
newtype ParallelT m a = ParallelT {getParallelT :: Stream m a}

instance AsyncStreaming ParallelT where
  joinAsync = ParallelT . sjoin . sfold (joinStreamVar2 (SVarStyle Conjunction FIFO)) snil

instance SyncStreaming ParallelT where
  joinSync = ParallelT . sjoin

instance Streaming ParallelT where
  toStream = getParallelT
  fromStream = ParallelT
  point = ParallelT . singleton

------------------------------------------------------------------------------
-- Parallely Zipping Streams
------------------------------------------------------------------------------

-- | Like 'ZipStream' but zips in parallel, it generates both the elements to
-- be zipped concurrently.
--
-- @
-- main = (toList . 'zippingAsync' $ (,) \<$\> s1 \<*\> s2) >>= print
--     where s1 = pure 1 <> pure 2
--           s2 = pure 3 <> pure 4
-- @
-- @
-- [(1,3),(2,4)]
-- @
--
-- This applicative operation can be seen as the zipping equivalent of
-- parallel composition with '<|>'.
newtype ZipAsync m a = ZipAsync {getZipAsync :: Stream m a}

deriving instance MonadAsync m => Alternative (ZipAsync m)

instance AsyncStreaming ZipAsync where
    joinAsync = ZipAsync . sjoin . sfold concat snil

instance SyncStreaming ZipAsync where
    joinSync = ZipAsync . sjoin . sfold concat snil

instance Streaming ZipAsync where
    toStream = getZipAsync
    fromStream = ZipAsync
    point = ZipAsync . srepeat

-- | Demand driven concurrent composition. In contrast to '<|>' this operator
-- concurrently "merges" streams in a left biased manner rather than fairly
-- interleaving them.  It keeps yielding from the stream on the left as long as
-- it can. If the left stream blocks or cannot keep up with the pace of the
-- consumer it can concurrently yield from the stream on the right in parallel.
--
-- @
-- main = ('toList' . 'serially' $ (return 1 <> return 2) \<| (return 3 <> return 4)) >>= print
-- @
-- @
-- [1,2,3,4]
-- @
--
-- Unlike '<|>' it can be used to fold infinite containers of streams. This
-- operator corresponds to the 'AsyncT' type for product style composition.
--
{-# INLINE (<|) #-}
(<|) :: (Streaming t, MonadAsync m) => t m a -> t m a -> t m a
m1 <| m2 = fromStream $ parLeft (toStream m1) (toStream m2)

-------------------------------------------------------------------------------
-- Type adapting combinators
-------------------------------------------------------------------------------

-- | Interpret an ambiguously typed stream as 'AsyncT'.
asyncly :: AsyncT m a -> AsyncT m a
asyncly x = x

-- | Interpret an ambiguously typed stream as 'ParallelT'.
parallely :: ParallelT m a -> ParallelT m a
parallely x = x

-- | Interpret an ambiguously typed stream as 'ZipAsync'.
zippingAsync :: ZipAsync m a -> ZipAsync m a
zippingAsync x = x

-------------------------------------------------------------------------------
-- Running Streams, convenience functions specialized to types
-------------------------------------------------------------------------------

-- | Same as @runStreaming . asyncly@.
runAsyncT :: Monad m => AsyncT m a -> m ()
runAsyncT = runStreaming

-- | Same as @runStreaming . parallely@.
runParallelT :: Monad m => ParallelT m a -> m ()
runParallelT = runStreaming

-- | Same as @runStreaming . zippingAsync@.
runZipAsync :: Monad m => ZipAsync m a -> m ()
runZipAsync = runStreaming
