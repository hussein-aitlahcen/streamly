{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE InstanceSigs          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeInType            #-}
{-# LANGUAGE UndecidableInstances  #-}

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
      MonadAsync

    -- * Streams
    , Stream (..)
    , SyncStreaming (..)
    , AsyncStreaming (..)
    , Streaming (..)

    -- * Construction
    , singleton
    , scons
    , srepeat
    , snil

    , SVar (..)
    , SVarSched (..)
    , SVarTag (..)
    , SVarStyle (..)
    , ChildEvent (..)

    -- * Composition
    , interleave
    , concat
    , sjoin
    , scojoin
    , sinterleave
    , sfold
    , sscan
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
import           Prelude                            hiding (concat)

------------------------------------------------------------------------------
-- The stream type
------------------------------------------------------------------------------

-- TBD use a functor instead of the bare type a?

-- | The type 'Stream m a' represents a monadic stream of values of type 'a'
-- constructed using actions in monad 'm'. It uses a stop continuation and a
-- yield continuation. You can consider it a rough equivalent of direct style
-- type:
--
-- data Stream m a = Stop | Yield a (Maybe (Stream m a))
--
-- Our goal is to be able to represent finite as well infinite streams and
-- being able to compose a large number of small streams efficiently. In
-- addition we want to compose streams in parallel, to facilitate that we
-- maintain a local state in an SVar that is shared across and is used for
-- synchronization of the streams being composed.
--
-- Using this type, there are two ways to indicate the end of a stream, one is
-- by calling the stop continuation and the other one is by yielding the last
-- value along with 'Nothing' as the rest of the stream.
--
-- Why do we have this redundancy? Why can't we use (a -> Stream m a -> m r) as
-- the type of the yield continuation and always use the stop continuation to
-- indicate the end of the stream? The reason is that when we compose a large
-- number of short or singleton streams then using the stop continuation
-- becomes expensive, just to know that there is no next element we have to
-- call the continuation, introducing an indirection, it seems when using CPS
-- GHC is not able to optimize this out as efficiently as it can be in direct
-- style because of the function call involved. In direct style it will just be
-- a constructor check and a memory access instead of a function call. So we
-- could use:
--
-- data Stream m a = Stop | Yield a (Stream m a)
--
-- In CPS style, when we use the 'Maybe' argument of yield to indicate the end
-- then just like direct style we can figure out that there is no next element
-- without a function call.
--
-- Then why not get rid of the stop continuation and use only yield to indicate
-- the end of stream? The answer is, in that case to indicate the end of the
-- stream we would have to yield at least one element so there is no way to
-- represent an empty stream.
--
-- Whenever we make a singleton stream or in general when we build a stream
-- strictly i.e. when we know all the elements of the stream in advance we can
-- use the last yield to indicate th end of the stream, because we know in
-- advance at the time of the last yield that the stream is ending.  We build
-- singleton streams in the implementation of 'pure' for Applicative and Monad,
-- and in 'lift' for MonadTrans, in these places we use yield with 'Nothing' to
-- indicate the end of the stream. Note that, the only advantage of Maybe is
-- when we have to build a large number of singleton or short streams. For
-- larger streams anyway the overhead of a separate stop continuation is not
-- significant. This could be significant when we breakdown a large stream into
-- its elements, process them in some way and then recompose it from the
-- pieces. Zipping streams is one such example. Zipping with streamly is the
-- fastest among all streaming libraries.
--
-- However in a lazy computation we cannot know in advance that the stream is
-- ending therefore we cannot use 'Maybe', we use the stop continuation in that
-- case. For example when building a stream from a lazy container using a right
-- fold.
--
newtype Stream m a = Stream { runStream :: forall r.
                                           Maybe (SVar m a)               -- local state
                                        -> m r                               -- stop
                                        -> (a -> Maybe (Stream m a) -> m r)  -- yield
                                        -> m r
                            }

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

-- | A monad that can perform asynchronous/concurrent IO operations. Streams
-- that can be composed concurrently require the underlying monad to be
-- 'MonadAsync'.
type MonadAsync m = (MonadIO m, MonadBaseControl IO m, MonadThrow m)

------------------------------------------------------------------------------
-- Types that can behave as a Stream
------------------------------------------------------------------------------

-- | Class of types that can represent a stream of elements of some type 'a' in
-- some monad 'm'.

-- type family (StreamType a) :: Bool where
--   StreamType

class Streaming t where
  toStream :: t m a -> Stream m a
  fromStream :: Stream m a -> t m a
  point :: a -> t m a

instance Streaming Stream where
  toStream = id
  fromStream = id
  point = singleton

class AsyncStreaming t where
  joinAsync :: MonadAsync m => Stream m (Stream m a) -> t m a

class SyncStreaming t where
  joinSync :: Monad m => Stream m (Stream m a) -> t m a

instance AsyncStreaming Stream where
  joinAsync = sjoin

instance SyncStreaming Stream where
  joinSync = sjoin

singleton :: a -> Stream m a
singleton = flip scons Nothing

scons :: a -> Maybe (Stream m a) -> Stream m a
scons a r = Stream $ \_ _ yld -> yld a r

srepeat :: a -> Stream m a
srepeat a = let x = scons a (Just x) in x

snil :: Stream m a
snil = Stream $ \_ stp _ -> stp

------------------------------------------------------------------------------
-- Composing streams
------------------------------------------------------------------------------

-- Streams can be composed sequentially or in parallel; in product style
-- compositions (monadic bind multiplies streams in a ListT fashion) or in sum
-- style compositions like 'Semigroup', 'Monoid', 'Alternative' or variants of
-- these.

------------------------------------------------------------------------------
-- Semigroup
------------------------------------------------------------------------------

-- | '<>' concatenates two streams sequentially i.e. the first stream is
-- exhausted completely before yielding any element from the second stream.

instance {-# OVERLAPPING #-} Semigroup (Stream m a) where
  (<>) = concat

instance (Streaming t) => Semigroup (t m a) where
  tm1 <> tm2 = fromStream $ toStream tm1 <> toStream tm2

------------------------------------------------------------------------------
-- Monoid
------------------------------------------------------------------------------
instance {-# OVERLAPPING #-} Monoid (Stream m a) where
  mempty = snil
  mappend = (<>)

instance (Streaming t) => Monoid (t m a) where
  mempty = fromStream snil
  mappend = (<>)

concat :: Stream m a -> Stream m a -> Stream m a
concat m1 m2 = sjoin $ scons m1 (Just $ singleton m2)

------------------------------------------------------------------------------
-- Interleave
------------------------------------------------------------------------------

-- | Same as '<=>'.
interleave :: Stream m a -> Stream m a -> Stream m a
interleave m1 m2 = Stream $ \_ stp yld -> do
    let stop = (runStream m2) Nothing stp yld
        yield a Nothing  = yld a (Just m2)
        yield a (Just r) = yld a (Just (interleave m2 r))
    (runStream m1) Nothing stop yield

sscan :: (a -> b -> b) -> b -> Stream m a -> Stream m b
sscan step acc m = Stream $ \_ stp yld ->
      let yield a Nothing = yld (step a acc) Nothing
          yield a (Just r) =
            let acc' = step a acc
            in yld acc' (Just $ sfold step acc' r)
      in (runStream m) Nothing stp yield

sfold :: (a -> b -> b) -> b -> Stream m a -> Stream m b
sfold step acc m = Stream $ \_ stp yld ->
  let yield a Nothing = yld (step a acc) Nothing
      yield a (Just r) =
        -- discard the intermediate result
        let run x = (runStream x) Nothing stp yld
            acc' = step a acc
        in run $ sfold step acc' r
  in (runStream m) Nothing stp yield

sinterleave :: Stream m (Stream m a) -> Stream m a
sinterleave = sjoin . sfold interleave snil

------------------------------------------------------------------------------
-- Sequentially join
------------------------------------------------------------------------------

sjoin :: Stream m (Stream m a) -> Stream m a
sjoin m = Stream $ \_ stp yld ->
  let run x = (runStream x) Nothing stp yld
      yield m1 Nothing = run m1
      yield m1 (Just rr) = run $ Stream $ \_ stp1 yld1 ->
        let stop = (runStream $ sjoin rr) Nothing stp1 yld1
            yield1 a Nothing  = yld1 a (Just $ sjoin rr)
            yield1 a (Just r) = yld1 a (Just $ sjoin $ scons r (Just rr))
        in (runStream m1) Nothing stop yield1
  in (runStream m) Nothing stp yield

------------------------------------------------------------------------------
-- CoJoin
------------------------------------------------------------------------------

scojoin :: Stream m (Stream m a)  -> Stream m a
scojoin m = Stream $ \_ stp yld ->
  let run x = (runStream x) Nothing stp yld
      yield m1 Nothing = run m1
      yield m1 (Just rr) = run $ Stream $ \_ stp1 yld1 ->
        let yield1 a Nothing  = yld1 a (Just $ scojoin rr)
            yield1 a (Just r) = yld1 a (Just $ scojoin (rr <> singleton r))
        in (runStream m1) Nothing stp1 yield1
  in (runStream m) Nothing stp yield
