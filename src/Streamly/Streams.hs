{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving#-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE UndecidableInstances      #-} -- XXX

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
module Streamly.Streams
    (
      IsStream (..)
    , Streaming         -- deprecated
    , MonadParallel
    , S.MonadAsync      -- deprecated

    -- * SVars
    , SVarSched (..)
    , SVarTag (..)
    , SVarStyle (..)
    , SVar
    , S.newEmptySVar

    -- * Construction
    , nil
    , cons
    , (.:)
    , streamBuild
    , fromCallback
    , fromSVar

    -- * Elimination
    , streamFold
    , runStream
    , runStreaming      -- deprecated
    , toSVar

    -- * Transformation
    , async

    -- * Merging Streams
    , splice
    , cosplice
    , coparallel
    , parallel
    , (<=>)            --deprecated
    , (<|)             --deprecated

    -- * IO Streams
    , Stream
    , Costream
    , Coparallel
    , Parallel
    , ZipStream
    , ZipParallel
    , fromIO
    , fromM

    -- * Stream Transformers
    , StreamT
    , CostreamT
    , InterleavedT      -- deprecated
    , CoparallelT
    , AsyncT            -- deprecated
    , ParallelT
    , ZipStreamM
    , ZipParallelM
    , ZipAsync          -- deprecated

    -- * Type Adapters
    , streamly
    , costreamly
    , interleaving     -- deprecated
    , coparallely
    , asyncly          -- deprecated
    , parallely
    , zipStreamly
    , zipping          -- deprecated
    , zipParallely
    , zippingAsync     -- deprecated
    , adapt

    -- * Running Streams
    , runStreamT       -- deprecated
    , runInterleavedT  -- deprecated
    , runAsyncT        -- deprecated
    , runParallelT     -- deprecated
    , runZipStream     -- deprecated
    , runZipAsync      -- deprecated

    -- * Zipping
    , zipWith
    , zipParallelWith
    , zipAsyncWith    -- deprecated

    -- * Fold Utilities
    , foldWith
    , foldMapWith
    , forEachWith
    )
where

import           Control.Monad               (ap)
import           Control.Monad.Base          (MonadBase (..), liftBaseDefault)
import           Control.Monad.Catch         (MonadThrow, throwM)
-- import           Control.Monad.Error.Class   (MonadError(..))
import           Control.Monad.IO.Class      (MonadIO(..))
import           Control.Monad.Reader.Class  (MonadReader(..))
import           Control.Monad.State.Class   (MonadState(..))
import           Control.Monad.Trans.Class   (MonadTrans (lift))
import           Data.Semigroup              (Semigroup(..))
import           Prelude hiding              (zipWith)
import           Streamly.Core               ( MonadParallel
                                             , singleton
                                             , SVar, SVarStyle(..)
                                             , SVarTag(..), SVarSched(..))
import qualified Streamly.Core as S

------------------------------------------------------------------------------
-- Types that can behave as a Stream
------------------------------------------------------------------------------

-- | Class of types that can represent a stream of elements of some type 'a' in
-- some monad 'm'.
class IsStream t where
    toStream :: t m a -> S.Stream m a
    fromStream :: S.Stream m a -> t m a

-- | Same as 'IsStream'.
{-# Deprecated Streaming "Please use IsStream instead." #-}
type Streaming = IsStream

------------------------------------------------------------------------------
-- Constructing a stream
------------------------------------------------------------------------------

-- | Represesnts an empty stream just like @[]@ represents an empty list.
nil :: IsStream t => t m a
nil = fromStream S.nil

infixr 5 `cons`

-- | Constructs a stream by adding a pure value at the head of an existing
-- stream, just like ':' constructs lists. For example:
--
-- @
-- > let stream = 1 \`cons` 2 \`cons` 3 \`cons` nil
-- > (toList . streamly) stream
-- [1,2,3]
-- @
cons :: IsStream t => a -> t m a -> t m a
cons a r = fromStream $ S.cons a (toStream r)

infixr 5 .:

-- | Operator equivalent of 'cons' so that you can construct a stream of pure
-- values more succinctly like this:
--
-- @
-- > let stream = 1 .: 2 .: 3 .: nil
-- > (toList . streamly) stream
-- [1,2,3]
-- @
--
-- '.:' constructs a stream just like ':' constructs a list.
--
-- Also note that another equivalent way of building streams from pure values
-- is:
--
-- @
-- > let stream = pure 1 <> pure 2 <> pure 3
-- > (toList . streamly) stream
-- [1,2,3]
-- @
--
-- In the first method we construct a stream by adding one element at a time.
-- In the second method we first construct singleton streams using 'pure' and
-- then compose all those streams together using the 'Semigroup' style
-- composition of streams. The former method is a bit more efficient than the
-- latter.
--
(.:) :: IsStream t => a -> t m a -> t m a
(.:) = cons

-- | Build a stream from its church encoding.  The function passed maps
-- directly to the underlying representation of the stream type. The second
-- parameter to the function is the "yield" function yielding a value and the
-- remaining stream if any otherwise 'Nothing'. The third parameter is to
-- represent an "empty" stream.
streamBuild :: IsStream t
    => (forall r. Maybe (SVar m a)
        -> (a -> t m a -> m r)
        -> (a -> m r)
        -> m r
        -> m r)
    -> t m a
streamBuild k = fromStream $ S.Stream $ \svr stp sng yld ->
    let yield a r = yld a (toStream r)
     in k svr yield sng stp

-- | Build a singleton stream from a callback function.
fromCallback :: IsStream t => (forall r. (a -> m r) -> m r) -> t m a
fromCallback k = fromStream $ S.Stream $ \_ _ sng _ -> k sng

-- | Read an SVar to get a stream.
fromSVar :: (MonadParallel m, IsStream t) => SVar m a -> t m a
fromSVar sv = fromStream $ S.fromStreamVar sv

------------------------------------------------------------------------------
-- Destroying a stream
------------------------------------------------------------------------------

-- | Fold a stream using its church encoding. The second argument is the "step"
-- function consuming an element and the remaining stream, if any. The third
-- argument is for consuming an "empty" stream that yields nothing.
streamFold
    :: IsStream t
    => Maybe (SVar m a)
    -> (a -> t m a -> m r)
    -> (a -> m r)
    -> m r
    -> t m a
    -> m r
streamFold svr step single blank m =
    let yield a x = step a (fromStream x)
     in (S.runStream (toStream m)) svr blank single yield

-- | Run a streaming composition, discard the results. By default it interprets
-- the stream as 'StreamT', to run other types of streams use the type adapting
-- combinators for example @runStream . 'parallely'@.
runStream :: Monad m => StreamT m a -> m ()
runStream m = go (toStream m)
    where
    go m1 =
        let stop = return ()
            single _ = return ()
            yield _ r = go r
         in (S.runStream m1) Nothing stop single yield

-- | Same as 'runStream'
{-# Deprecated runStreaming "Please use runStream instead." #-}
runStreaming :: (Monad m, IsStream t) => t m a -> m ()
runStreaming = runStream . adapt

-- | Write a stream to an 'SVar' in a non-blocking manner. The stream can then
-- be read back from the SVar using 'fromSVar'.
toSVar :: (IsStream t, MonadParallel m) => SVar m a -> t m a -> m ()
toSVar sv m = S.toStreamVar sv (toStream m)

------------------------------------------------------------------------------
-- Transformation
------------------------------------------------------------------------------

-- XXX Get rid of this?
-- | Make a stream asynchronous, triggers the computation and returns a stream
-- in the underlying monad representing the output generated by the original
-- computation. The returned action is exhaustible and must be drained once. If
-- not drained fully we may have a thread blocked forever and once exhausted it
-- will always return 'empty'.

async :: (IsStream t, MonadParallel m) => t m a -> m (t m a)
async m = do
    sv <- S.newStreamVar1 (SVarStyle Disjunction LIFO) (toStream m)
    return $ fromSVar sv

------------------------------------------------------------------------------
-- CPP macros for common instances
------------------------------------------------------------------------------

-- XXX use template haskell instead and include Monoid and IsStream instances
-- as well.

#define MONADPARALLEL , MonadParallel m

#define MONAD_APPLICATIVE_INSTANCE(STREAM,CONSTRAINT)         \
instance (Monad m CONSTRAINT) => Applicative (STREAM m) where { \
    pure = STREAM . singleton;                     \
    (<*>) = ap }

#define MONAD_COMMON_INSTANCES(STREAM,CONSTRAINT)                            \
instance (MonadBase b m, Monad m CONSTRAINT) => MonadBase b (STREAM m) where {\
    liftBase = liftBaseDefault };                                             \
                                                                              \
instance (MonadIO m CONSTRAINT) => MonadIO (STREAM m) where {                 \
    liftIO = lift . liftIO };                                                 \
                                                                              \
instance (MonadThrow m CONSTRAINT) => MonadThrow (STREAM m) where {           \
    throwM = lift . throwM };                                                 \
                                                                              \
{- \
instance (MonadError e m CONSTRAINT) => MonadError e (STREAM m) where {       \
    throwError = lift . throwError;                                           \
    catchError m h =                                                          \
        fromStream $ S.withCatchError (toStream m) (\e -> toStream $ h e) };  \
-} \
                                                                              \
instance (MonadReader r m CONSTRAINT) => MonadReader r (STREAM m) where {     \
    ask = lift ask;                                                           \
    local f m = fromStream $ S.withLocal f (toStream m) };                    \
                                                                              \
instance (MonadState s m CONSTRAINT) => MonadState s (STREAM m) where {       \
    get     = lift get;                                                       \
    put x   = lift (put x);                                                   \
    state k = lift (state k) }

------------------------------------------------------------------------------
-- StreamT
------------------------------------------------------------------------------

-- | The 'Semigroup' instance of 'StreamT' appends two streams sequentially,
-- yielding all elements from the first stream, and then all elements from the
-- second stream.
--
-- @
-- main = ('toList' . 'streamly' $ (fromFoldable [1,2]) \<\> (fromFoldable [3,4])) >>= print
-- @
-- @
-- [1,2,3,4]
-- @
--
-- The 'Monad' instance runs the /monadic continuation/ for each
-- element of the stream, streamly.
--
-- @
-- main = 'runStream' . 'streamly' $ do
--     x <- return 1 \<\> return 2
--     liftIO $ print x
-- @
-- @
-- 1
-- 2
-- @
--
-- 'StreamT' nests streams streamly in a depth first manner.
--
-- @
-- main = 'runStream' . 'streamly' $ do
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
-- This behavior of 'StreamT' is exactly like a list transformer. We call the
-- monadic code being run for each element of the stream a monadic
-- continuation. In imperative paradigm we can think of this composition as
-- nested @for@ loops and the monadic continuation is the body of the loop. The
-- loop iterates for all elements of the stream.
--
-- The 'streamly' combinator can be omitted as the default stream type is
-- 'StreamT'.
-- Note that serial composition can be used to combine an infinite number of
-- streams as it explores only one stream at a time.
--
newtype StreamT m a = StreamT {getStreamT :: S.Stream m a}
    deriving (Semigroup, Monoid, Functor, MonadTrans)

instance IsStream StreamT where
    toStream = getStreamT
    fromStream = StreamT

------------------------------------------------------------------------------
-- Semigroup
------------------------------------------------------------------------------

-- | Polymorphic version of the 'Semigroup' operation '<>' of 'StreamT'.
-- Appends two streams sequentially, yielding all elements from the first
-- stream, and then all elements from the second stream.
{-# INLINE splice #-}
splice :: IsStream t => t m a -> t m a -> t m a
splice m1 m2 = fromStream $ S.splice (toStream m1) (toStream m2)

------------------------------------------------------------------------------
-- Monad
------------------------------------------------------------------------------

instance Monad m => Monad (StreamT m) where
    return = pure
    (StreamT (S.Stream m)) >>= f = StreamT $ S.Stream $ \_ stp sng yld ->
        let run x = (S.runStream x) Nothing stp sng yld
            single a  = run $ toStream (f a)
            yield a r = run $ toStream $ f a <> (fromStream r >>= f)
        in m Nothing stp single yield

------------------------------------------------------------------------------
-- Other instances
------------------------------------------------------------------------------

MONAD_APPLICATIVE_INSTANCE(StreamT,)
MONAD_COMMON_INSTANCES(StreamT,)

------------------------------------------------------------------------------
-- CostreamT
------------------------------------------------------------------------------

-- | The 'Semigroup' instance of 'CostreamT' interleaves two streams,
-- yielding one element from each stream alternately.
--
-- @
-- main = ('toList' . 'interleaving' $ (fromFoldable [1,2]) \<\> (fromFoldable [3,4])) >>= print
-- @
-- @
-- [1,3,2,4]
-- @
--
-- Similarly, the 'Monad' instance fairly interleaves the iterations of the
-- inner and the outer loop, nesting loops in a breadth first manner.
--
--
-- @
-- main = 'runStream' . 'interleaving' $ do
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
-- Note that interleaving composition can only combine a finite number of
-- streams as it needs to retain state for each unfinished stream.
--
newtype CostreamT m a = CostreamT {getCostreamT :: S.Stream m a}
    deriving (Functor, MonadTrans)

{-# DEPRECATED InterleavedT "Please use 'CostreamT' instead." #-}
type InterleavedT = CostreamT

instance IsStream CostreamT where
    toStream = getCostreamT
    fromStream = CostreamT

------------------------------------------------------------------------------
-- Semigroup
------------------------------------------------------------------------------

-- | Polymorphic version of the 'Semigroup' operation '<>' of 'CostreamT'.
-- Interleaves two streams, yielding one element from each stream alternately.
{-# INLINE cosplice #-}
cosplice :: IsStream t => t m a -> t m a -> t m a
cosplice m1 m2 = fromStream $ S.cosplice (toStream m1) (toStream m2)

instance Semigroup (CostreamT m a) where
    (<>) = cosplice

infixr 5 <=>

-- | Same as 'cosplice'.
{-# DEPRECATED (<=>) "Please use 'cosplice' instead." #-}
{-# INLINE (<=>) #-}
(<=>) :: IsStream t => t m a -> t m a -> t m a
(<=>) = cosplice

------------------------------------------------------------------------------
-- Monoid
------------------------------------------------------------------------------

instance Monoid (CostreamT m a) where
    mempty = nil
    mappend = (<>)

------------------------------------------------------------------------------
-- Monad
------------------------------------------------------------------------------

instance Monad m => Monad (CostreamT m) where
    return = pure
    (CostreamT (S.Stream m)) >>= f = CostreamT $ S.Stream $ \_ stp sng yld ->
        let run x = (S.runStream x) Nothing stp sng yld
            single a  = run $ toStream (f a)
            yield a r = run $ toStream $ f a <> (fromStream r >>= f)
        in m Nothing stp single yield

------------------------------------------------------------------------------
-- Other instances
------------------------------------------------------------------------------

MONAD_APPLICATIVE_INSTANCE(CostreamT,)
MONAD_COMMON_INSTANCES(CostreamT,)

------------------------------------------------------------------------------
-- CoparallelT
------------------------------------------------------------------------------

-- | Adaptive parallel, in a left to right 'Semigroup' composition it tries to
-- yield elements from the left stream as long as it can, but it can run the
-- right stream in parallel if it needs to based on demand. The right stream
-- can be run if the left stream blocks on IO or cannot produce elements fast
-- enough for the consumer.
--
-- @
-- main = ('toList' . 'coparallely' $ (fromFoldable [1,2]) \<> (fromFoldable [3,4])) >>= print
-- @
-- @
-- [1,2,3,4]
-- @
--
-- Similarly, the monad instance of 'ParallelT' /may/ run each iteration
-- concurrently based on demand.  More concurrent iterations are started only
-- if the previous iterations are not able to produce enough output for the
-- consumer.
--
-- @
-- import "Streamly"
-- import Control.Concurrent
--
-- main = 'runStream' . 'coparallely' $ do
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
--
-- Note that this composition can be used to combine infinite number of streams
-- as it explores only a bounded number of streams at a time.
--
newtype CoparallelT m a = CoparallelT {getCoparallelT :: S.Stream m a}
    deriving (Functor, MonadTrans)

{-# DEPRECATED AsyncT "Please use 'CoparallelT' instead." #-}
type AsyncT = CoparallelT

instance IsStream CoparallelT where
    toStream = getCoparallelT
    fromStream = CoparallelT

------------------------------------------------------------------------------
-- Semigroup
------------------------------------------------------------------------------

-- | Polymorphic version of the 'Semigroup' operation '<>' of 'CoparallelT', but
-- polymorphic.  Merges two streams possibly concurrently, preferring the
-- elements from the left one when available.
{-# INLINE coparallel #-}
coparallel :: (IsStream t, MonadParallel m) => t m a -> t m a -> t m a
coparallel m1 m2 = fromStream $ S.coparallel (toStream m1) (toStream m2)

instance MonadParallel m => Semigroup (CoparallelT m a) where
    (<>) = coparallel

-- | Same as 'coparallel'.
{-# DEPRECATED (<|) "Please use 'coparallel' instead." #-}
{-# INLINE (<|) #-}
(<|) :: (IsStream t, MonadParallel m) => t m a -> t m a -> t m a
(<|) = coparallel

------------------------------------------------------------------------------
-- Monoid
------------------------------------------------------------------------------

instance MonadParallel m => Monoid (CoparallelT m a) where
    mempty = nil
    mappend = (<>)

------------------------------------------------------------------------------
-- Monad
------------------------------------------------------------------------------

{-# INLINE parbind #-}
parbind
    :: (forall c. S.Stream m c -> S.Stream m c -> S.Stream m c)
    -> S.Stream m a
    -> (a -> S.Stream m b)
    -> S.Stream m b
parbind par m f = go m
    where
        go (S.Stream g) =
            S.Stream $ \ctx stp sng yld ->
            let run x = (S.runStream x) ctx stp sng yld
                single a  = run $ f a
                yield a r = run $ f a `par` go r
            in g Nothing stp single yield

instance MonadParallel m => Monad (CoparallelT m) where
    return = pure
    (CoparallelT m) >>= f = CoparallelT $ parbind par m (getCoparallelT . f)
        where par = S.joinStreamVar2 (SVarStyle Conjunction LIFO)

------------------------------------------------------------------------------
-- Other instances
------------------------------------------------------------------------------

MONAD_APPLICATIVE_INSTANCE(CoparallelT,MONADPARALLEL)
MONAD_COMMON_INSTANCES(CoparallelT, MONADPARALLEL)

------------------------------------------------------------------------------
-- ParallelT
------------------------------------------------------------------------------

-- | Round robin concurrent composition.
--
-- The Semigroup instance of 'ParallelT' concurrently /merges/ streams in a
-- round robin fashion, yielding elements from both streams alternately.
--
-- @
-- main = ('toList' . 'parallely' $ (fromFoldable [1,2]) \<> (fromFoldable [3,4])) >>= print
-- @
-- @
-- [1,3,2,4]
-- @
--
-- Similarly, the 'Monad' instance of 'ParallelT' runs /all/ iterations fairly
-- concurrently using a round robin scheduling.
--
-- @
-- import "Streamly"
-- import Control.Concurrent
--
-- main = 'runStream' . 'parallely' $ do
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
-- Unlike 'CoparallelT' all iterations are guaranteed to run fairly
-- concurrently, unconditionally.
--
-- Note that round robin composition can only combine a finite number of
-- streams as it needs to retain state for each unfinished stream.
--
newtype ParallelT m a = ParallelT {getParallelT :: S.Stream m a}
    deriving (Functor, MonadTrans)

instance IsStream ParallelT where
    toStream = getParallelT
    fromStream = ParallelT

------------------------------------------------------------------------------
-- Semigroup
------------------------------------------------------------------------------

-- | Polymorphic version of the 'Semigroup' operation '<>' of 'ParallelT'.
-- Merges two streams concurrently choosing elements from both fairly.
{-# INLINE parallel #-}
parallel :: (IsStream t, MonadParallel m) => t m a -> t m a -> t m a
parallel m1 m2 = fromStream $ S.parallel (toStream m1) (toStream m2)

instance MonadParallel m => Semigroup (ParallelT m a) where
    (<>) = parallel

------------------------------------------------------------------------------
-- Monoid
------------------------------------------------------------------------------

instance MonadParallel m => Monoid (ParallelT m a) where
    mempty = nil
    mappend = (<>)

------------------------------------------------------------------------------
-- Monad
------------------------------------------------------------------------------

instance MonadParallel m => Monad (ParallelT m) where
    return = pure
    (ParallelT m) >>= f = ParallelT $ parbind par m (getParallelT . f)
        where par = S.joinStreamVar2 (SVarStyle Conjunction FIFO)

------------------------------------------------------------------------------
-- Other instances
------------------------------------------------------------------------------

MONAD_APPLICATIVE_INSTANCE(ParallelT,MONADPARALLEL)
MONAD_COMMON_INSTANCES(ParallelT, MONADPARALLEL)

------------------------------------------------------------------------------
-- Serially Zipping Streams
------------------------------------------------------------------------------

-- | Zip two streams serially using a pure zipping function.
zipWith :: IsStream t => (a -> b -> c) -> t m a -> t m b -> t m c
zipWith f m1 m2 = fromStream $ go (toStream m1) (toStream m2)
    where
    go mx my = S.Stream $ \_ stp sng yld -> do
        let merge a ra =
                let single2 b = sng (f a b)
                    yield2 b rb = yld (f a b) (go ra rb)
                 in (S.runStream my) Nothing stp single2 yield2
        let single1 a   = merge a S.nil
            yield1 a ra = merge a ra
        (S.runStream mx) Nothing stp single1 yield1

-- | The applicative instance of 'ZipStreamM' zips a number of streams serially
-- i.e. it produces one element from each stream serially and then zips all
-- those elements.
--
-- @
-- main = (toList . 'zipStreamly' $ (,,) \<$\> s1 \<*\> s2 \<*\> s3) >>= print
--     where s1 = fromFoldable [1, 2]
--           s2 = fromFoldable [3, 4]
--           s3 = fromFoldable [5, 6]
-- @
-- @
-- [(1,3,5),(2,4,6)]
-- @
--
-- The 'Semigroup' instance of this type works the same way as that of
-- 'StreamT'.
--
newtype ZipStreamM m a = ZipStreamM {getZipStreamM :: S.Stream m a}
        deriving (Functor, Semigroup, Monoid)

instance Monad m => Applicative (ZipStreamM m) where
    pure = ZipStreamM . S.repeat
    (<*>) = zipWith id

instance IsStream ZipStreamM where
    toStream = getZipStreamM
    fromStream = ZipStreamM

------------------------------------------------------------------------------
-- Parallely Zipping Streams
------------------------------------------------------------------------------

-- | Zip two streams concurrently (i.e. both the elements being zipped are
-- generated concurrently) using a pure zipping function.
zipParallelWith :: (IsStream t, MonadParallel m)
    => (a -> b -> c) -> t m a -> t m b -> t m c
zipParallelWith f m1 m2 = fromStream $ S.Stream $ \_ stp sng yld -> do
    ma <- async m1
    mb <- async m2
    (S.runStream (toStream (zipWith f ma mb))) Nothing stp sng yld

{-# DEPRECATED zipAsyncWith "Please use zipParallelWith instead." #-}
zipAsyncWith :: (IsStream t, MonadParallel m)
    => (a -> b -> c) -> t m a -> t m b -> t m c
zipAsyncWith = zipParallelWith

-- | Like 'ZipStreamM' but zips in parallel, it generates all the elements to
-- be zipped concurrently.
--
-- @
-- main = (toList . 'zipParallely' $ (,,) \<$\> s1 \<*\> s2 \<*\> s3) >>= print
--     where s1 = fromFoldable [1, 2]
--           s2 = fromFoldable [3, 4]
--           s3 = fromFoldable [5, 6]
-- @
-- @
-- [(1,3,5),(2,4,6)]
-- @
--
-- The 'Semigroup' instance of this type works the same way as that of
-- 'StreamT'.
--
newtype ZipParallelM m a = ZipParallelM {getZipParallelM :: S.Stream m a}
        deriving (Functor, Semigroup, Monoid)

{-# DEPRECATED ZipAsync "Please use ZipParallelM instead." #-}
type ZipAsync = ZipParallelM

instance MonadParallel m => Applicative (ZipParallelM m) where
    pure = ZipParallelM . S.repeat
    (<*>) = zipParallelWith id

instance IsStream ZipParallelM where
    toStream = getZipParallelM
    fromStream = ZipParallelM

-------------------------------------------------------------------------------
-- Type adapting combinators
-------------------------------------------------------------------------------

-- | Adapt any specific stream type to any other specific stream type.
adapt :: (IsStream t1, IsStream t2) => t1 m a -> t2 m a
adapt = fromStream . toStream

-- | Fix the type of a polymorphic stream as 'StreamT'.
streamly :: IsStream t => StreamT m a -> t m a
streamly = adapt

-- | Fix the type of a polymorphic stream as 'CostreamT'.
costreamly :: IsStream t => CostreamT m a -> t m a
costreamly = adapt

-- | Same as 'costreamly'.
{-# DEPRECATED interleaving "Please use costreamly instead." #-}
interleaving :: IsStream t => CostreamT m a -> t m a
interleaving = costreamly

-- | Fix the type of a polymorphic stream as 'CoparallelT'.
coparallely :: IsStream t => CoparallelT m a -> t m a
coparallely = adapt

-- | Same as 'coparallely'.
{-# DEPRECATED asyncly "Please use coparallely instead." #-}
asyncly :: IsStream t => CoparallelT m a -> t m a
asyncly = coparallely

-- | Fix the type of a polymorphic stream as 'ParallelT'.
parallely :: IsStream t => ParallelT m a -> t m a
parallely = adapt

-- | Fix the type of a polymorphic stream as 'ZipStreamM'.
zipStreamly :: IsStream t => ZipStreamM m a -> t m a
zipStreamly = adapt

-- | Same as 'zipStreamly'.
{-# DEPRECATED zipping "Please use zipStreamly instead." #-}
zipping :: IsStream t => ZipStreamM m a -> t m a
zipping = zipStreamly

-- | Fix the type of a polymorphic stream as 'ZipParallelM'.
zipParallely :: IsStream t => ZipParallelM m a -> t m a
zipParallely = adapt

-- | Same as 'zipParallely'.
{-# DEPRECATED zippingAsync "Please use zipParallely instead." #-}
zippingAsync :: IsStream t => ZipParallelM m a -> t m a
zippingAsync = zipParallely

-------------------------------------------------------------------------------
-- Running Streams, convenience functions specialized to types
-------------------------------------------------------------------------------

-- | Same as @runStream@.
{-# DEPRECATED runStreamT "Please use runStream instead." #-}
runStreamT :: Monad m => StreamT m a -> m ()
runStreamT = runStream

-- | Same as @runStream . costreamly@.
{-# DEPRECATED runInterleavedT "Please use 'runStream . interleaving' instead." #-}
runInterleavedT :: Monad m => InterleavedT m a -> m ()
runInterleavedT = runStream . costreamly

-- | Same as @runStream . coparallely@.
{-# DEPRECATED runAsyncT "Please use 'runStream . coparallely' instead." #-}
runAsyncT :: Monad m => CoparallelT m a -> m ()
runAsyncT = runStream . coparallely

-- | Same as @runStream . parallely@.
{-# DEPRECATED runParallelT "Please use 'runStream . parallely' instead." #-}
runParallelT :: Monad m => ParallelT m a -> m ()
runParallelT = runStream . parallely

-- | Same as @runStream . zipping@.
{-# DEPRECATED runZipStream "Please use 'runStream . zipStreamly instead." #-}
runZipStream :: Monad m => ZipStreamM m a -> m ()
runZipStream = runStream . zipStreamly

-- | Same as @runStream . zippingAsync@.
{-# DEPRECATED runZipAsync "Please use 'runStream . zipParallely instead." #-}
runZipAsync :: Monad m => ZipParallelM m a -> m ()
runZipAsync = runStream . zipParallely

------------------------------------------------------------------------------
-- IO Streams
------------------------------------------------------------------------------

-- | A serial IO stream of elements of type @a@. See 'StreamT' documentation
-- for more details.
type Stream a = StreamT IO a

-- | An interleaving serial IO stream of elements of type @a@. See 'CostreamT'
-- documentation for more details.
type Costream a = CostreamT IO a

-- | A demand driven left biased parallelly composing IO stream of elements of
-- type @a@.  See 'CoparallelT' documentation for more details.
type Coparallel a = CoparallelT IO a

-- | A round robin parallelly composing IO stream of elements of type @a@.
-- See 'ParallelT' documentation for more details.
type Parallel a = ParallelT IO a

-- | An IO stream whose applicative instance zips streams serially.
type ZipStream a = ZipStreamM IO a

-- | An IO stream whose applicative instance zips streams parallely.
type ZipParallel a = ZipParallelM IO a

-- | Lift a value from IO monad to any of the stream types. This works for all
-- stream types including those that are not monads e.g. 'ZipStream' and
-- 'ZipParallel'.
fromIO :: (IsStream t, MonadIO m) => IO a -> t m a
fromIO = streamly . liftIO

fromM :: (IsStream t, Monad m) => m a -> t m a
fromM = streamly . lift

------------------------------------------------------------------------------
-- Fold Utilities
------------------------------------------------------------------------------

-- | A variant of 'Data.Foldable.fold' that allows you to fold a 'Foldable'
-- container of streams using the specified stream sum operation.
--
-- @foldWith 'parallel' $ map return [1..3]@
{-# INLINABLE foldWith #-}
foldWith :: (IsStream t, Foldable f)
    => (t m a -> t m a -> t m a) -> f (t m a) -> t m a
foldWith f = foldr f nil

-- | A variant of 'foldMap' that allows you to map a monadic streaming action
-- on a 'Foldable' container and then fold it using the specified stream sum
-- operation.
--
-- @foldMapWith 'parallel' return [1..3]@
{-# INLINABLE foldMapWith #-}
foldMapWith :: (IsStream t, Foldable f)
    => (t m b -> t m b -> t m b) -> (a -> t m b) -> f a -> t m b
foldMapWith f g = foldr (f . g) nil

-- | Like 'foldMapWith' but with the last two arguments reversed i.e. the
-- monadic streaming function is the last argument.
{-# INLINABLE forEachWith #-}
forEachWith :: (IsStream t, Foldable f)
    => (t m b -> t m b -> t m b) -> f a -> (a -> t m b) -> t m b
forEachWith f xs g = foldr (f . g) nil xs
