{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE UndecidableInstances  #-}

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

    , adapt

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

import           Prelude                hiding (zipWith)
import           Streamly.Core


------------------------------------------------------------------------------
-- Constructing a stream
------------------------------------------------------------------------------

-- | Represesnts an empty stream just like @[]@ represents an empty list.
nil :: Streaming t => t m a
nil = fromStream snil

infixr 5 `cons`

-- | Constructs a stream by adding a pure value at the head of an existing
-- stream, just like ':' constructs lists. For example:
--
-- @
-- > let stream = 1 \`cons` 2 \`cons` 3 \`cons` nil
-- > (toList . serially) stream
-- [1,2,3]
-- @
cons :: (Streaming t) => a -> t m a -> t m a
cons a r = fromStream $ scons a (Just (toStream r))

infixr 5 .:

-- | Operator equivalent of 'cons' so that you can construct a stream of pure
-- values more succinctly like this:
--
-- @
-- > let stream = 1 .: 2 .: 3 .: nil
-- > (toList . serially) stream
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
-- > (toList . serially) stream
-- [1,2,3]
-- @
--
-- In the first method we construct a stream by adding one element at a time.
-- In the second method we first construct singleton streams using 'pure' and
-- then compose all those streams together using the 'Semigroup' style
-- composition of streams. The former method is a bit more efficient than the
-- latter.
--
(.:) :: (Streaming t) => a -> t m a -> t m a
(.:) = cons

-- | Build a stream from its church encoding.  The function passed maps
-- directly to the underlying representation of the stream type. The second
-- parameter to the function is the "yield" function yielding a value and the
-- remaining stream if any otherwise 'Nothing'. The third parameter is to
-- represent an "empty" stream.
streamBuild :: Streaming t
    => (forall k r. Maybe (k m a)
        -> (a -> Maybe (t m a) -> m r)
        -> m r
        -> m r)
    -> t m a
streamBuild k = fromStream $ Stream $ \sv stp yld ->
    let yield a Nothing  = yld a Nothing
        yield a (Just r) = yld a (Just (toStream r))
     in k sv yield stp

-- | Build a singleton stream from a callback function.
fromCallback :: (Streaming t) => (forall r. (a -> m r) -> m r) -> t m a
fromCallback k = fromStream $ Stream $ \_ _ yld -> k (\a -> yld a Nothing)

------------------------------------------------------------------------------
-- Destroying a stream
------------------------------------------------------------------------------

-- | Fold a stream using its church encoding. The second argument is the "step"
-- function consuming an element and the remaining stream, if any. The third
-- argument is for consuming an "empty" stream that yields nothing.
streamFold :: Streaming t
    => Maybe (SVar m a) -> (a -> Maybe (t m a) -> m r) -> m r -> t m a -> m r
streamFold sv step blank m =
    let yield a Nothing  = step a Nothing
        yield a (Just x) = step a (Just (fromStream x))
     in (runStream (toStream m)) sv blank yield

-- | Run a streaming composition, discard the results.
runStreaming :: (Monad m, Streaming t) => t m a -> m ()
runStreaming m = go (toStream m)
    where
    go m1 =
        let stop = return ()
            yield _ Nothing  = stop
            yield _ (Just x) = go x
         in (runStream m1) Nothing stop yield

------------------------------------------------------------------------------
-- Transformation
------------------------------------------------------------------------------

-- | Zip two streams serially using a pure zipping function.
zipWith :: Streaming t => (a -> b -> c) -> t m a -> t m b -> t m c
zipWith f m1 m2 = fromStream $ go (toStream m1) (toStream m2)
    where
    go mx my = Stream $ \_ stp yld -> do
        let merge a ra =
                let yield2 b Nothing   = yld (f a b) Nothing
                    yield2 b (Just rb) = yld (f a b) (Just (go ra rb))
                 in (runStream my) Nothing stp yield2
        let yield1 a Nothing   = merge a snil
            yield1 a (Just ra) = merge a ra
        (runStream mx) Nothing stp yield1

-------------------------------------------------------------------------------
-- Type adapting combinators
-------------------------------------------------------------------------------

-- | Adapt one streaming type to another.
adapt :: (Streaming t1, Streaming t2) => t1 m a -> t2 m a
adapt = fromStream . toStream

------------------------------------------------------------------------------
-- Sum Style Composition
------------------------------------------------------------------------------

infixr 5 <=>

-- | Sequential interleaved composition, in contrast to '<>' this operator
-- fairly interleaves two streams instead of appending them; yielding one
-- element from each stream alternately.
--
-- @
-- main = ('toList' . 'serially' $ (return 1 <> return 2) \<=\> (return 3 <> return 4)) >>= print
-- @
-- @
-- [1,3,2,4]
-- @
--
-- This operator corresponds to the 'InterleavedT' style. Unlike '<>', this
-- operator cannot be used to fold infinite containers since that might
-- accumulate too many partially drained streams.  To be clear, it can combine
-- infinite streams but not infinite number of streams.
{-# INLINE (<=>) #-}
(<=>) :: Streaming t => t m a -> t m a -> t m a
m1 <=> m2 = fromStream $ interleave (toStream m1) (toStream m2)

------------------------------------------------------------------------------
-- Fold Utilities
------------------------------------------------------------------------------

-- $foldutils
-- These utilities are designed to pass the first argument as one of the sum
-- style composition operators (i.e. '<>', '<=>', '<|', '<|>') to conveniently
-- fold a container using any style of stream composition.

-- | Like the 'Prelude' 'fold' but allows you to specify a binary sum style
-- stream composition operator to fold a container of streams.
--
-- @foldWith (<>) $ map return [1..3]@
{-# INLINABLE foldWith #-}
foldWith :: (Streaming t, Foldable f)
    => (t m a -> t m a -> t m a) -> f (t m a) -> t m a
foldWith f = foldr f nil

-- | Like 'foldMap' but allows you to specify a binary sum style composition
-- operator to fold a container of streams. Maps a monadic streaming action on
-- the container before folding it.
--
-- @foldMapWith (<>) return [1..3]@
{-# INLINABLE foldMapWith #-}
foldMapWith :: (Streaming t, Foldable f)
    => (t m b -> t m b -> t m b) -> (a -> t m b) -> f a -> t m b
foldMapWith f g = foldr (f . g) nil

-- | Like 'foldMapWith' but with the last two arguments reversed i.e. the
-- monadic streaming function is the last argument.
{-# INLINABLE forEachWith #-}
forEachWith :: (Streaming t, Foldable f)
    => (t m b -> t m b -> t m b) -> f a -> (a -> t m b) -> t m b
forEachWith f xs g = foldr (f . g) nil xs
