{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
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
module Streamly.Sync
    (
      Streaming (..)
    , MonadAsync

    -- * Construction
    , nil
    , cons
    , (.:)
    , streamBuild
    , fromCallback

    -- * Elimination
    , streamFold
    , runStreaming

    -- * Stream Styles
    , StreamT
    , ReverseT
    , InterleavedT
    , ZipStream

    -- * Type Adapters
    , adapt
    , serially
    , reversely
    , interleaving
    , zipping

    -- * Running Streams
    , runStreamT
    , runReverseT
    , runInterleavedT
    , runZipStream

    -- * Zipping
    , zipWith

    -- * Sum Style Composition
    , (<=>)

    -- * Fold Utilities
    -- $foldutils
    , foldWith
    , foldMapWith
    , forEachWith
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

instance {-# OVERLAPPABLE #-} (Monad m, SyncStreaming t, Streaming t) => Functor (t m) where
  fmap f = go
    where
      go t = fromStream $ Stream $ \_ stp yld ->
        let yield a Nothing  = yld (f a) Nothing
            yield a (Just r) = yld (f a) (Just (toStream (go (fromStream r))))
        in (runStream $ toStream t) Nothing stp yield

instance {-# OVERLAPPABLE #-} (Monad m, SyncStreaming t, Streaming t) => Applicative (t m) where
    pure = point
    (<*>) = ap

instance {-# OVERLAPPABLE #-} (Monad m, SyncStreaming t, Streaming t) => Monad (t m) where
    return = pure
    s >>= f = joinSync . toStream $ fmap (toStream . f) s

instance {-# OVERLAPPABLE #-} (Monad m, SyncStreaming t, Streaming t, Fractional a) => Fractional (t m a) where
    fromRational n = pure (fromRational n)

    recip = fmap recip

    (/) = liftA2 (/)

instance {-# OVERLAPPABLE #-} (Monad m, SyncStreaming t, Streaming t, Floating a) => Floating (t m a) where
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


instance {-# OVERLAPPABLE #-} (Monad m, SyncStreaming t, Streaming t, Num a) => Num (t m a) where
    fromInteger n = pure (fromInteger n)

    negate = fmap negate
    abs    = fmap abs
    signum = fmap signum

    (+) = liftA2 (+)
    (*) = liftA2 (*)
    (-) = liftA2 (-)

-------------------------------------------------------------------------------
-- Transformer
-------------------------------------------------------------------------------

instance {-# OVERLAPPABLE #-} (SyncStreaming t, Streaming t) => MonadTrans t where
    lift mx = fromStream $ Stream $ \_ _ yld -> mx >>= (\a -> (yld a Nothing))

instance {-# OVERLAPPABLE #-} (MonadBase b m, Monad m, SyncStreaming t, Streaming t) => MonadBase b (t m) where
    liftBase = liftBaseDefault

------------------------------------------------------------------------------
-- Standard transformer instances
------------------------------------------------------------------------------

instance {-# OVERLAPPABLE #-} (Monad m, MonadIO m, SyncStreaming t, Streaming t) => MonadIO (t m) where
    liftIO = lift . liftIO

instance {-# OVERLAPPABLE #-} (Monad m, MonadThrow m, SyncStreaming t, Streaming t) => MonadThrow (t m) where
    throwM = lift . throwM

instance {-# OVERLAPPABLE #-} (Monad m, MonadError e m, SyncStreaming t, Streaming t) => MonadError e (t m) where
    throwError     = lift . throwError
    catchError m h = fromStream $ Stream $ \st stp yld ->
        let handle r = r `catchError` \e -> (runStream (toStream $ h e)) st stp yld
            yield a Nothing  = yld a Nothing
            yield a (Just r) = yld a (Just $ toStream $ catchError (fromStream r) h)
        in handle $ (runStream (toStream m)) st stp yield

instance {-# OVERLAPPABLE #-} (Monad m, MonadReader r m, SyncStreaming t, Streaming t) => MonadReader r (t m) where
    ask = lift ask
    local f m = fromStream $ Stream $ \st stp yld ->
        let yield a Nothing  = local f $ yld a Nothing
            yield a (Just r) = local f $ yld a (Just $ local f r)
        in (runStream $ toStream m) st (local f stp) yield

instance {-# OVERLAPPABLE #-} (Monad m, MonadState s m, SyncStreaming t, Streaming t) => MonadState s (t m) where
    get   = lift get
    put   = lift . put
    state = lift . state

------------------------------------------------------------------------------
-- StreamT
------------------------------------------------------------------------------

-- | The 'Monad' instance of 'StreamT' runs the /monadic continuation/ for each
-- element of the stream, serially.
--
-- @
-- main = 'runStreamT' $ do
--     x <- return 1 \<\> return 2
--     liftIO $ print x
-- @
-- @
-- 1
-- 2
-- @
--
-- 'StreamT' nests streams serially in a depth first manner.
--
-- @
-- main = 'runStreamT' $ do
--     x <- return 1 \<\> return 2
--     y <- return 3 \<\> return 4
--     liftIO $ print (x, y)
-- @
-- @
-- (1,3)
-- (1,4)
-- (2,3)
-- (2,4)
-- @
--
-- This behavior is exactly like a list transformer. We call the monadic code
-- being run for each element of the stream a monadic continuation. In
-- imperative paradigm we can think of this composition as nested @for@ loops
-- and the monadic continuation is the body of the loop. The loop iterates for
-- all elements of the stream.
--
newtype StreamT m a = StreamT {getStreamT :: Stream m a}

instance SyncStreaming StreamT where
  joinSync = StreamT . sjoin

instance AsyncStreaming StreamT where
  joinAsync = StreamT . sjoin

instance Streaming StreamT where
    toStream = getStreamT
    fromStream = StreamT
    point = StreamT . singleton

-- XXX The Functor/Applicative/Num instances for all the types are exactly the
-- same, how can we reduce this boilerplate (use TH)? We cannot derive them
-- from a single base type because they depend on the Monad instance which is
-- different for each type.

------------------------------------------------------------------------------
-- ReverseT
------------------------------------------------------------------------------

-- TODO: documenation

newtype ReverseT m a = ReverseT {getReverseT :: Stream m a}

instance SyncStreaming ReverseT where
  joinSync = ReverseT . scojoin

instance AsyncStreaming ReverseT where
  joinAsync = ReverseT . scojoin

instance Streaming ReverseT where
    toStream = getReverseT
    fromStream = ReverseT
    point = ReverseT . singleton

------------------------------------------------------------------------------
-- InterleavedT
------------------------------------------------------------------------------

-- | Like 'StreamT' but different in nesting behavior. It fairly interleaves
-- the iterations of the inner and the outer loop, nesting loops in a breadth
-- first manner.
--
--
-- @
-- main = 'runInterleavedT' $ do
--     x <- return 1 \<\> return 2
--     y <- return 3 \<\> return 4
--     liftIO $ print (x, y)
-- @
-- @
-- (1,3)
-- (2,3)
-- (1,4)
-- (2,4)
-- @
--
newtype InterleavedT m a = InterleavedT {getInterleavedT :: Stream m a}

instance SyncStreaming InterleavedT where
  joinSync = InterleavedT . sinterleave

instance AsyncStreaming InterleavedT where
  joinAsync = InterleavedT . sinterleave

instance Streaming InterleavedT where
    toStream = getInterleavedT
    fromStream = InterleavedT
    point = InterleavedT . singleton

------------------------------------------------------------------------------
-- Serially Zipping Streams
------------------------------------------------------------------------------

-- | 'ZipStream' zips serially i.e. it produces one element from each stream
-- serially and then zips the two elements. Note, for convenience we have used
-- the 'zipping' combinator in the following example instead of using a type
-- annotation.
--
-- @
-- main = (toList . 'zipping' $ (,) \<$\> s1 \<*\> s2) >>= print
--     where s1 = pure 1 <> pure 2
--           s2 = pure 3 <> pure 4
-- @
-- @
-- [(1,3),(2,4)]
-- @
--
-- This applicative operation can be seen as the zipping equivalent of
-- interleaving with '<=>'.
newtype ZipStream m a = ZipStream {getZipStream :: Stream m a}

-- deriving instance MonadAsync m => Alternative (ZipStream m)

instance SyncStreaming ZipStream where
  joinSync = ZipStream . sjoin . sfold concat snil

instance AsyncStreaming ZipStream where
  joinAsync = ZipStream . sjoin . sfold concat snil

instance Streaming ZipStream where
    toStream = getZipStream
    fromStream = ZipStream
    point = ZipStream . srepeat

-------------------------------------------------------------------------------
-- Type adapting combinators
-------------------------------------------------------------------------------

-- | Interpret an ambiguously typed stream as 'StreamT'.
serially :: StreamT m a -> StreamT m a
serially x = x

-- | Interpret an ambiguously typed stream as 'ReverseT'.
reversely :: ReverseT m a -> ReverseT m a
reversely x = x

-- | Interpret an ambiguously typed stream as 'InterleavedT'.
interleaving :: InterleavedT m a -> InterleavedT m a
interleaving x = x

-- | Interpret an ambiguously typed stream as 'ZipStream'.
zipping :: ZipStream m a -> ZipStream m a
zipping x = x

-------------------------------------------------------------------------------
-- Running Streams, convenience functions specialized to types
-------------------------------------------------------------------------------

-- | Same as @runStreaming . serially@.
runStreamT :: Monad m => StreamT m a -> m ()
runStreamT = runStreaming

-- | Same as @runStreaming . reversely@.
runReverseT :: Monad m => ReverseT m a -> m ()
runReverseT = runStreaming

-- | Same as @runStreaming . interleaving@.
runInterleavedT :: Monad m => InterleavedT m a -> m ()
runInterleavedT = runStreaming

-- | Same as @runStreaming . zipping@.
runZipStream :: Monad m => ZipStream m a -> m ()
runZipStream = runStreaming

