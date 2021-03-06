## Unreleased

### Breaking changes
* Change the semantics of the Semigroup instance for `InterleavedT`, `AsyncT`
  and `ParallelT`. The new semantics are as follows:
  * For `InterleavedT`, `<>` operation interleaves two streams
  * For `AsyncT`, `<>` now concurrently merges two streams in a left biased
    manner using demand based concurrency.
  * For `ParallelT`, the `<>` operation now concurrently meges the two streams
    in a fairly parallel manner.

  To adapt to the new changes, replace `<>` with `splice` wherever it is used
  for stream types other than `StreamT`.

* Change the semantics of `Alternative` instance. The `<|>` operator now has a
  different behavior for each type. See the documentation for more details. To
  adapt to this change replace any usage of `<|>` with `parallel` and
  `empty` with `nil`.
* Stream type now defaults to the `StreamT` type unless explicitly specified
  using a type combinator or a monomorphic type.  This change reduces puzzling
  type errors for beginners. It includes the following two changes:
  * Change the type of all stream elimination functions to use `StreamT`
    instead of a polymorphic type. This makes sure that the stream type is
    always fixed at all exits.
  * Change the type combinators (e.g. `parallely`) to only fix the argument
    stream type and the output stream type remains polymorphic.

  Stream types may have to be changed or type combinators may have to be added
  or removed to adapt to this change.
* The type `ZipStream` has been redefined to be specialized to IO monad.
  `ZipStreamM` is now the same as the original `ZipStream` type. You will have
  to change all occurrences of `ZipStream` to `ZipStreamM`.
* Change the type of `foldrM` to make it consistent with `foldrM` in base.
* Remove the `MonadError` instance as it was not working correctly for
  parallel compositions. Use `MonadThrow` instead for error propagation.
* Remove Num/Fractional/Floating instances as they are not very useful. Use
  `fmap` and `liftA2` instead.

### Deprecations
* Deprecate and rename the following symbols:
    * `Streaming` to `IsStream`
    * `runStreaming` to `runStream`
    * `AsyncT` to `CoparallelT`
    * `ZipAsync` to `ZipParallelM`
    * `interleaving` to `costreamly`
    * `asyncly` to `coparallely`
    * `zipping` to `zipStreamly`
    * `zippingAsync` to `zipParallely`
    * `<=>` to `cosplice`
    * `<|` to `coparallel`
    * `each` to `fromFoldable`
    * `scan` to `scanx`
    * `foldl` to `foldx`
    * `foldlM` to `foldxM`
    * `zipAsyncWith` to `zipParallelWith`
    * `zipAsyncWithM` to `zipParallelWithM`
* Deprecate and remove the following symbols:
    * `runStreamT`
    * `runInterleavedT`
    * `runAsyncT`
    * `runParallelT`
    * `runZipStream`
    * `runZipAsync`

### Enhancements
* Add the following functions:
    * `scanl'` strict left scan
    * `foldl'` strict left fold
    * `foldlM'` strict left fold with a monadic fold function
    * `splice` run two streams serially one after the other
    * `parallel` run two streams in parallel (replaces `<|>`)
* Add simpler stream types that are specialized to the IO monad

## 0.1.2

### Enhancements
* Add `iterate`, `iterateM` stream operations

### Bug Fixes
* Fixed a bug that casued unexpected behavior when `pure` was used to inject
  values in Applicative composition of `ZipStream` and `ZipAsync` types.

## 0.1.1

### Enhancements
* Make `cons` right associative and provide an operator form `.:` for it
* Add `null`, `tail`, `reverse`, `replicateM`, `scan` stream operations
* Improve performance of some stream operations (`foldl`, `dropWhile`)

### Bug Fixes
* Fix the `product` operation. Earlier, it always returned 0 due to a bug
* Fix the `last` operation, which returned `Nothing` for singleton streams

## 0.1.0

* Initial release
