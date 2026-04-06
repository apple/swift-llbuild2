# Dependency Graph and Caching

This document explains how llbuild2 models dependencies and uses caching to avoid redundant work.

## Keys and Values

In llbuild2, the dependency graph is implicit in the relationships between `FXKey` evaluations. There is no separate
graph data structure — instead, keys declare their dependencies through the `FXVersioning` protocol and discover
concrete dependencies at evaluation time via `FXFunctionInterface.request()`.

### `FXKey`

An `FXKey` is a unit of evaluation that produces an `FXValue`. During evaluation, a key's `computeValue()` method
receives an `FXFunctionInterface` through which it can:

- **`request()`** another `FXKey`, establishing a dependency and returning its value.
- **`spawn()`** an `FXAction`, dispatching work to an `FXExecutor` and returning the action's result.
- **`resource()`** to access an `FXResource` (e.g. a compiler or SDK).

These dependency relationships are tracked at runtime by `KeyDependencyGraph`, which detects cycles.

### `FXAction`

An `FXAction` represents a unit of work that may need a specific execution environment. Actions declare
`FXActionRequirements` (worker size, network access, custom key-value pairs) and implement a `run()` method. The
`FXExecutor` is responsible for dispatching actions to an appropriate environment.

## Versioning and Cache Keys

llbuild2 uses a versioning system (`FXVersioning`) to generate stable cache keys. Each key type declares:

- **`version`** — An integer version that should be incremented when the key's computation logic changes.
- **`versionDependencies`** — Other `FXVersioning` types this key depends on.
- **`actionDependencies`** — `FXAction` types this key may spawn.
- **`configurationKeys`** — Configuration inputs that affect this key's evaluation.
- **`resourceEntitlements`** — `FXResource`s this key needs access to.

The versioning system aggregates across the full dependency graph: a key's `cacheKeyPrefix` includes the sum of all
transitive dependency versions. This means changing the version of any key in the dependency chain automatically
invalidates all downstream caches.

Cache paths are computed from the key type name, aggregated version, and the key's encoded contents (via
`CommandLineArgsEncoder` for short keys, JSON for medium keys, or a BLAKE3 hash for long keys). Resource versions and
configuration inputs are appended when present.

## Cache Lookup Flow

When `FXEngine` evaluates a key:

1. Compute the key's cache path (type name + aggregated version + encoded contents).
2. Look up the cache path in `FXFunctionCache`.
3. **Cache hit**: Retrieve the `FXCASObject` from the CAS database, deserialize the value, and validate it via the
   key's `validateCache()` method. If validation fails, attempt `fixCached()` before falling back to recomputation.
4. **Cache miss**: Call `computeValue()`, store the result in the CAS and function cache.

The `FXFunctionCache` protocol has two built-in implementations:
- **`InMemoryFunctionCache`** — A simple in-process cache (the default).
- **`FileBackedFunctionCache`** — Persistent cache backed by on-disk storage.

## Avoiding Redundant Work

Because cache keys incorporate the full content of the key (not just its identity), llbuild2 naturally avoids redundant
work. If an upstream change produces the same output as before, downstream keys will have the same cache key and hit
the cache, even though the upstream key was re-evaluated.

The engine also deduplicates concurrent requests for the same key using `LLBEventualResultsCache`, ensuring that if
multiple consumers request the same key simultaneously, only one evaluation occurs.
